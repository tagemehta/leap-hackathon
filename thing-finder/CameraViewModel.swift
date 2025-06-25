import ARKit
import AVFoundation
import Combine
import Photos
import SwiftUI
import Vision

enum DetectionState: Equatable {
  case searching
  case verifying(candidates: [IdentifiedObject])
  case found(target: IdentifiedObject)
  var displayAllBoxes: Bool {
    switch self {
    case .searching: return true
    case .verifying(_): return true
    case .found(_): return false
    }
  }
}

class CameraViewModelLegacy: NSObject, ObservableObject, FrameProviderDelegate {

  // Settings for configurable parameters
  private let settings: Settings

  @MainActor @Published var boundingBoxes: [BoundingBox] = []
  @Published private(set) var currentFPS: Double = 0.0
  var detectionState: DetectionState = DetectionState.searching
  private var interfaceOrientation: UIInterfaceOrientation = UIInterfaceOrientation.portrait
  private var frameTimes: [Date] = []
  private let maxFrameTimes = 10  // Number of frames to average FPS over
  private var colors: [String: UIColor] = [:]
  private var cachedPreviewViewBounds: CGRect?

  private let CONFIDENCE_FILTER: Float = 0.4  // Only tracks if it passes llm so send as many as you want
  private let targetClasses: [String]  // User Input: Coco classes we are filtering for
  private let targetTextDescription: String  // User Input: Describe what we are looking for
  private var cachedBufferDims: CGSize?

  private var detectionManager: DetectionManager
  private var navigationManager: NavigationManager

  // Most recent depth frame from LiDAR or stereo camera.
  private var verifier: LLMVerifier
  private var inflight: [UUID: AnyCancellable] = [:]  // candidate.id ⇒ cancellable
  private var sequenceHandler = VNSequenceRequestHandler()
  private var activeTracking: [VNTrackObjectRequest] = []

  private var imgUtils: ImageUtilities = ImageUtilities()

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
    navigationManager.handle(
      .start(targetClasses: targetClasses, targetTextDescription: targetTextDescription))
  }

  deinit {
    self.cancelAllInflight()
    self.clearActiveTracking()
    // Clean up FPS tracking
    frameTimes.removeAll()
  }

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
  // MARK: - FPS Calculation
  private func updateFPSCalculation() {
    let now = Date()
    frameTimes.append(now)
    // Remove timestamps older than 1 second
    frameTimes = frameTimes.filter { now.timeIntervalSince($0) <= 1.0 }
    calculateAndPublishFPS()
  }

  private func calculateAndPublishFPS() {
    guard frameTimes.count >= 2 else { return }

    let timeInterval = frameTimes.last!.timeIntervalSince(frameTimes.first!)
    if timeInterval > 0 {
      let fps = Double(frameTimes.count - 1) / timeInterval
      DispatchQueue.main.async {
        self.currentFPS = min(fps, 60.0)  // Cap at 60 FPS which is typical for iOS
      }
    }
  }

  // MARK: - Frame Dimensions Setup
  private func setupFrameDimensions(_ buffer: CVPixelBuffer, _ capture: any FrameProvider) {
    // Check and setup buffer dimensions
    if cachedBufferDims == nil {
      // Orientation changed or first frame, initialize buffer dimensions
      let frameWidth = CVPixelBufferGetWidth(buffer)
      let frameHeight = CVPixelBufferGetHeight(buffer)
      self.cachedBufferDims = CGSize(width: frameWidth, height: frameHeight)
    }

    // Check and setup preview view bounds
    if cachedPreviewViewBounds == nil {
      // Only update the bounds once when needed
      if Thread.isMainThread {
        cachedPreviewViewBounds = capture.previewView.bounds
      } else {
        // Still need to get it once, but this won't happen on every frame anymore
        cachedPreviewViewBounds = DispatchQueue.main.sync {
          capture.previewView.bounds
        }
      }
    }
  }

  // MARK: - Object Tracking
  private func handleObjectTracking(_ buffer: CVPixelBuffer, _ scalingOption: ScalingOptions) {
    if !activeTracking.isEmpty {
      do {
        let cgOrientation: CGImagePropertyOrientation
        switch scalingOption {
        case .arkit(let orientation):
          cgOrientation = orientation
        case .avfoundation:
          cgOrientation = .up
        }

        try sequenceHandler.perform(
          activeTracking, on: buffer,
          orientation: cgOrientation)

        // Remove tracking requests that have completed
        activeTracking.removeAll { $0.isLastFrame }
      } catch {
        activeTracking.removeAll { $0.isLastFrame }
        clearActiveTracking()
        print("Tracking error: \(error)")
      }
    }
  }

  // MARK: - Object Detection
  private func performObjectDetection(_ buffer: CVPixelBuffer, _ scalingOption: ScalingOptions)
    -> [VNRecognizedObjectObservation]
  {
    // Detect objects in the frame
    let allDetections = detectionManager.detect(
      buffer,
      {
        targetClasses.contains($0.labels[0].identifier)
          && $0.labels[0].confidence * $0.confidence > Float(settings.confidenceThreshold)
      },
      scaling: scalingOption
    )

    // For stable detection, we could use:
    // return detectionManager.stableDetections()

    // Currently using all detections
    return allDetections
  }

  // MARK: - State-Based Processing

  private func processStateTransitions(
    identifiedObjects: [IdentifiedObject], boundingBoxesLocal: [BoundingBox]
  ) {
    // Update state if we're searching and found candidates
    if case .searching = detectionState {
      identifiedObjects.count > 0 ? detectionState = .verifying(candidates: identifiedObjects) : ()
    }

    // Update UI with bounding boxes if needed
    if detectionState.displayAllBoxes {
      self.updateBoundingBoxes(to: boundingBoxesLocal)
    }
  }

  private func isTargetDrifted(target: IdentifiedObject, observation: VNDetectedObjectObservation)
    -> Bool
  {
    let prevBox = target.lastBoundingBox ?? observation.boundingBox
    let iouPrev = prevBox.iou(with: observation.boundingBox)
    let diagonal = Float(hypot(prevBox.width, prevBox.height))
    let centreShift =
      detectionManager.changeInCenter(
        between: prevBox, and: observation.boundingBox) / diagonal
    let areaPrev = Float(prevBox.width * prevBox.height)
    let areaShift =
      detectionManager.changeInArea(
        between: prevBox, and: observation.boundingBox) / areaPrev

    return iouPrev < settings.minIouThreshold || centreShift > Float(settings.maxCenterShift)
      || areaShift > Float(settings.maxAreaShift)
      || observation.confidence < Float(settings.minTrackingConfidence)
  }

  private func handleTargetLostOrExpired(target: IdentifiedObject) {
    if target.lifetime >= settings.targetLifetime {
      navigationManager.handle(NavEvent.expired)
      self.detectionState = .searching
      self.clearActiveTracking()
    } else if target.lostInTracking > settings.maxLostFrames {
      navigationManager.handle(NavEvent.lost)
      self.detectionState = .searching
      self.clearActiveTracking()
    } else {
      var targetMut = target
      targetMut.box.label += "?"
      targetMut.lostInTracking += 1
      self.detectionState = .found(target: targetMut)
    }
  }

  private func handleTargetDrifted(target: IdentifiedObject) {
    if target.lostInTracking >= settings.maxLostFrames {
      navigationManager.handle(NavEvent.lost)
      self.detectionState = .searching
      self.clearActiveTracking()
    } else {
      var targetMut = target
      targetMut.box.label += "?"
      targetMut.lostInTracking += 1
      self.detectionState = .found(target: targetMut)
    }
  }

  private func processFoundTarget(
    target: IdentifiedObject,
    buffer: CVPixelBuffer,
    bufferDims: CGSize,
    previewViewBounds: CGRect,
    imageToViewRect: @escaping (CGRect, (CGSize, CGSize)) -> CGRect,
    scalingOption: ScalingOptions,
    depthAt: @escaping (CGPoint) -> Float?
  ) {
    var targetMut = target
    targetMut.lifetime += 1
    guard let observation = target.trackingRequest.results?.first as? VNDetectedObjectObservation,
      target.lifetime < 700
    else {
      handleTargetLostOrExpired(target: targetMut)
      return
    }

    // -------------------------------------------------------------
    // 1. Early-exit if Vision's current box clearly doesn't match the
    //    box from the previous frame (stored in lastBoundingBox).
    // -------------------------------------------------------------
    if isTargetDrifted(target: target, observation: observation) {
      handleTargetDrifted(target: targetMut)
      return
    }

    // Update history for next frame
    targetMut.lastBoundingBox = observation.boundingBox
    let (imgRect, viewRect) = imgUtils.unscaledBoundingBoxes(
      for: observation.boundingBox,
      imageSize: bufferDims,
      viewSize: previewViewBounds.size,
      imageToView: imageToViewRect,
      options: scalingOption
    )

    let box = BoundingBox(
      imageRect: imgRect,
      viewRect: viewRect,
      label: "tracking",
      color: .red,
      alpha: Double(observation.confidence))
    self.updateBoundingBoxes(to: [box])

    // --------------------------------------------------------
    // Distance estimation via lidar or arkit (if present)
    // --------------------------------------------------------
    let distanceMeters: Float? = depthAt(CGPoint(x: viewRect.midX, y: viewRect.midY))
    navigationManager.handle(
      NavEvent.found, box: observation.boundingBox,
      distanceMeters: (distanceMeters != nil) ? Double(distanceMeters!) : nil)
    self.detectionState = .found(target: targetMut)
  }

  private func processCandidate(
    candidate: VNRecognizedObjectObservation,
    box: BoundingBox,
    buffer: CVPixelBuffer,
    identifiedObjects: inout [IdentifiedObject],
    frameCGImage: inout CGImage?
  ) {
    // Verify new detections
    // Only verify new detections when we are actively searching. If we are already
    // verifying or have a confirmed (found) target, skip starting another round
    // of verification so the tracker stays locked on the current object.
    switch detectionState {
    case .searching:
      if verifier.timeSinceLastVerification() > settings.verificationCooldown {
        frameCGImage =
          frameCGImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: buffer)
        let trackingReq = VNTrackObjectRequest(detectedObjectObservation: candidate)
        activeTracking.append(trackingReq)
        let identifiedObject = IdentifiedObject(
          box: box, observation: candidate, trackingRequest: trackingReq)
        startVerification(for: identifiedObject, image: frameCGImage!)
        identifiedObjects.append(identifiedObject)
      }
    default:
      break
    }
  }

  // MARK: - Bounding Box Creation
  private func createBoundingBox(
    for candidate: VNRecognizedObjectObservation,
    bufferDims: CGSize,
    previewViewBounds: CGRect,
    imageToViewRect: @escaping (CGRect, (CGSize, CGSize)) -> CGRect,
    scalingOption: ScalingOptions
  ) -> BoundingBox {
    // Calculate image and view rectangles
    let (imgRect, viewRect) = imgUtils.unscaledBoundingBoxes(
      for: candidate.boundingBox,
      imageSize: bufferDims,
      viewSize: previewViewBounds.size,
      imageToView: imageToViewRect,
      options: scalingOption
    )

    // Get or create color for this label
    let label = candidate.labels[0].identifier
    if colors[label] == nil {
      colors[label] = Constants.ultralyticsColors.randomElement() ?? .blue
    }

    // Create and return the bounding box
    return BoundingBox(
      imageRect: imgRect,
      viewRect: viewRect,
      label: label,
      color: Color(colors[label]!),
      alpha: Double(candidate.labels[0].confidence)
    )
  }

  // MARK: - VideoCaptureDelegate
  // MARK: - Unified frame processing
  func processFrame(
    _ capture: any FrameProvider, buffer: CVPixelBuffer, depthAt: @escaping (CGPoint) -> Float?,
    imageToViewRect: @escaping (CGRect, (CGSize, CGSize)) -> CGRect
  ) {
    let scalingOption: ScalingOptions
    switch capture.sourceType {
    case .arkit:
      scalingOption = .arkit(
        imgUtils.cgOrientation(for: interfaceOrientation))
    case .avfoundation:
      scalingOption = .avfoundation
    }

    // Update FPS calculation
    updateFPSCalculation()

    // Setup frame dimensions and preview view bounds
    setupFrameDimensions(buffer, capture)
    guard let bufferDims = cachedBufferDims, let previewViewBounds = cachedPreviewViewBounds else {
      return
    }

    // Perform all tracking requests
    handleObjectTracking(buffer, scalingOption)

    // Perform object detection
    let candidates = performObjectDetection(buffer, scalingOption)
    var boundingBoxesLocal: [BoundingBox] = []
    var identifiedObjects: [IdentifiedObject] = []
    var frameCGImage: CGImage?
    //    frameCGImage =
    //      frameCGImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: buffer)
    //      UIImage(cgImage: frameCGImage!).saveToPhotoLibrary { _, _ in
    //          print("saved processFrame")
    //        }

    // Process each candidate and create bounding boxes
    for candidate in candidates {
      let box = createBoundingBox(
        for: candidate,
        bufferDims: bufferDims,
        previewViewBounds: previewViewBounds,
        imageToViewRect: imageToViewRect,
        scalingOption: scalingOption
      )

      // Process candidate based on current detection state
      processCandidate(
        candidate: candidate,
        box: box,
        buffer: buffer,
        identifiedObjects: &identifiedObjects,
        frameCGImage: &frameCGImage
      )

      boundingBoxesLocal.append(box)
    }

    // Process state transitions and update UI
    processStateTransitions(
      identifiedObjects: identifiedObjects, boundingBoxesLocal: boundingBoxesLocal)

    // Process found target if applicable
    if case .found(let target) = self.detectionState {
      processFoundTarget(
        target: target,
        buffer: buffer,
        bufferDims: bufferDims,
        previewViewBounds: previewViewBounds,
        imageToViewRect: imageToViewRect,
        scalingOption: scalingOption,
        depthAt: depthAt
      )
    }
  }

  func startVerification(
    for candidate: IdentifiedObject, image: CGImage
  ) {
    guard inflight[candidate.id] == nil, let bufferDims = cachedBufferDims else { return }  // already verifying
    let imageRect = candidate.box.imageRect
    let boundSafeBox = CGRect(
      x: max(0, min(imageRect.origin.x, CGFloat(bufferDims.width))),
      y: max(0, min(imageRect.origin.y, CGFloat(bufferDims.height))),
      width: max(0, min(imageRect.width, CGFloat(bufferDims.width) - imageRect.origin.x)),
      height: max(0, min(imageRect.height, CGFloat(bufferDims.height) - imageRect.origin.y))
    )

    guard let croppedImage = image.cropping(to: boundSafeBox) else { return }
    let uiImage = UIImage(cgImage: croppedImage)
    let base64Img = uiImage.jpegData(compressionQuality: 1)?.base64EncodedString() ?? ""
    inflight[candidate.id] = verifier.verify(imageData: base64Img)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] comp in
          print("llm error: \(comp)")
          guard let self = self else { return }
          self.inflight.removeValue(forKey: candidate.id)
          candidate.trackingRequest.isLastFrame = true
          if self.inflight.isEmpty {
            // Redundancy because if it's the last one and being called then it wasn't found
            if case .verifying = self.detectionState {
              navigationManager.handle(.noMatch)
              self.detectionState = .searching
            }
          }
        },
        receiveValue: { [weak self] matched in
          guard let self = self else { return }
          if matched {
            self.clearActiveTracking(except: candidate.trackingRequest)
            let withTracking = IdentifiedObject(
              box: candidate.box, observation: candidate.observation,
              trackingRequest: candidate.trackingRequest,
              imageEmbedding: nil)
            self.detectionState = .found(target: withTracking)
            self.activeTracking.append(candidate.trackingRequest)
            self.cancelAllInflight()
          } else {
            print("not matched")
          }
        })
  }

  private func updateBoundingBoxes(to newBoundingBoxes: [BoundingBox]) {
    DispatchQueue.main.async { [weak self] in
      self?.boundingBoxes = newBoundingBoxes
    }
  }

  private func clearActiveTracking(except keep: VNTrackObjectRequest? = nil) {
    for req in activeTracking where req !== keep {
      req.isLastFrame = true  // tell Vision this is the final frame
    }
  }
  private func cancelAllInflight() {
    self.inflight.values.forEach { $0.cancel() }
    self.inflight.removeAll()
  }
}
