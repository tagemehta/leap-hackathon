//
//  DetectionManager.swift
//  thing-finder
//
//  Created by Sam Mehta on 6/9/25.
//
import AVFoundation
import Photos
import SwiftUI
import Vision

class DetectionManger {
  private var mlModel: VNCoreMLModel
  private var previousDetections: [[VNRecognizedObjectObservation]] = []
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
      if previousDetections.count == 6 {
        previousDetections.remove(at: 0)
        previousDetections.append(filteredResults)
      }
      return filteredResults
    } catch {
      print("Unexpected detection error: \(error).")
      return []
    }
  }
  
  /// Converts a VNRecognizedObjectObservation.boundingBox (norm. units w/ origin at bottom-left)
  /// into a CGRect in your view’s coordinate space, assuming .scaleFill/videoGravity=resizeAspectFill.
  func unscaledBoundingBoxes(
    for normalizedRect: CGRect,
    imageSize:         CGSize,   // e.g. (width: CVPixelBufferGetWidth, height: CVPixelBufferGetHeight)
    viewSize:          CGSize    // e.g. videoPreview.bounds.size
  ) -> (imageRect: CGRect, viewRect: CGRect) {
    // 1) flip Y & scale normalized → image pixels
    let imgX = normalizedRect.origin.x * imageSize.width
    let imgY = (1 - normalizedRect.origin.y - normalizedRect.height) * imageSize.height
    let imgW = normalizedRect.width  * imageSize.width
    let imgH = normalizedRect.height * imageSize.height
    let imageRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)
    
    // 2) compute the uniform “fill” scale for image → view
    let scale = max(
      viewSize.width  / imageSize.width,
      viewSize.height / imageSize.height
    )
    let scaledImageSize = CGSize(
      width:  imageSize.width  * scale,
      height: imageSize.height * scale
    )
    
    // 3) compute centering offsets
    let xOffset = (viewSize.width  - scaledImageSize.width)  / 2
    let yOffset = (viewSize.height - scaledImageSize.height) / 2
    
    // 4) map image-pixel rect into view-pixel rect
    let viewX = imageRect.minX * scale + xOffset
    let viewY = imageRect.minY * scale + yOffset
    let viewW = imageRect.width  * scale
    let viewH = imageRect.height * scale
    let viewRect = CGRect(x: viewX, y: viewY, width: viewW, height: viewH)
    
    return (imageRect, viewRect)
  }

  public func stableDetections(iouThreshold: CGFloat = 0.5, stabilityPercent: Double = 0.7)
    -> [VNRecognizedObjectObservation]
  {
    guard !previousDetections.isEmpty, let lastDetections = previousDetections.last else {
      return []
    }

    let minStableFrames = Int(round(Double(previousDetections.count - 1) * stabilityPercent))

    // For each detection in the last frame, count how many times it appears in previous frames
    return lastDetections.filter { detection in
      var matchCount = 0

      // For each previous frame (excluding the last one)
      for frameIndex in 0..<previousDetections.count - 1 {
        let frameDetections = previousDetections[frameIndex]

        // Check if any detection in this frame matches our current detection
        for frameDetection in frameDetections {
          if detection.boundingBox.iou(with: frameDetection.boundingBox) > iouThreshold {
            matchCount += 1
            break  // Found a match in this frame, move to next frame
          }
        }

        // Early exit if we can't reach the minimum stable frames
        if (matchCount + (previousDetections.count - 2 - frameIndex)) < minStableFrames {
          return false
        }
      }

      return matchCount >= minStableFrames
    }
  }

}

extension CGRect {
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
