import AVFoundation
import Combine
import SwiftUI
import Vision

var mlModel = try! VNCoreMLModel(for: yolo11n(configuration: .init()).model)

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

  @MainActor @Published var boundingBoxes: [BoundingBox] = []
  var detectionState: DetectionState = DetectionState.searching

  private let CONFIDENCE_FILTER: Float = 0.5
  private let GPT_DELAY: TimeInterval = 2
  private let targetClasses: [String]  // User Input: Coco classes we are filtering for
  private let targetTextDescription: String  // User Input: Describe what we are looking for
  private var bufferDims: (width: Int, height: Int)?

  private var detectionManager = DetectionManger(model: mlModel)
  private var navigationManager = NavigationManager()
  private var verifier: LLMVerifier
  private var inflight: [UUID: AnyCancellable] = [:]  // candidate.id ⇒ cancellable
  private var sequenceHandler = VNSequenceRequestHandler()
  private var activeTracking: [VNTrackObjectRequest] = []

  init(targetClasses: [String], targetTextDescription: String) {
    self.targetClasses = targetClasses
    self.targetTextDescription = targetTextDescription
    self.verifier = LLMVerifier(targetTextDescription: targetTextDescription)
  }

  deinit {
    self.cancelAllInflight()
    self.clearActiveTracking()
  }

  public func videoCapture(
    _ capture: VideoCapture, didCaptureVideoFrame sampleBuffer: CMSampleBuffer
  ) {
    if bufferDims == nil {
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
      let frameWidth = Int(CVPixelBufferGetWidth(pixelBuffer))
      let frameHeight = Int(CVPixelBufferGetHeight(pixelBuffer))
      bufferDims = (frameWidth, frameHeight)
    }
    if !activeTracking.isEmpty {
      do {
        try sequenceHandler.perform(activeTracking, on: sampleBuffer)
        activeTracking.removeAll { $0.isLastFrame }
      } catch {
        print("Tracking error: \(error)")
      }
    }
    var boundingBoxesLocal: [BoundingBox] = []
    let allDetections = detectionManager.detect(
      sampleBuffer,
      {
        $0.confidence > CONFIDENCE_FILTER

          && targetClasses.contains($0.labels[0].identifier)
      })
    // Must appear in 4 consecutive frames
    //    let candidates = detectionManager.stableDetections()
    let candidates = allDetections

    if detectionState.displayAllBoxes {
      boundingBoxesLocal = []
      var identifiedObjects: [IdentifiedObject] = []
      var frameCGImage: CGImage?
      for candidate in candidates {

        let (imgRect, viewRect) = ImageUtilities.unscaledBoundingBoxes(
          for:
            candidate.boundingBox,
          imageSize: CGSize(width: bufferDims!.width, height: bufferDims!.height),
          viewSize: capture.previewLayer?.bounds.size ?? .zero)

        let box = BoundingBox(
          imageRect: imgRect,
          viewRect: viewRect,
          label: candidate.labels[0].identifier,
          color: .blue,
          alpha: Double(candidate.confidence))

        //         Verify new detections
        if detectionState == .searching && verifier.timeSinceLastVerification() > GPT_DELAY {
          frameCGImage =
            frameCGImage ?? ImageUtilities.cmSampleBuffertoCGImage(buffer: sampleBuffer)
          let identifiedObject = IdentifiedObject(
            box: box, observation: candidate, trackingRequest: nil)
          startVerification(for: identifiedObject, image: frameCGImage!)
          identifiedObjects.append(identifiedObject)
        }

        boundingBoxesLocal.append(box)
      }
      if identifiedObjects.count > 0 {  // Only runs
        self.detectionState = .verifying(candidates: identifiedObjects)
      }
      self.updateBoundingBoxes(to: boundingBoxesLocal)
    }

    if case .found(let target) = self.detectionState {
      // Track one object
      guard let observation = target.trackingRequest?.results?.first as? VNDetectedObjectObservation
      else {
        // Lost in tracking for 5 frames
        if target.lostInTracking > 4 {
          self.detectionState = .searching
          self.clearActiveTracking()
        } else {
          self.detectionState = .found(
            target: IdentifiedObject(
              box: BoundingBox(
                imageRect: target.box.imageRect,
                viewRect: target.box.viewRect,
                label: target.box.label + "?",
                color: target.box.color,
                alpha: target.box.alpha),
              observation: target.observation,
              trackingRequest: target.trackingRequest,
              lostInTracking: target.lostInTracking + 1))
        }
        return
      }
      // Code to help the tracker be more accurate and not decay
      if allDetections.count > 0 {  // and significantly different box?
              let bestCandidate = detectionManager.findBestOverlap(
                target: observation.boundingBox,
                candidates: allDetections)
              target.trackingRequest?.isLastFrame = true
              let newTrackingReq = VNTrackObjectRequest(detectedObjectObservation: bestCandidate)
              newTrackingReq.trackingLevel = .accurate
              let newIdObj = IdentifiedObject(
                box: target.box,
                observation: bestCandidate,
                trackingRequest: newTrackingReq)
              self.detectionState = .found(target: newIdObj)
              self.activeTracking.append(newTrackingReq)
      }

      let normalizedBox = observation.boundingBox
      let (imgRect, viewRect) = ImageUtilities.unscaledBoundingBoxes(
        for: normalizedBox,
        imageSize: CGSize(width: bufferDims!.width, height: bufferDims!.height),
        viewSize: capture.previewLayer?.bounds.size ?? .zero)
      let box = BoundingBox(
        imageRect: imgRect,
        viewRect: viewRect,
        label: "tracking",
        color: .red,
        alpha: Double(observation.confidence))
      self.updateBoundingBoxes(to: [box])
      navigationManager.navigate(to: box, in: bufferDims!)
    }
  }

  func startVerification(for candidate: IdentifiedObject, image: CGImage) {
    guard inflight[candidate.id] == nil else { return }  // already verifying
    let base64Img = ImageUtilities.cropBoxFromBuffer(
      image: image,
      box: candidate.box.imageRect,
      bufferDims: bufferDims!)

    inflight[candidate.id] = verifier.verify(imageData: base64Img)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] comp in
          print("llm error: \(comp)")
          guard let self = self else { return }
          self.inflight.removeValue(forKey: candidate.id)
          if self.inflight.isEmpty {
            // Redundancy because if it's the last one and being called then it wasn't found
            if case .verifying = self.detectionState {
              self.detectionState = .searching
            }
          }
        },
        receiveValue: { [weak self] matched in
          guard let self = self else { return }
          if matched {
            let trackingReq = VNTrackObjectRequest(detectedObjectObservation: candidate.observation)
            trackingReq.trackingLevel = .accurate
            self.clearActiveTracking()
            let withTracking = IdentifiedObject(
              box: candidate.box, observation: candidate.observation, trackingRequest: trackingReq)
            self.detectionState = .found(target: withTracking)
            self.activeTracking.append(trackingReq)
            self.cancelAllInflight()
          } else {
            print("not matched")
          }
        })
  }

  public func updateBufferDims(width: Int, height: Int) {
    bufferDims = (width, height)
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
