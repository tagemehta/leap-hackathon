import Combine
import SwiftUI
import Vision

/// A view model that manages the camera feed, object detection, and user interface updates.
///
/// This class coordinates between the camera feed, object detection services, and the UI.
/// It handles frame processing, object tracking, and state management while ensuring
/// thread safety and memory efficiency.
///
class CameraViewModel: NSObject, ObservableObject, FrameProviderDelegate {

  // MARK: - Dependencies

  private let dependencies: CameraDependencies
  private let cameraService: CameraService
  private let verifier: LLMVerifier

  // MARK: - Published Properties

  /// Bounding boxes to display in the UI
  @Published var boundingBoxes: [BoundingBox] = []

  /// Current FPS value
  @Published private(set) var currentFPS: Double = 0.0

  // MARK: - Private Properties

  /// Interface orientation
  private var interfaceOrientation: UIInterfaceOrientation = .portrait

  /// Colors for different object classes
  private var colors: [String: UIColor] = [:]

  /// Cached preview view bounds
  private var cachedPreviewViewBounds: CGRect?

  /// Cached buffer dimensions
  private var cachedBufferDims: CGSize?

  /// In-flight verification requests
  private var inflight: [UUID: AnyCancellable] = [:]

  /// Confidence filter threshold
  private let CONFIDENCE_FILTER: Float = 0.4

  /// Target classes to detect
  private var targetClasses: [String] { dependencies.targetClasses }

  /// Text description of the target
  private var targetTextDescription: String { dependencies.targetTextDescription }

  /// Settings for configurable parameters
  private var settings: Settings { dependencies.settings }

  /// Navigation manager for handling navigation events
  private var navigationManager: NavigationManager { dependencies.navigationManager }

  /// Detection manager for object detection
  private var detectionManager: DetectionManager { dependencies.detectionManager }

  /// Image utilities for image processing
  private var imgUtils: ImageUtilities { dependencies.imageUtils }

  // MARK: - Initialization

  /// Initializes the CameraViewModel with required parameters
  /// - Parameter dependencies: Container for all required dependencies
  init(dependencies: CameraDependencies) {
    self.dependencies = dependencies
    self.verifier = LLMVerifier(
      targetClasses: dependencies.targetClasses,
      targetTextDescription: dependencies.targetTextDescription
    )

    // Create camera service using factory
    self.cameraService = ServiceFactory.createCameraService(
      settings: dependencies.settings,
      navigationManager: dependencies.navigationManager,
      detectionManager: dependencies.detectionManager,
      imgUtils: dependencies.imageUtils
    )

    super.init()

    // Set up publishers
    setupPublishers()
  }

  /// Convenience initializer for backward compatibility
  convenience init(targetClasses: [String], targetTextDescription: String, settings: Settings) {
    self.init(
      dependencies: .makeDefault(
        targetClasses: targetClasses,
        targetTextDescription: targetTextDescription,
        settings: settings
      )
    )
  }

  /// Sets up publishers for FPS and detection state
  private func setupPublishers() {
    // Subscribe to FPS updates
    cameraService.fpsPublisher
      .receive(on: DispatchQueue.main)
      .assign(to: &$currentFPS)

  }

  /// Cancellables for storing subscriptions
  private var cancellables = Set<AnyCancellable>()

  /// Clean up resources when the view model is deallocated
  deinit {
    // Operations on main actor must be dispatched asynchronously from a non-isolated context.
    self.cancelAllInflight()
    self.cameraService.clearTracking()

  }

  // MARK: - Orientation Handling

  /// Handles device orientation changes
  /// Handles device orientation changes and updates the UI accordingly.
  ///
  /// This method should be called when the device orientation changes.
  /// It ensures that the camera feed and UI elements are properly oriented.
  func handleOrientationChange() {
    // Reset bufferDims and cachedPreviewViewBounds to nil so they will be recalculated on next frame
    cachedBufferDims = nil
    cachedPreviewViewBounds = nil
    let deviceOrientation = UIDevice.current.orientation
    switch deviceOrientation {
    case .portrait: interfaceOrientation = .portrait
    case .portraitUpsideDown: interfaceOrientation = .portraitUpsideDown
    case .landscapeLeft: interfaceOrientation = .landscapeRight  // Note: these are flipped
    case .landscapeRight: interfaceOrientation = .landscapeLeft  // Note: these are flipped
    default: return  // Ignore face up/down and unknown orientations
    }
  }

  // MARK: - Frame Processing

  /// Processes a frame from the camera
  /// - Parameters:
  ///   - capture: The frame provider
  ///   - buffer: The pixel buffer containing the current frame
  ///   - depthAt: Function to get depth at a specific point
  ///   - imageToViewRect: Function to convert image rectangles to view rectangles
  func processFrame(
    _ capture: any FrameProvider, buffer: CVPixelBuffer, depthAt: @escaping (CGPoint) -> Float?
  ) {
    // Update FPS calculation
    cameraService.updateFPSCalculation()

    // Set up frame dimensions and preview view bounds
    setupFrameDimensions(buffer, capture)
    guard let bufferSize = cachedBufferDims, let previewViewBounds = cachedPreviewViewBounds else {
      return
    }

    // Get the orientation based on interface orientation
    let orientation = imgUtils.cgOrientation(for: interfaceOrientation)

    // Handle object tracking
    cameraService.handleObjectTracking(
      buffer: buffer,
      orientation: orientation
    )

    // Process based on detection state
    switch cameraService.detectionState {
    case .searching:
      // Process candidates for detection
      let candidates = cameraService.performObjectDetection(
        buffer: buffer,
        filter: { [weak self] (observation: VNRecognizedObjectObservation) -> Bool in
          // Filter observations based on confidence
          guard let self = self,
            let label = observation.labels.first
          else {
            return false
          }
          return label.confidence > CONFIDENCE_FILTER
            && self.targetClasses.contains(label.identifier)
        },
        orientation: orientation
      )

      // Create bounding boxes and identified objects
      var boundingBoxes: [BoundingBox] = []
      var identifiedObjects: [IdentifiedObject] = []
      var frameCGImage: CGImage?
      //            frameCGImage = frameCGImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: buffer)
      //            UIImage(cgImage: frameCGImage!).saveToPhotoLibrary { _, _ in
      //              print("saved")
      //            }
      // Process each candidate
      for observation in candidates {
        // Get the label for the observation
        let label = observation.labels[0].identifier

        // Create a bounding box for the observation
        let box = cameraService.createBoundingBox(
          from: observation,
          bufferSize: bufferSize,
          viewSize: previewViewBounds.size,
          orientation: orientation,
          label: label
        )

        // Process candidate based on current detection state
        // Only verify new detections when we are actively searching
        if verifier.timeSinceLastVerification() > settings.verificationCooldown {
          // Create a tracking request for the observation
          let trackingRequest = cameraService.createTrackingRequest(
            for: observation
          )

          // Add the tracking request
          cameraService.addTracking(trackingRequest)

          // Create identified object
          let identifiedObject = IdentifiedObject(
            box: box,
            observation: observation,
            trackingRequest: trackingRequest,
            imageEmbedding: nil
          )

          // Start verification
          frameCGImage = frameCGImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: buffer)
          if let image = frameCGImage {
            startVerification(for: identifiedObject, image: image)
          }

          identifiedObjects.append(identifiedObject)
        }

        // Always add the bounding box
        boundingBoxes.append(box)
      }

      // Process state transitions
      cameraService.processStateTransitions(
        identifiedObjects: identifiedObjects,
        boundingBoxes: boundingBoxes,
        updateBoundingBoxes: { [weak self] newBoxes in
          self?.updateBoundingBoxes(to: newBoxes)
        }
      )
      // Should probably be moved to the processStateTransitions
      if identifiedObjects.count > 0 {
        cameraService.handleObjectTracking(
          buffer: buffer,
          orientation: orientation
        )
      }

    case .verifying(let candidates):
      // When in verifying state, we don't need to process candidates again
      // Just display the bounding boxes for the candidates
      var boundingBoxesLocal: [BoundingBox] = []

      for candidate in candidates {
        if let observation = candidate.trackingRequest.results?.first
          as? VNDetectedObjectObservation
        {
          let box = cameraService.createBoundingBox(
            from: observation,
            bufferSize: bufferSize,
            viewSize: previewViewBounds.size,
            orientation: orientation,
            label: candidate.box.label,
            color: .yellow
          )
          boundingBoxesLocal.append(box)
        } else {
          boundingBoxesLocal.append(candidate.box)
        }
      }
      // Update bounding boxes
      updateBoundingBoxes(to: boundingBoxesLocal)

    case .found(let target):
      // Get the observation from the tracking request
      let observation = target.trackingRequest.results?.first as? VNDetectedObjectObservation
      // Create a bounding box for the observation if available
//      var boundingBox: BoundingBox?
      if let observation = observation {
        let boundingBox = cameraService.createBoundingBox(
          from: observation,
          bufferSize: bufferSize,
          viewSize: previewViewBounds.size,
          orientation: orientation,
          label: target.box.label,
          color: .green
        )
        let distanceMeters: Float?
        // Calculate distance to target if available using the center point of the view rect
        switch capture.sourceType {
        case .avfoundation:
          let normalizedBox = VNNormalizedRectForImageRect(
            boundingBox.imageRect, Int(bufferSize.width), Int(bufferSize.height))
          distanceMeters = depthAt(CGPoint(x: normalizedBox.midX, y: normalizedBox.midY))
        case .arkit:
          distanceMeters = depthAt(CGPoint(x: boundingBox.viewRect.midX, y: boundingBox.viewRect.midY))
        }
        // Process the found target
        let _ = cameraService.processFoundTarget(
          target: target,
          observation: observation,
          boundingBox: boundingBox,
          distanceMeters: distanceMeters == nil ? nil : Double(distanceMeters!),
          updateBoundingBoxes: { [weak self] newBoxes in
            self?.updateBoundingBoxes(to: newBoxes)
          }
        )
      } else {
        let _ = cameraService.processFoundTarget(target: target, observation: nil, boundingBox: nil, distanceMeters: nil, updateBoundingBoxes: { [weak self] newBoxes in
          self?.updateBoundingBoxes(to: newBoxes)
        })
      }



    }
  }

  // MARK: - Helper Methods

  /// Sets up frame dimensions
  /// - Parameters:
  ///   - buffer: The pixel buffer
  ///   - capture: The frame provider
  private func setupFrameDimensions(_ buffer: CVPixelBuffer, _ capture: any FrameProvider) {
    // Cache buffer dimensions if needed
    if cachedBufferDims == nil {
      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      cachedBufferDims = CGSize(width: width, height: height)
    }

    // Cache preview view bounds if needed
    if cachedPreviewViewBounds == nil {
      if Thread.isMainThread {
        cachedPreviewViewBounds = capture.previewView.bounds
      } else {
        DispatchQueue.main.sync {
          cachedPreviewViewBounds = capture.previewView.bounds
        }
      }
    }
  }

  /// Starts verification for a candidate
  /// - Parameters:
  ///   - candidate: The candidate to verify
  ///   - image: The image containing the candidate
  private func startVerification(for candidate: IdentifiedObject, image: CGImage) {
    // Skip if already verifying this candidate
    if self.targetTextDescription == "" {
      _ = self.cameraService.handleVerificationResult(
        candidate: candidate,
        matched: true,
        inflightRemaining: false  // always false
      )
      return
    }
    guard inflight[candidate.id] == nil, let bufferDims = cachedBufferDims else { return }

    // Get the image rectangle and create a safe bounding box
    let imageRect = candidate.box.imageRect
    let boundSafeBox = CGRect(
      x: max(0, min(imageRect.origin.x, CGFloat(bufferDims.width))),
      y: max(0, min(imageRect.origin.y, CGFloat(bufferDims.height))),
      width: max(0, min(imageRect.width, CGFloat(bufferDims.width) - imageRect.origin.x)),
      height: max(0, min(imageRect.height, CGFloat(bufferDims.height) - imageRect.origin.y))
    )

    // Crop the image to the bounding box
    guard let croppedImage = image.cropping(to: boundSafeBox) else { return }
    let uiImage = UIImage(cgImage: croppedImage)
    //    uiImage.saveToPhotoLibrary { _, _ in
    //
    //    }
    let base64Img = uiImage.jpegData(compressionQuality: 1)?.base64EncodedString() ?? ""

    // Start verification
    inflight[candidate.id] = verifier.verify(imageData: base64Img)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self = self else { return }
          print("LLM verification error: \(completion)")
          self.inflight.removeValue(forKey: candidate.id)
          // Mark the tracking request as complete
          candidate.trackingRequest.isLastFrame = true
          // If no more inflight requests, notify state controller
          if self.inflight.isEmpty {
            _ = self.cameraService.handleVerificationResult(
              candidate: candidate,
              matched: false,
              inflightRemaining: false
            )
          }
        },
        receiveValue: { [weak self] matched in
          guard let self = self else { return }

          // Remove this request from inflight
          self.inflight.removeValue(forKey: candidate.id)

          // Update state based on verification result
          _ = self.cameraService.handleVerificationResult(
            candidate: candidate,
            matched: matched,
            inflightRemaining: !self.inflight.isEmpty
          )

          // If matched, cancel any other pending verifications
          if matched {
            self.cancelAllInflight()
          }
        })
  }

  /// Updates the bounding boxes in the UI
  /// - Parameter newBoundingBoxes: The new bounding boxes to display
  private func updateBoundingBoxes(to newBoundingBoxes: [BoundingBox]) {
    DispatchQueue.main.async { [weak self] in
      self?.boundingBoxes = newBoundingBoxes
    }
  }

  // Removed clearActiveTracking method - now using ObjectTracker through cameraService

  /// Cancels all in-flight verification requests
  private func cancelAllInflight() {
    self.inflight.values.forEach { $0.cancel() }
    self.inflight.removeAll()
  }
}
