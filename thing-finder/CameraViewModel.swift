import AVFoundation
import Combine
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

class CameraViewModel: NSObject, ObservableObject, VideoCaptureDelegate {
  // Settings for configurable parameters
  private let settings: Settings

  @MainActor @Published var boundingBoxes: [BoundingBox] = []
  @Published private(set) var currentFPS: Double = 0.0
  var detectionState: DetectionState = DetectionState.searching

  private var frameTimes: [Date] = []
  private let maxFrameTimes = 10  // Number of frames to average FPS over
  private var colors: [String: UIColor] = [:]

  private let CONFIDENCE_FILTER: Float = 0.4  // Only tracks if it passes llm so send as many as you want
  private let targetClasses: [String]  // User Input: Coco classes we are filtering for
  private let targetTextDescription: String  // User Input: Describe what we are looking for
  private var bufferDims: (width: Int, height: Int)?

  private var detectionManager: DetectionManager
  private var navigationManager: NavigationManager

  // Most recent depth frame from LiDAR or stereo camera.
  private var latestDepthData: AVDepthData?
  private var verifier: LLMVerifier
  private var inflight: [UUID: AnyCancellable] = [:]  // candidate.id ⇒ cancellable
  private var sequenceHandler = VNSequenceRequestHandler()
  private var activeTracking: [VNTrackObjectRequest] = []

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
  }
  // MARK: - VideoCaptureDelegate
  public func onNewData(
    _ capture: VideoCapture,
    imageBuffer: CVPixelBuffer,
    depthData: AVDepthData?
  ) {
    // Update FPS calculation
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
      let frameWidth = Int(CVPixelBufferGetWidth(imageBuffer))
      let frameHeight = Int(CVPixelBufferGetHeight(imageBuffer))
      bufferDims = (frameWidth, frameHeight)
      return
    }

    // Perform all tracking requests
    if !activeTracking.isEmpty {
      do {
        try sequenceHandler.perform(activeTracking, on: imageBuffer)
        activeTracking.removeAll { $0.isLastFrame }
      } catch {
        clearActiveTracking()
        activeTracking.removeAll { $0.isLastFrame }
        print("Tracking error: \(error)")
      }
    }
    var boundingBoxesLocal: [BoundingBox] = []
    let allDetections = detectionManager.detect(
      imageBuffer,
      {
        targetClasses.contains($0.labels[0].identifier)
          && $0.labels[0].confidence * $0.confidence > Float(settings.confidenceThreshold)
      }
    )
    // Must appear in 4 consecutive frames
    //    let candidates = detectionManager.stableDetections()

    let candidates = allDetections
    var identifiedObjects: [IdentifiedObject] = []
    var frameCGImage: CGImage?

    for candidate in candidates {
      let (imgRect, viewRect) = ImageUtilities.unscaledBoundingBoxes(
        for:
          candidate.boundingBox,
        imageSize: CGSize(width: bufferDims.width, height: bufferDims.height),
        viewSize: capture.previewLayer?.bounds.size ?? .zero)
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
            frameCGImage ?? ImageUtilities.cvPixelBuffertoCGImage(buffer: imageBuffer)
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

      let (imgRect, viewRect) = ImageUtilities.unscaledBoundingBoxes(
        for: normalizedBox,
        imageSize: CGSize(width: bufferDims.width, height: bufferDims.height),
        viewSize: capture.previewLayer?.bounds.size ?? .zero)
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
      var distanceMeters: Double? = nil
      if let depthData = depthData {
        let depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthBuf = depth.depthDataMap
        CVPixelBufferLockBaseAddress(depthBuf, .readOnly)
        let w = CVPixelBufferGetWidth(depthBuf)
        let h = CVPixelBufferGetHeight(depthBuf)
        let centerX = Int(min(max(0, Int(normalizedBox.midX * CGFloat(w))), w - 1))
        let centerY = Int(min(max(0, Int((1 - normalizedBox.midY) * CGFloat(h))), h - 1))
        if let base = CVPixelBufferGetBaseAddress(depthBuf) {
          let rowBytes = CVPixelBufferGetBytesPerRow(depthBuf)
          let ptr = base.advanced(by: centerY * rowBytes + centerX * MemoryLayout<Float32>.size)
          let val = ptr.load(as: Float32.self)
          if val.isFinite && val > 0 {
            distanceMeters = Double(val)
          }
        }
        CVPixelBufferUnlockBaseAddress(depthBuf, .readOnly)
      }
      navigationManager.handle(
        NavEvent.found, box: box, in: bufferDims, distanceMeters: distanceMeters)
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
