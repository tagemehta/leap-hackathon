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
  private let nav: NavigationManagerProtocol
  private let store: CandidateStore
  private let stateMachine: DetectionStateMachine = DetectionStateMachine()
  private let lifecycle: CandidateLifecycleService
  
  private let targetClasses: [String]
  private let targetDescription: String
  // MARK: Publishers
  @Published public private(set) var presentation: FramePresentation?

  // MARK: Init
  public init(
    detector: ObjectDetector,
    tracker: VisionTracker,
    driftRepair: DriftRepairServiceProtocol,
    verifier: VerifierServiceProtocol,
    nav: NavigationManagerProtocol,
    store: CandidateStore = CandidateStore(),
    lifecycle: CandidateLifecycleService,
    targetClasses: [String],
    targetDescription: String
  ) {
    self.detector = detector
    self.tracker = tracker
    self.driftRepair = driftRepair
    self.verifier = verifier
    self.nav = nav
    self.store = store
    self.lifecycle = lifecycle
    self.targetClasses = targetClasses
    self.targetDescription = targetDescription
    nav.handle(.start(targetClasses: targetClasses, targetTextDescription: targetDescription), box: nil, distanceMeters: nil)
  }

  // MARK: Per-frame entry point
  public func process(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    imageSize: CGSize,
    viewBounds: CGRect,
    depthAt: @escaping (CGPoint) -> Float?,
    captureType: CaptureSourceType
  ) {
    // 1. Detection (filter always true for now)
    let detections = detector.detect(
      pixelBuffer,
      filter: { obs in
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
    let isLost = lifecycle.tick(
      pixelBuffer: pixelBuffer, orientation: orientation, imageSize: imageSize,
      detections: detections, store: store)
    // 5. Verifier tick (sets matchStatus)
    verifier.tick(
      pixelBuffer: pixelBuffer,
      orientation: orientation,
      imageSize: imageSize,
      viewBounds: viewBounds,
      store: store
    )

    // If all candidates were removed, notify lost and reset any tracking
    if isLost {
      print(isLost)
      nav.handle(NavEvent.lost, box: nil, distanceMeters: nil)
    }

    // 6. Update global phase
    var machine = stateMachine
    machine.update(snapshot: Array(store.candidates.values))
    let phase = machine.phase

    // 7. Navigation cues (very naïve initial logic)
    switch phase {
    case .found(let id):
      let cand = store.candidates[id]!
      let (imageRect, viewRect) = ImageUtilities.shared.unscaledBoundingBoxes(for: cand.lastBoundingBox, imageSize: imageSize, viewSize: viewBounds.size, orientation: orientation)
      let depth: Float?
      switch captureType {
      case .avFoundation:
        let normalizedBox = VNNormalizedRectForImageRect(
          imageRect, Int(imageSize.width), Int(imageSize.height))
        depth = depthAt(CGPoint(x: normalizedBox.midX, y: normalizedBox.midY))
      case .arKit:
        depth = depthAt(CGPoint(x: viewRect.midX, y: imageRect.midY))
      }
      nav.handle(.found, box: cand.lastBoundingBox, distanceMeters: (depth != nil) ? Double(depth!) : nil)
    case .searching:
      nav.handle(.searching, box: nil, distanceMeters: nil)
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
