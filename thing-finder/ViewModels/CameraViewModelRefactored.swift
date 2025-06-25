import ARKit
import AVFoundation
import Combine
import Photos
import SwiftUI
import Vision

/// Refactored CameraViewModel that uses the new protocol-based service architecture
class CameraViewModel: NSObject, ObservableObject, FrameProviderDelegate {

  // MARK: - Published Properties

  /// Bounding boxes to display in the UI
  @MainActor @Published var boundingBoxes: [BoundingBox] = []

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

  /// Confidence filter threshold
  private let CONFIDENCE_FILTER: Float = 0.4

  /// Target classes to detect
  private let targetClasses: [String]

  /// Text description of the target
  private let targetTextDescription: String

  /// Settings for configurable parameters
  private let settings: Settings

  /// LLM verifier for object verification
  private var verifier: LLMVerifier

  /// In-flight verification requests
  private var inflight: [UUID: AnyCancellable] = [:]

  /// Camera service that coordinates all camera-related functionality
  private let cameraService: CameraService

  /// Navigation manager for handling navigation events
  private var navigationManager: NavigationManager

  /// Detection manager for object detection
  private var detectionManager: DetectionManager

  /// Image utilities for image processing
  private var imgUtils: ImageUtilities

  // MARK: - Initialization

  /// Initializes the CameraViewModel with required parameters
  /// - Parameters:
  ///   - targetClasses: Classes to detect
  ///   - targetTextDescription: Text description of the target
  ///   - settings: Application settings
  init(targetClasses: [String], targetTextDescription: String, settings: Settings) {
    self.targetClasses = targetClasses
    self.targetTextDescription = targetTextDescription
    self.verifier = LLMVerifier(
      targetClasses: targetClasses, targetTextDescription: targetTextDescription)
    let mlModel = try! VNCoreMLModel(for: yolo11n(configuration: .init()).model)
    mlModel.featureProvider = ThresholdProvider(iouThreshold: 0.45, confidenceThreshold: 0.25)
    self.settings = settings
    self.detectionManager = DetectionManager(model: mlModel)
    self.navigationManager = NavigationManager(settings: settings)
    self.imgUtils = ImageUtilities()

    // Create camera service using factory
    self.cameraService = ServiceFactory.createCameraService(
      settings: settings,
      navigationManager: navigationManager,
      detectionManager: detectionManager,
      imgUtils: imgUtils
    )

    super.init()

    // Set up publishers
    setupPublishers()

    // Start navigation
    navigationManager.handle(
      .start(targetClasses: targetClasses, targetTextDescription: targetTextDescription))
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
    self.cancelAllInflight()
    // Clear tracking through cameraService
    cameraService.clearTracking()
  }

  // MARK: - Orientation Handling

  /// Handles device orientation changes
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
    _ capture: any FrameProvider, buffer: CVPixelBuffer, depthAt: @escaping (CGPoint) -> Float?,
    imageToViewRect: @escaping (CGRect, (CGSize, CGSize)) -> CGRect
  ) {
    // Update FPS calculation
    cameraService.updateFPSCalculation()

    // Set up frame dimensions and preview view bounds
    setupFrameDimensions(buffer, capture)
    guard let bufferSize = cachedBufferDims, let previewViewBounds = cachedPreviewViewBounds else {
      return
    }

    // Set up scaling option based on capture source type
    let scalingOption: ScalingOptions
    switch capture.sourceType {
    case .arkit:
      scalingOption = .arkit(imgUtils.cgOrientation(for: interfaceOrientation))
    case .avfoundation:
      scalingOption = .avfoundation
    }

    // Handle object tracking
    cameraService.handleObjectTracking(
      buffer: buffer,
      scalingOption: scalingOption
    )

    // Process based on detection state
    switch cameraService.detectionState {
    case .searching:
      // Process candidates for detection
      let candidates = cameraService.performObjectDetection(
        buffer: buffer,
        filter: { observation in
          // Filter observations based on confidence
          guard let label = observation.labels.first else { return false }
          return label.confidence > CONFIDENCE_FILTER && targetClasses.contains(label.identifier)
        },
        scaling: scalingOption
      )

      // Create bounding boxes and identified objects
      var boundingBoxes: [BoundingBox] = []
      var identifiedObjects: [IdentifiedObject] = []
      var frameCGImage: CGImage?

      // Process each candidate
      for observation in candidates {
        // Get the label for the observation
        let label = observation.labels[0].identifier

        // Create a bounding box for the observation
        let box = cameraService.createBoundingBox(
          from: observation,
          bufferSize: bufferSize,
          viewSize: previewViewBounds.size,
          imageToViewRect: imageToViewRect,
          scalingOption: scalingOption,
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
            imageToViewRect: imageToViewRect,
            scalingOption: scalingOption,
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
      var boundingBox: BoundingBox?
      if let observation = observation {
        boundingBox = cameraService.createBoundingBox(
          from: observation,
          bufferSize: bufferSize,
          viewSize: previewViewBounds.size,
          imageToViewRect: imageToViewRect,
          scalingOption: scalingOption,
          label: target.box.label,
          color: .green
        )
      }

      // Calculate distance to target if available using the center point of the view rect
      let distanceMeters: Float? =
        boundingBox != nil
        ? depthAt(CGPoint(x: boundingBox!.viewRect.midX, y: boundingBox!.viewRect.midY)) : nil

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
