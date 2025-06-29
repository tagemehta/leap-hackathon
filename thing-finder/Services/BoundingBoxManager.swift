import SwiftUI
import Vision

/// Protocol defining bounding box creation functionality
protocol BoundingBoxCreator {
  /// Creates a bounding box from a recognized object observation
  /// - Parameters:
  ///   - observation: The recognized object observation
  ///   - bufferSize: The size of the buffer containing the observation
  ///   - viewSize: The size of the view where the bounding box will be displayed
  ///   - imageToViewRect: A function to convert image rectangles to view rectangles
  ///   - scalingOption: The scaling option to use
  ///   - label: The label for the bounding box
  ///   - color: The color for the bounding box
  /// - Returns: A BoundingBox object
  func createBoundingBox(
    from observation: VNDetectedObjectObservation,
    bufferSize: CGSize,
    viewSize: CGSize,
    orientation: CGImagePropertyOrientation,
    label: String,
    color: Color
  ) -> BoundingBox
}

/// Manages the creation and handling of bounding boxes
class BoundingBoxManager: BoundingBoxCreator {
  /// Image utilities for bounding box calculations
  private let imgUtils: ImageUtilities

  /// Initializes the BoundingBoxManager with image utilities
  /// - Parameter imgUtils: Image utilities for bounding box calculations
  init(imgUtils: ImageUtilities) {
    self.imgUtils = imgUtils
  }

  /// Creates a bounding box from a recognized object observation
  /// - Parameters:
  ///   - observation: The recognized object observation
  ///   - bufferSize: The size of the buffer containing the observation
  ///   - viewSize: The size of the view where the bounding box will be displayed
  ///   - imageToViewRect: A function to convert image rectangles to view rectangles
  ///   - scalingOption: The scaling option to use
  ///   - label: The label for the bounding box
  ///   - color: The color for the bounding box
  /// - Returns: A BoundingBox object
  func createBoundingBox(
    from observation: VNDetectedObjectObservation,
    bufferSize: CGSize,
    viewSize: CGSize,
    orientation: CGImagePropertyOrientation,
    label: String,
    color: Color = .yellow
  ) -> BoundingBox {
    // Calculate the image and view rectangles for the bounding box
    let (imgRect, viewRect) = imgUtils.unscaledBoundingBoxes(
      for: observation.boundingBox,
      imageSize: bufferSize,
      viewSize: viewSize,
      orientation: orientation
    )

    // Get the confidence from the observation
    let confidence =
      (observation as? VNRecognizedObjectObservation)?.labels.first?.confidence
      ?? observation.confidence

    // Create and return the bounding box
    return BoundingBox(
      imageRect: imgRect,
      viewRect: viewRect,
      label: label,
      color: color,
      alpha: Double(confidence)
    )
  }
}
