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

/// Concrete implementation of `VerifierService`.
final class VerifierService: VerifierServiceProtocol {
  private let apiClient: LLMVerifier
  private let imgUtils: ImageUtilities
  private var cancellables: Set<AnyCancellable> = []
  /// Timestamp of the most recent *batch* of verify() requests (i.e., the last tick that sent one or more verify calls).
  private var lastVerifyBatch: Date = .distantPast
  /// Minimum interval between successive batches of verify() requests.
  private let minVerifyInterval: TimeInterval = 1.0  // seconds

  init(apiClient: LLMVerifier, imgUtils: ImageUtilities) {
    self.apiClient = apiClient
    self.imgUtils = imgUtils
  }

  /// Called every frame by `FramePipelineCoordinator`.
  func tick(
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
    if apiClient.targetTextDescription.isEmpty {
      for cand in pendingUnknown {
        store.update(id: cand.id) { $0.matchStatus = .matched }
      }
    } else {
      toVerify = pendingUnknown
    }
    guard !toVerify.isEmpty else { return }

    let now = Date()
    // Rate-limit: if the previous batch was too recent, skip this tick entirely.
    guard now.timeIntervalSince(lastVerifyBatch) >= minVerifyInterval else {
      return
    }

    let fullImage: CGImage = imgUtils.cvPixelBuffertoCGImage(buffer: pixelBuffer)

    lastVerifyBatch = now
    for cand in toVerify {

      // Convert normalized box → pixel rect using ImageUtilities
      let (imageRect, _) = imgUtils.unscaledBoundingBoxes(
        for: cand.lastBoundingBox,
        imageSize: imageSize,
        viewSize: imageSize,  // view size irrelevant here
        orientation: orientation
      )
      guard let crop = fullImage.cropping(to: imageRect) else { continue }

      guard let jpg = UIImage(cgImage: crop).jpegData(compressionQuality: 1) else { continue }

      store.update(id: cand.id) { $0.matchStatus = .waiting }

      apiClient.verify(imageData: jpg.base64EncodedString())
        .sink { completion in
          if case .failure(let err) = completion {
            print("LLM verify error: \(err)")
          }
        } receiveValue: { matched in
          if matched {
            store.update(id: cand.id) { $0.matchStatus = .matched }
          } else {
            store.remove(id: cand.id)
          }
        }
        .store(in: &cancellables)
    }
  }
}
