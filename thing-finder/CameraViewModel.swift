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

class CameraViewModel: NSObject, ObservableObject, FrameProviderDelegate {

  // Settings for configurable parameters
  private let settings: Settings

  @MainActor @Published var boundingBoxes: [BoundingBox] = []
  @Published private(set) var currentFPS: Double = 0.0
  var detectionState: DetectionState = DetectionState.searching
  private var interfaceOrientation: UIInterfaceOrientation = UIInterfaceOrientation.portrait
  private var frameTimes: [Date] = []
  private let maxFrameTimes = 10  // Number of frames to average FPS over
  private var colors: [String: UIColor] = [:]

  private let CONFIDENCE_FILTER: Float = 0.4  // Only tracks if it passes llm so send as many as you want
  private let targetClasses: [String]  // User Input: Coco classes we are filtering for
  private let targetTextDescription: String  // User Input: Describe what we are looking for
  private var bufferDims: CGSize?

  private var detectionManager: DetectionManager
  private var navigationManager: NavigationManager

  // Most recent depth frame from LiDAR or stereo camera.
  private var latestDepthData: AVDepthData?
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
    // Reset bufferDims to nil so it will be recalculated on next frame
    bufferDims = nil
    let deviceOrientation = UIDevice.current.orientation
    switch deviceOrientation {
    case .portrait: interfaceOrientation = .portrait
    case .portraitUpsideDown: interfaceOrientation = .portraitUpsideDown
    case .landscapeLeft: interfaceOrientation = .landscapeRight  // Note: these are flipped
    case .landscapeRight: interfaceOrientation = .landscapeLeft  // Note: these are flipped
    default: return  // Ignore face up/down and unknown orientations
    }
  }
  // MARK: - VideoCaptureDelegate
  // MARK: - Unified frame processing
  func processFrame(
    _ capture: any FrameProvider, buffer: CVPixelBuffer, depthAt: @escaping (CGPoint) -> Float?,
    imageToViewRect: @escaping (CGRect, (CGSize, CGSize)) -> CGRect
  ) {
    let scalingOption: ScalingOptions  // Update FPS calculation
    switch capture.sourceType {
    case .arkit:
      scalingOption = .arkit(
        imgUtils.cgOrientation(for: interfaceOrientation))
    case .avfoundation:
      scalingOption = .avfoundation
    }
    let now = Date()
    frameTimes.append(now)
    // Remove timestamps older than 1 second
    frameTimes = frameTimes.filter { now.timeIntervalSince($0) <= 1.0 }

    // Calculate FPS (frames per second)
    if frameTimes.count >= 2 {
      let timeInterval = frameTimes.last!.timeIntervalSince(frameTimes.first!)
      if timeInterval > 0 {
        let fps = Double(frameTimes.count - 1) / timeInterval
        DispatchQueue.main.async {
          self.currentFPS = min(fps, 60.0)  // Cap at 60 FPS which is typical for iOS
        }
      }
    }

    // Store buffer dimensions
    guard let bufferDims = bufferDims else {  // Orientation changed skip a frame to fix buffer size
      let frameWidth = CVPixelBufferGetWidth(buffer)
      let frameHeight = CVPixelBufferGetHeight(buffer)
      bufferDims = CGSize(width: frameWidth, height: frameHeight)
      return
    }

    // Perform all tracking requests
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
          orientation: cgOrientation)  // TODO fix
        activeTracking.removeAll { $0.isLastFrame }
      } catch {
        clearActiveTracking()
        activeTracking.removeAll { $0.isLastFrame }
        print("Tracking error: \(error)")
      }
    }
    var boundingBoxesLocal: [BoundingBox] = []
    let allDetections = detectionManager.detect(
      buffer,
      {
        targetClasses.contains($0.labels[0].identifier)
          && $0.labels[0].confidence * $0.confidence > Float(settings.confidenceThreshold)
      },
      scaling: scalingOption
    )
    // Must appear in 4 consecutive frames
    //    let candidates = detectionManager.stableDetections()
    let candidates = allDetections

    var identifiedObjects: [IdentifiedObject] = []
    var frameCGImage: CGImage?
//    frameCGImage =
//      frameCGImage ?? imgUtils.cvPixelBuffertoCGImage(buffer: buffer)
//      UIImage(cgImage: frameCGImage!).saveToPhotoLibrary { _, _ in
//          print("saved processFrame")
//        }
    //     Capture preview view bounds on main thread
    let previewViewBounds: CGRect
    if Thread.isMainThread {
      previewViewBounds = capture.previewView.bounds
    } else {
      previewViewBounds = DispatchQueue.main.sync {
        capture.previewView.bounds
      }
    }

    for candidate in candidates {
      let (imgRect, viewRect) = imgUtils.unscaledBoundingBoxes(
        for: candidate.boundingBox,
        imageSize: bufferDims,
        viewSize: previewViewBounds.size,
        imageToView: imageToViewRect,
        options: scalingOption
      )

      let label = candidate.labels[0].identifier
      if colors[label] == nil {
        colors[label] = Constants.ultralyticsColors.randomElement() ?? .blue
      }

      let box = BoundingBox(
        imageRect: imgRect,
        viewRect: viewRect,
        label: label,
        color: Color(colors[label]!),
        alpha: Double(candidate.labels[0].confidence)
      )
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
      boundingBoxesLocal.append(box)
    }

    if case .searching = detectionState {
      identifiedObjects.count > 0 ? detectionState = .verifying(candidates: identifiedObjects) : ()
    }

    if detectionState.displayAllBoxes {
      self.updateBoundingBoxes(to: boundingBoxesLocal)
    }

    if case .found(let target) = self.detectionState {
      var targetMut = target
      targetMut.lifetime += 1
      guard let observation = target.trackingRequest.results?.first as? VNDetectedObjectObservation,
        target.lifetime < 700
      else {
        if target.lifetime >= settings.targetLifetime {
          navigationManager.handle(NavEvent.expired)
          self.detectionState = .searching
          self.clearActiveTracking()
        } else if target.lostInTracking > settings.maxLostFrames {
          navigationManager.handle(NavEvent.lost)
          self.detectionState = .searching
          self.clearActiveTracking()
        } else {
          targetMut.box.label += "?"
          targetMut.lostInTracking += 1
          self.detectionState = .found(target: targetMut)
        }
        return
      }

      // -------------------------------------------------------------
      // 1. Early-exit if Vision’s current box clearly doesn’t match the
      //    box from the previous frame (stored in lastBoundingBox).
      // -------------------------------------------------------------

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

      let normalizedBox = observation.boundingBox
      var drifted = false
      if iouPrev < settings.minIouThreshold || centreShift > Float(settings.maxCenterShift)
        || areaShift > Float(settings.maxAreaShift)
        || observation.confidence < Float(settings.minTrackingConfidence)
      {
        drifted = true
      }

      if drifted {
        if target.lostInTracking >= settings.maxLostFrames {
          navigationManager.handle(NavEvent.lost)
          self.detectionState = .searching
          self.clearActiveTracking()
        } else {
          targetMut.box.label += "?"
          targetMut.lostInTracking += 1
          self.detectionState = .found(target: targetMut)
        }
        return
      }

      // Update history for next frame
      targetMut.lastBoundingBox = observation.boundingBox
      let (imgRect, viewRect) = imgUtils.unscaledBoundingBoxes(
        for: normalizedBox,
        imageSize: CGSize(width: bufferDims.width, height: bufferDims.height),
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
      // Distance estimation via latestDepthData (if present)
      // --------------------------------------------------------
      let distanceMeters: Float? = depthAt(CGPoint(x: viewRect.midX, y: viewRect.midY))
      print(distanceMeters)
      navigationManager.handle(
        NavEvent.found, box: observation.boundingBox,
        distanceMeters: (distanceMeters != nil) ? Double(distanceMeters!) : nil)
      self.detectionState = .found(target: targetMut)
    }
  }

  func startVerification(
    for candidate: IdentifiedObject, image: CGImage
  ) {
    guard inflight[candidate.id] == nil, let bufferDims = bufferDims else { return }  // already verifying
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
