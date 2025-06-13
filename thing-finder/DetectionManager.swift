//
//  DetectionManager.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/9/25.
//
import AVFoundation
import Photos
import SwiftUI
import Vision

class DetectionManger {
  private var mlModel: VNCoreMLModel
  // last processed frame
  private var lastDetections: [VNRecognizedObjectObservation] = []
  /// Stores consecutive-frame counts as a cache
  private var detectionStability: [CGRect: Int] = [:]
  private lazy var visionRequest: VNCoreMLRequest = {
    let request = VNCoreMLRequest(
      model: mlModel
    )
    // NOTE: BoundingBoxView object scaling depends on request.imageCropAndScaleOption https://developer.apple.com/documentation/vision/vnimagecropandscaleoption
    request.imageCropAndScaleOption = .scaleFill  // .scaleFit, .scaleFill, .centerCrop
    return request
  }()
  init(model: VNCoreMLModel) {
    self.mlModel = model
  }

  public func detect(
    _ pixelBuffer: CMSampleBuffer, _ detectionFilterFn: (VNRecognizedObjectObservation) -> Bool
  ) -> [VNRecognizedObjectObservation] {
    // .up becaue the buffer is being appropriately rotated for orientation changes already
    let handler = VNImageRequestHandler(
      cmSampleBuffer: pixelBuffer, orientation: .up, options: [:])
    do {
      // MARK - check input into model
      //      lazy var visionRequest2: VNCoreMLRequest = {
      //        do {
      //          let visionModel = try VNCoreMLModel(for: Image2Image().model)
      //
      //          let request = VNCoreMLRequest(
      //            model: visionModel,
      //            completionHandler: { request, error in
      //              if let results = request.results as? [VNPixelBufferObservation],
      //                let pixelBuffer = results.first?.pixelBuffer
      //              {
      //                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      //                let context = CIContext()
      //                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
      //                  let uiImage = UIImage(cgImage: cgImage)
      //                  print("Start")
      //                  print(uiImage.base64)
      //                  print("end")
      //                } else {
      //                  print("❌ Failed to create CGImage from CIImage")
      //                }
      //              } else if let error = error {
      //                print("❌ Vision request error: \(error.localizedDescription)")
      //              } else {
      //                print("❌ No results and no error")
      //              }
      //            })
      //
      //          request.imageCropAndScaleOption = .scaleFill
      //          return request
      //        } catch {
      //          fatalError("Failed to create VNCoreMLModel: \(error)")
      //        }
      //      }()
      //      try handler.perform([visionRequest2])
      try handler.perform([visionRequest])
      guard let results = visionRequest.results as? [VNRecognizedObjectObservation] else {
        return []
      }
      let filteredResults = results.filter(detectionFilterFn)
      self.lastDetections = filteredResults
      return filteredResults
    } catch {
      print("Unexpected detection error: \(error).")
      return []
    }
  }

  /// Returns detections that have appeared (≈matched by IoU) in *N* consecutive frames.
  /// - Parameters:
  ///   - iouThreshold:  The intersection-over-union threshold that decides whether two boxes refer to the same object.
  ///   - stabilityPercent:  Minimum fraction of the currently buffered frames that a detection must continuously appear in to be considered *stable*.
  ///                        E.g. with a 6-frame buffer and `0.7`, a detection must persist for ≥5 consecutive frames.
  public func stableDetections(
    iouThreshold: CGFloat = 0.8,
    requiredConsecutiveFrames: Int = 4
  ) -> [VNRecognizedObjectObservation] {

    // Compute required consecutive frames (≥ 1).
    // Build a fresh stability map for **this** frame.
    var newStability: [CGRect: Int] = [:]
    var stableObservations: [VNRecognizedObjectObservation] = []

    for detection in lastDetections {
      var consecutive = 1  // At minimum it is present in the current frame.

      // Find any *previous* box that matches this one; if found, extend its streak.
      if let (prevKey, prevCount) = detectionStability.first(where: { (key, _) in
        detection.boundingBox.iou(with: key) > iouThreshold
      }) {
        consecutive = prevCount + 1
        // Remove so it won’t be matched again this iteration.
        detectionStability.removeValue(forKey: prevKey)
      }

      newStability[detection.boundingBox] = consecutive

      if consecutive >= requiredConsecutiveFrames {
        stableObservations.append(detection)
      }
    }

    // Replace map for next call.
    detectionStability = newStability

    return stableObservations
  }
  public func findBestOverlap(target: CGRect, candidates: [VNRecognizedObjectObservation])
    -> VNRecognizedObjectObservation
  {
    precondition(!candidates.isEmpty, "candidates array must not be empty")
    let bestCandidate = candidates.max(
      by: { $0.boundingBox.iou(with: target) < $1.boundingBox.iou(with: target) }
    )
    return bestCandidate!
  }

}

extension CGRect {
  /// Clamps the rectangle's coordinates to be within [0,1] range
  func clampedToUnitBounds() -> CGRect {
    let minX = max(0, min(1, self.minX))
    let minY = max(0, min(1, self.minY))
    let maxX = max(0, min(1, self.maxX))
    let maxY = max(0, min(1, self.maxY))

    // Ensure width and height are not negative
    let width = max(0, maxX - minX)
    let height = max(0, maxY - minY)

    return CGRect(x: minX, y: minY, width: width, height: height)
  }

  func iou(with rect: CGRect) -> CGFloat {
    let intersection = self.intersection(rect)
    let intersectionArea = intersection.width * intersection.height
    let unionArea = width * height + rect.width * rect.height - intersectionArea
    return intersectionArea / unionArea
  }
}

// Add this extension to save to documents directory
//extension UIImage {
//  var base64: String? {
//    self.jpegData(compressionQuality: 1)?.base64EncodedString()
//  }
//}
