//  FramePipelineCoordinator.swift
//  thing-finder
//
//  Coordinates the per-frame flow:
//  1. Detection → new Vision observations
//  2. VisionTracker tick → updates candidate bounding boxes
//  3. DriftRepairService tick (every N frames)
//  4. VerifierService tick (LLM)
//  5. State reducer → DetectionPhase update
//  6. NavigationManager reacts
//  7. Publishes FramePresentation for UI
//
//  NOTE: This is an initial skeleton focused on wiring. Concrete queue/
//  threading decisions will come later.

import Combine
import CoreMedia
import Foundation
import Vision

/// High-level value passed to SwiftUI for rendering overlays.
public struct FramePresentation {
  public let phase: DetectionPhase
  public let candidates: [Candidate]
}

/// Dependency-injected coordinator – pure Swift logic, testable.
public final class FramePipelineCoordinator: ObservableObject {
  // MARK: Services
  private let detector: ObjectDetector
  private let tracker: VisionTracker
  private let driftRepair: DriftRepairServiceProtocol
  private let verifier: VerifierServiceProtocol
  private let nav: NavigationManager
  private let store: CandidateStore
  private let stateMachine: DetectionStateMachine = DetectionStateMachine()

  // MARK: Publishers
  @Published public private(set) var presentation: FramePresentation?

  // MARK: Init
  public init(
    detector: ObjectDetector,
    tracker: VisionTracker,
    driftRepair: DriftRepairServiceProtocol,
    verifier: VerifierServiceProtocol,
    nav: NavigationManager,
    store: CandidateStore = CandidateStore()
  ) {
    self.detector = detector
    self.tracker = tracker
    self.driftRepair = driftRepair
    self.verifier = verifier
    self.nav = nav
    self.store = store
  }

  // MARK: Per-frame entry point
  public func process(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    imageSize: CGSize,
    viewBounds: CGRect,
    targetClasses: [String]
  ) {
    // 1. Detection (filter always true for now)
    let detections = detector.detect(pixelBuffer, filter: { obs in
      targetClasses.contains(obs.labels.first?.identifier ?? "")
    }, orientation: orientation)

    // 2. Vision tracking updates existing candidates
    tracker.tick(pixelBuffer: pixelBuffer, orientation: orientation, store: store)

    // 3. Drift repair (may/no-op depending on stride)
    driftRepair.tick(
      pixelBuffer: pixelBuffer,
      orientation: orientation,
      imageSize: imageSize,
      viewBounds: viewBounds,
      detections: detections,
      store: store
    )

    // 4. Upsert fresh detections that are not overlapping existing candidates
    var cgImage: CGImage?
    for det in detections {
      // Check for duplicates using both IoU and center distance checks
      if !store.containsDuplicateOf(det.boundingBox) {
        let req = VNTrackObjectRequest(detectedObjectObservation: det)
        req.trackingLevel = .accurate
        // Compute initial embedding for robustness in drift-repair & verifier
        if cgImage == nil {
          cgImage = ImageUtilities.shared.cvPixelBuffertoCGImage(buffer: pixelBuffer)
        }
        let emb = EmbeddingComputer.compute(
          cgImage: cgImage!,
          boundingBox: det.boundingBox,
          orientation: orientation,
          imgUtils: ImageUtilities.shared,
          imageSize: imageSize
        )
        let cand = Candidate(
          trackingRequest: req,
          boundingBox: det.boundingBox,
          embedding: emb
        )
        store.upsert(cand)
      }
    }

    // 5. Verifier tick (sets matchStatus)
    verifier.tick(
      pixelBuffer: pixelBuffer,
      orientation: orientation,
      imageSize: imageSize,
      viewBounds: viewBounds,
      store: store
    )

    // 5b. Ensure only ONE matched candidate remains (latest wins)
    let matched = store.candidates.values.filter { $0.isMatched }
    if let winner = matched.max(by: { $0.lastUpdated < $1.lastUpdated }) {
      for (id, _) in store.candidates where id != winner.id {
        store.remove(id: id)
      }
    }

    // 5c. Out-of-frame / drift handling – drop candidates that no longer overlap any detection
    let missThreshold = 5 // frames
    for (id, cand) in store.candidates {
      // ignore if candidate was just inserted this frame (has embedding maybe recent?)
      let overlapsDet = detections.contains { det in
        det.boundingBox.iou(with: cand.lastBoundingBox) > 0.1
      }
      if overlapsDet {
        store.update(id: id) { $0.missCount = 0 }
      } else {
        store.update(id: id) { $0.missCount += 1 }
        if let updated = store[id], updated.missCount >= missThreshold {
          store.remove(id: id)
        }
      }
    }

    // If all candidates were removed, notify lost and reset any tracking
    if store.candidates.isEmpty {
      nav.handle(NavEvent.lost, box: nil, distanceMeters: nil)
    }

    // 6. Update global phase
    var machine = stateMachine
    machine.update(snapshot: Array(store.candidates.values))
    let phase = machine.phase

    // 7. Navigation cues (very naïve initial logic)
    switch phase {
    case .found(let id):
      let cand = store.candidates[id]
      nav.handle(.found, box: cand?.lastBoundingBox, distanceMeters: nil)
    case .searching:
      nav.handle(.lost, box: nil, distanceMeters: nil)
    case .verifying:
      break
//      nav.handle(.noMatch, box: nil, distanceMeters: nil)
    }

    // 8. Publish for UI
    presentation = FramePresentation(
      phase: phase,
      candidates: Array(store.candidates.values)
    )
  }
}
