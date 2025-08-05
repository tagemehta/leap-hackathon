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
  /// When using combined strategy we build verifiers on-the-fly; otherwise we keep one.
  private let defaultVerifier: ImageVerifier

  internal let imgUtils: ImageUtilities
  internal let verificationConfig: VerificationConfig
  internal let ocrEngine: OCREngine
  private var cancellables: Set<AnyCancellable> = []
  /// Timestamp of the most recent *batch* of verify() requests (i.e., the last tick that sent one or more verify calls).
  private var lastVerifyBatch: Date = .distantPast
  /// Minimum interval between successive batches of verify() requests.
  private let minVerifyInterval: TimeInterval = 1  // seconds

  init(
    verifier: ImageVerifier, imgUtils: ImageUtilities, config: VerificationConfig,
    ocrEngine: OCREngine = VisionOCREngine()
  ) {
    self.defaultVerifier = verifier
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
    let now = Date()
    // Thread-safe read copy of current candidates
    let candidatesSnapshot = store.snapshot()
    let pendingUnknown = candidatesSnapshot.values.filter { $0.matchStatus == .unknown }

    // Include stale partial/full candidates for re-verification
    let staleVerified = candidatesSnapshot.values.filter {
      ($0.matchStatus == .partial || $0.matchStatus == .full)
        && (now.timeIntervalSince($0.lastVerified ?? $0.createdAt)
          >= self.verificationConfig.reverifyInterval)
    }
    // Split candidates into ones we can auto-match (no text description) and ones needing verification.
    var toVerify: [Candidate] = []
    toVerify.append(contentsOf: staleVerified)
    if defaultVerifier.targetTextDescription.isEmpty {
      for cand in pendingUnknown {
        store.update(id: cand.id) { $0.matchStatus = .full }
      }
    } else {
      toVerify.append(contentsOf: pendingUnknown)
    }
    guard
      !toVerify.isEmpty || !store.snapshot().values.filter({ $0.matchStatus == .partial }).isEmpty
    else { return }

    // --------- OCR retry pass (only when OCR enabled)
    var fullImage: CGImage?
    if self.verificationConfig.shouldRunOCR {
      let partials = store.snapshot().values.filter {
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
      // ---------------- Per-candidate throttling ----------------
      print(
        "[Verifier] Considering candidate \(cand.id); bestView=\(cand.view); lastMMR=\(cand.lastMMRTime.timeIntervalSince1970)"
      )

      // Skip verification if the candidate's bounding box covers less than 15% of the frame.
      // `lastBoundingBox` is already normalised to [0,1] coordinates so width*height gives
      // the fraction of image area occupied.
      let bboxArea = cand.lastBoundingBox.width * cand.lastBoundingBox.height
      let minAreaThreshold: CGFloat = 0.10  // 10% of the image
      if bboxArea < minAreaThreshold {
        print("[Verifier] Candidate \(cand.id) skipped – bbox too small (\(bboxArea * 100)%)")
        continue
      }

      // Skip verification if bounding box is significantly taller than it is wide.
      // Allow roughly square boxes (front/rear views) but reject tall portrait shapes.
      let aspectRatio = cand.lastBoundingBox.height / max(cand.lastBoundingBox.width, 0.0001)
      let maxTallness: CGFloat = 2  // height cannot exceed 200% of width
      if aspectRatio > maxTallness {
        print("[Verifier] Candidate \(cand.id) skipped – bbox too tall (h/w=\(aspectRatio))")
        continue
      }

      if cand.view != .side
        && now.timeIntervalSince(cand.lastMMRTime) < verificationConfig.perCandidateMMRInterval
      {
        // Skip TrafficEye re-verify until per-candidate interval passes.
        print("[Verifier] Candidate \(cand.id) skipped – MMR throttled")
        continue
      }

      // Convert normalized box → pixel rect using ImageUtilities
      let (imageRect, _) = imgUtils.unscaledBoundingBoxes(
        for: cand.lastBoundingBox,
        imageSize: imageSize,
        viewSize: imageSize,  // view size irrelevant here
        orientation: orientation
      )
      guard let crop = fullImage!.cropping(to: imageRect) else { continue }

      let img = UIImage(cgImage: crop, scale: 1.0, orientation: UIImage.Orientation(orientation))
      // For first-time verification show .waiting; for periodic re-verification keep current status to avoid extra speech.
      if cand.matchStatus == .unknown {
        store.update(id: cand.id) { $0.matchStatus = .waiting }
      }
      // Choose verifier per candidate based on config & policy, with optional override
      let chosenKind: VerifierKind
      let chosenVerifier: ImageVerifier
      if self.verificationConfig.useCombinedVerifier {
        switch VerificationPolicy.nextKind(for: cand) {
        case .trafficEye:
          chosenKind = .trafficEye
          chosenVerifier = TrafficEyeVerifier(
            targetTextDescription: self.defaultVerifier.targetTextDescription,
            config: self.verificationConfig)
        case .llm:
          chosenKind = .llm
          chosenVerifier = TwoStepVerifier(
            targetTextDescription: self.defaultVerifier.targetTextDescription)
        }
      } else {
        chosenKind = .trafficEye
        chosenVerifier = self.defaultVerifier
      }
      let verifyStartTime = Date()
      chosenVerifier.verify(image: img)
        .replaceError(
          with: VerificationOutcome(isMatch: false, description: "", rejectReason: .apiError)
        )
        .sink { outcome in
          // -------- Post-verification bookkeeping --------
          // Update best view & timing
          let latency = Date().timeIntervalSince(verifyStartTime)
          print(
            "[Verifier] Result for candidate \(cand.id): kind=\(chosenKind) match=\(outcome.isMatch) view=\(String(describing: outcome.vehicleView)) score=\(String(describing: outcome.viewScore)) reason=\(String(describing: outcome.rejectReason?.rawValue)) latency=\(String(format: "%.3f", latency))s"
          )
          store.update(id: cand.id) { c in
            if let v = outcome.vehicleView, let score = outcome.viewScore {
              c.updateView(v, score: score)
            }
            if chosenKind == .trafficEye { c.lastMMRTime = now }
          }

          if !outcome.isMatch {
            store.update(id: cand.id) {
              switch chosenKind {
              case .trafficEye: $0.verificationTracker.trafficAttempts += 1
              case .llm: $0.verificationTracker.llmAttempts += 1
              }
            }
          }

          if outcome.isMatch {
            store.update(id: cand.id) {
              $0.detectedDescription = outcome.description
              $0.lastVerified = Date()
            }
            if !self.verificationConfig.shouldRunOCR || outcome.isPlateMatch {
              store.update(id: cand.id) {
                $0.matchStatus = .full
                $0.lastVerified = Date()
              }
              return
            }
            // Promote to partial and begin OCR verification
            store.update(id: cand.id) {
              $0.matchStatus = .partial
              $0.detectedDescription = outcome.description
              $0.lastVerified = Date()
            }
            self.enqueueOCR(
              for: cand, fullImage: fullImage!, imageSize: imageSize, orientation: orientation,
              store: store)
          } else {
            store.update(id: cand.id) {
              // Convert string rejectReason to enum
              let reason = outcome.rejectReason

              // Check if the reason is retryable
              if let reason = reason, reason.isRetryable {
                // Retryable reason - keep searching so candidate will be retried
                $0.matchStatus = .unknown
              } else if reason != nil {
                // Hard reject reason
                $0.matchStatus = .rejected
              }

              $0.rejectReason = reason
              $0.detectedDescription = outcome.description
            }
          }
        }
        .store(in: &cancellables)
    }

  }
}
