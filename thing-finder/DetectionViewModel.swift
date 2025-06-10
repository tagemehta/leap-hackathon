import AVFoundation
//
//  DetectionViewModel.swift
//  thing-finder
//
//  Created by Sam Mehta on 6/9/25.
//
import SwiftUI
import Vision

var mlModel = try! VNCoreMLModel(for: yolo11n(configuration: .init()).model)

class DetectionViewModel: ObservableObject, VideoCaptureDelegate {

  @MainActor @Published var boundingBoxes: [BoundingBox] = []

  private var detectionManager = DetectionManger(model: mlModel)
  private let CONFIDENCE: Float = 0.5
  private let targetClasses: [String]
  private var bufferDims: (width: Int, height: Int)?
  init(targetClasses: [String]) {
    self.targetClasses = targetClasses
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
    var boundingBoxesLocal: [BoundingBox] = []
    let detections = detectionManager.detect(
      sampleBuffer,
      {
        $0.confidence > CONFIDENCE
        // && targetClasses.contains($0.labels[0].identifier)
      })
    
    detections.forEach({
      let unscaledRect = detectionManager.unscaledBoundingBoxes(for:
        $0.boundingBox,
        imageSize: CGSize(width: bufferDims!.width, height: bufferDims!.height),
        viewSize: capture.previewLayer?.bounds.size ?? .zero)
      boundingBoxesLocal.append(
        BoundingBox(
          imageRect: unscaledRect.0, viewRect: unscaledRect.1, label: $0.labels[0].identifier, color: .red,
          alpha: Double($0.confidence)))
    })
    DispatchQueue.main.async {
      self.boundingBoxes = boundingBoxesLocal
    }

  }

  public func updateBufferDims(width: Int, height: Int) {
    bufferDims = (width, height)
  }
}
