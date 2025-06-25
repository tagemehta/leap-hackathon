import CoreImage
import Foundation
import Vision

/// Protocol defining object detection functionality
protocol ObjectDetector {
  /// Detects objects in a frame
  /// - Parameters:
  ///   - buffer: The pixel buffer containing the frame
  ///   - filter: A filter function to apply to the detections
  ///   - scaling: The scaling option to use
  /// - Returns: An array of recognized object observations
  func detect(
    _ buffer: CVPixelBuffer,
    _ filter: ((VNRecognizedObjectObservation) -> Bool),
    scaling: ScalingOptions
  ) -> [VNRecognizedObjectObservation]

  /// Gets stable detections over consecutive frames
  /// - Returns: An array of recognized object observations that are stable
  func stableDetections(
    iouThreshold: CGFloat,
    requiredConsecutiveFrames: Int
  ) -> [VNRecognizedObjectObservation]
}
