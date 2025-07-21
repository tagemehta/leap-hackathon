/// VerifierService
/// --------------
/// Asynchronously verifies **candidate crops** against the user’s target description
/// using a Large Language Model (LLM) image-understanding API.
///
/// High-level flow performed each frame by `tick(...)`:
/// 1. Fetch candidates in `unknown` match state from the shared `CandidateStore`.
/// 2. Obtain a `CGImage` for the full frame once (lazy).
/// 3. Crop each candidate’s bounding box to an RGB JPEG and base-64 encode it.
/// 4. Call `LLMVerifier.verify(imageData:)` to classify whether the crop matches
///    the natural-language description.
/// 5. Update the `CandidateStore` with `.matched`, or remove the candidate if it
///    fails verification.
///
/// Threading / Combine:
/// * Network calls are performed off-main; updates to `CandidateStore` occur
///   on whichever scheduler Combine delivers on (store is thread-safe).
/// * A small `Set<AnyCancellable>` is kept per instance
///
/// Dependencies injected:
/// * `LLMVerifier` – abstraction over the external LLM API.
/// * `ImageUtilities` – for bounding-box → pixel rect mapping & buffer → image.
///
/// Created by Tage Mehta on 6/12/25.
//
//  DefaultVerifierService.swift
//  thing-finder
//
//  Created as part of the state-machine refactor. Wraps asynchronous LLM
//  verification calls and updates the `CandidateStore` with the results.
//
//  NOTE: VSCode may show unresolved import warnings – they compile fine in
//  Xcode as per user guidance.

import Combine
import CoreVideo
import Foundation
import UIKit
import Vision

public final class VerifierService: VerifierServiceProtocol {
  private let verifier: ImageVerifier
  internal let imgUtils: ImageUtilities
  internal let verificationConfig: VerificationConfig
  internal let ocrEngine: OCREngine
  private var cancellables: Set<AnyCancellable> = []
  /// Timestamp of the most recent *batch* of verify() requests (i.e., the last tick that sent one or more verify calls).
  private var lastVerifyBatch: Date = .distantPast
  /// Minimum interval between successive batches of verify() requests.
  private let minVerifyInterval: TimeInterval = 1.0  // seconds

  init(verifier: ImageVerifier, imgUtils: ImageUtilities, config: VerificationConfig, ocrEngine: OCREngine = VisionOCREngine()) {
    self.verifier = verifier
    self.imgUtils = imgUtils
    self.verificationConfig = config
    self.ocrEngine = ocrEngine
  }

  /// Called every frame by `FramePipelineCoordinator`.
  public func tick(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    imageSize: CGSize,
    viewBounds: CGRect,
    store: CandidateStore
  ) {
    let pendingUnknown = store.candidates.values.filter { $0.matchStatus == .unknown }
    guard !pendingUnknown.isEmpty else { return }

    // Split candidates into ones we can auto-match (no text description) and ones needing verification.
    var toVerify: [Candidate] = []
    if verifier.targetTextDescription.isEmpty {
      for cand in pendingUnknown {
        store.update(id: cand.id) { $0.matchStatus = .full }
      }
    } else {
      toVerify = pendingUnknown
    }
    guard
      !toVerify.isEmpty || !store.candidates.values.filter({ $0.matchStatus == .partial }).isEmpty
    else { return }

    let now = Date()
    // --------- OCR retry pass (only when OCR enabled)
    var fullImage: CGImage?
    if self.verificationConfig.shouldRunOCR {
      let partials = store.candidates.values.filter {
        $0.matchStatus == .partial && $0.ocrAttempts < self.verificationConfig.maxOCRRetries
      }
      if !partials.isEmpty {
        fullImage = imgUtils.cvPixelBuffertoCGImage(buffer: pixelBuffer)
        for cand in partials {
          self.enqueueOCR(
            for: cand, fullImage: fullImage!, imageSize: imageSize, orientation: orientation,
            store: store)
        }
      }
    }
    // Rate-limit: if the previous batch was too recent, skip this tick entirely.
    guard now.timeIntervalSince(lastVerifyBatch) >= minVerifyInterval else {
      return
    }

    fullImage = fullImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: pixelBuffer)

    lastVerifyBatch = now
    for cand in toVerify {

      // Convert normalized box → pixel rect using ImageUtilities
      let (imageRect, _) = imgUtils.unscaledBoundingBoxes(
        for: cand.lastBoundingBox,
        imageSize: imageSize,
        viewSize: imageSize,  // view size irrelevant here
        orientation: orientation
      )
      guard let crop = fullImage!.cropping(to: imageRect) else { continue }

      guard let jpg = UIImage(cgImage: crop).jpegData(compressionQuality: 1) else { continue }

      store.update(id: cand.id) { $0.matchStatus = .waiting }

      verifier.verify(imageData: jpg.base64EncodedString())
        .sink { completion in
          if case .failure(let err) = completion {
            print("LLM verify error: \(err)")
          }
        } receiveValue: { outcome in
          if outcome.isMatch {
            store.update(id: cand.id) {
              $0.detectedDescription = outcome.description
            }
            if !self.verificationConfig.shouldRunOCR {
              store.update(id: cand.id) { $0.matchStatus = .full }
              return
            }
            // Promote to partial and begin OCR verification
            store.update(id: cand.id) {
              $0.matchStatus = .partial
              $0.detectedDescription = outcome.description
            }
            self.enqueueOCR(
              for: cand, fullImage: fullImage!, imageSize: imageSize, orientation: orientation,
              store: store)
          } else {
            store.update(id: cand.id) {
              if outcome.rejectReason == "unclear_image" || outcome.rejectReason == "low_confidence"
              {
                // Image too blurry / unclear – keep searching so candidate will be retried
                $0.matchStatus = .unknown
              } else {
                $0.matchStatus = .rejected
              }
              $0.rejectReason = outcome.rejectReason
              $0.detectedDescription = outcome.description
            }
          }
        }
        .store(in: &cancellables)
    }

  }
}
