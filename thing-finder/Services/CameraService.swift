import Combine
import CoreImage
import Foundation
import SwiftUI
import Vision

/// Service that coordinates all camera-related functionality
class CameraService {
  // MARK: - Dependencies

  /// FPS calculator for frame rate management
  private let fpsCalculator: FPSCalculator

  /// Object tracker for tracking detected objects
  private let objectTracker: ObjectTracker

  /// Object detector for detecting objects in frames
  private let objectDetector: ObjectDetector

  /// Bounding box creator for creating bounding boxes
  private let boundingBoxCreator: BoundingBoxCreator

  /// State controller for managing detection state
  private let stateController: StateController

  /// Image utilities for image processing
  private let imgUtils: ImageUtilities

  // MARK: - Initialization

  /// Initializes the camera service with all required dependencies
  /// - Parameters:
  ///   - fpsCalculator: FPS calculator for frame rate management
  ///   - objectTracker: Object tracker for tracking detected objects
  ///   - objectDetector: Object detector for detecting objects in frames
  ///   - boundingBoxCreator: Bounding box creator for creating bounding boxes
  ///   - stateController: State controller for managing detection state
  ///   - imgUtils: Image utilities for image processing
  init(
    fpsCalculator: FPSCalculator,
    objectTracker: ObjectTracker,
    objectDetector: ObjectDetector,
    boundingBoxCreator: BoundingBoxCreator,
    stateController: StateController,
    imgUtils: ImageUtilities
  ) {
    self.fpsCalculator = fpsCalculator
    self.objectTracker = objectTracker
    self.objectDetector = objectDetector
    self.boundingBoxCreator = boundingBoxCreator
    self.stateController = stateController
    self.imgUtils = imgUtils
  }

  // MARK: - Public Methods

  /// Updates FPS calculation
  func updateFPSCalculation() {
    fpsCalculator.updateFPSCalculation()
  }

  /// Gets the current FPS
  var currentFPS: Double {
    return fpsCalculator.currentFPS
  }

  /// Gets the FPS publisher
  var fpsPublisher: AnyPublisher<Double, Never> {
    return fpsCalculator.fpsPublisher
  }

  /// Gets the current detection state
  var detectionState: DetectionState {
    return stateController.detectionState
  }

  /// Gets the detection state publisher
  var detectionStatePublisher: AnyPublisher<DetectionState, Never> {
    return stateController.detectionStatePublisher
  }

  /// Handles object tracking
  /// - Parameters:
  ///   - buffer: The pixel buffer containing the current frame
  ///   - orientation: The orientation of the image
  /// - Returns: Result containing tracking requests or an error
  @discardableResult
  func handleObjectTracking(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
    -> Result<
      [VNTrackObjectRequest], Error
    >
  {
    return objectTracker.performTracking(on: buffer, orientation: orientation)
  }

  /// Forwards LLM verification outcomes to the state controller
  /// - Parameters:
  ///   - candidate: The candidate that was verified
  ///   - matched: Whether the verifier matched the description
  ///   - inflightRemaining: Flag indicating if other verification requests are still running
  /// - Returns: The updated detection state
  @discardableResult
  func handleVerificationResult(
    candidate: IdentifiedObject,
    matched: Bool,
    inflightRemaining: Bool
  ) -> DetectionState {
    return stateController.handleVerificationResult(
      candidate: candidate,
      matched: matched,
      inflightRemaining: inflightRemaining,
      clearTracking: clearTracking,
      clearTrackingExcept: clearTrackingExcept(_:)
    )
  }

  /// Performs object detection
  /// - Parameters:
  ///   - buffer: The pixel buffer containing the frame
  ///   - filter: A filter function to apply to the detections
  ///   - scaling: The scaling option to use
  /// - Returns: An array of recognized object observations
  func performObjectDetection(
    buffer: CVPixelBuffer,
    filter: ((VNRecognizedObjectObservation) -> Bool),
    orientation: CGImagePropertyOrientation
  ) -> [VNRecognizedObjectObservation] {
    return objectDetector.detect(buffer, filter, orientation: orientation)
  }

  /// Creates a bounding box from a recognized object observation
  /// - Parameters:
  ///   - observation: The recognized object observation
  ///   - bufferSize: The size of the buffer containing the observation
  ///   - viewSize: The size of the view where the bounding box will be displayed
  ///   - orientation: The orientation of the image
  ///   - label: The label for the bounding box
  ///   - color: The color for the bounding box
  /// - Returns: A BoundingBox object
  func createBoundingBox(
    from observation: VNDetectedObjectObservation,
    bufferSize: CGSize,
    viewSize: CGSize,
    orientation: CGImagePropertyOrientation,
    label: String,
    color: Color = .yellow
  ) -> BoundingBox {
    return boundingBoxCreator.createBoundingBox(
      from: observation,
      bufferSize: bufferSize,
      viewSize: viewSize,
      orientation: orientation,
      label: label,
      color: color
    )
  }

  /// Processes state transitions
  /// - Parameters:
  ///   - identifiedObjects: Array of identified objects
  ///   - boundingBoxes: Current bounding boxes to display
  ///   - updateBoundingBoxes: Closure to update bounding boxes in the UI
  func processStateTransitions(
    identifiedObjects: [IdentifiedObject],
    boundingBoxes: [BoundingBox],
    updateBoundingBoxes: @escaping ([BoundingBox]) -> Void
  ) {
    stateController.processStateTransitions(
      identifiedObjects: identifiedObjects,
      boundingBoxes: boundingBoxes,
      updateBoundingBoxes: updateBoundingBoxes
    )
  }

  /// Processes a found target
  /// - Parameters:
  ///   - target: The identified object being tracked
  ///   - observation: The detected object observation
  ///   - boundingBox: The bounding box for the target
  ///   - distanceMeters: The estimated distance to the target in meters
  ///   - updateBoundingBoxes: Closure to update bounding boxes in the UI
  /// - Returns: Updated target with new state
  func processFoundTarget(
    target: IdentifiedObject,
    observation: VNDetectedObjectObservation?,
    boundingBox: BoundingBox?,
    distanceMeters: Double?,
    updateBoundingBoxes: @escaping ([BoundingBox]) -> Void
  ) -> IdentifiedObject? {
    return stateController.processFoundTarget(
      target: target,
      observation: observation,
      boundingBox: boundingBox,
      distanceMeters: distanceMeters,
      updateBoundingBoxes: updateBoundingBoxes,
      clearTracking: clearTracking
    )
  }

  /// Adds a tracking request
  /// - Parameter request: The tracking request to add
  func addTracking(_ request: VNTrackObjectRequest) {
    objectTracker.addTracking(request)
  }

  /// Adds multiple tracking requests
  /// - Parameter requests: The tracking requests to add
  func addTracking(_ requests: [VNTrackObjectRequest]) {
    objectTracker.addTracking(requests)
  }

  /// Clears all active tracking requests
  func clearTracking() {
    objectTracker.clearTracking()
  }

  /// Clears all active tracking requests except the specified one
  /// - Parameter keep: The tracking request to keep
  func clearTrackingExcept(_ keep: VNTrackObjectRequest) {
    objectTracker.clearTrackingExcept(keep)
  }

  /// Checks if there are any active tracking requests
  var hasActiveTracking: Bool {
    return objectTracker.hasActiveTracking
  }

  /// Creates a tracking request for an observation
  /// - Parameters:
  ///   - observation: The observation to track
  ///   - handler: The completion handler for the tracking request
  /// - Returns: A tracking request for the observation
  func createTrackingRequest(
    for observation: VNRecognizedObjectObservation
  ) -> VNTrackObjectRequest {
    // Create a tracking request using the global function from ObjectTracker.swift
    return objectTracker.createTrackingRequest(for: observation)
  }

}
