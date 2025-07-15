//  AppContainer.swift
//  thing-finder
//
//  Central composition root that wires concrete service implementations together.
//  Keeps SwiftUI view-models lean and allows tests to swap services easily.
//
//  Usage (e.g. in CameraViewModel):
//    let coordinator = AppContainer.shared.makePipeline()
//
//  NOTE: Real implementations for detector/tracker/etc. are placeholders here—
//  you can keep using the existing DetectionManager et al. until we migrate.

import Foundation
import Vision

public final class AppContainer {
  static let shared = AppContainer()
  private init() {}

  // Build a fully-wired coordinator for a given capture mode.
  func makePipeline(classes: [String], description: String) -> FramePipelineCoordinator {
    // MARK: Concrete service wiring
    // 1. Detector
    let mlModel: VNCoreMLModel = {
      // Fallback to a lightweight default Vision model if your main CoreML file
      // isn’t bundled yet; replace with actual.
      return try! VNCoreMLModel(for: yolo11n().model)
    }()
    let detector = DetectionManager(model: mlModel)

    // 2. Vision Tracker
    let tracker = TrackingManager()

    // 3. Drift repair using shared ImageUtilities
    let drift = DriftRepairService(imageUtils: ImageUtilities.shared)

    // 4. Verifier – DefaultVerifierService wired with LLMVerifier
    let verifier = VerifierService(
      apiClient: LLMVerifier(targetClasses: classes, targetTextDescription: description),
      imgUtils: ImageUtilities.shared
    )

    // 5. Navigation manager
    let nav = DefaultNavigationManager()

    return FramePipelineCoordinator(
      detector: detector,
      tracker: tracker,
      driftRepair: drift,
      verifier: verifier,
      nav: nav
    )
  }
}
