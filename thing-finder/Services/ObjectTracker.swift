import CoreImage
import Foundation
import Vision

/// Protocol defining object tracking functionality
protocol ObjectTracker {
  /// Performs tracking on the current frame
  /// - Parameters:
  ///   - buffer: The pixel buffer containing the current frame
  ///   - orientation: The orientation of the image
  /// - Returns: Result containing tracking requests or an error
  func performTracking(on buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Result<
    [VNTrackObjectRequest], Error
  >

  /// Adds a tracking request
  /// - Parameter request: The tracking request to add
  func addTracking(_ request: VNTrackObjectRequest)

  /// Adds multiple tracking requests
  /// - Parameter requests: The tracking requests to add
  func addTracking(_ requests: [VNTrackObjectRequest])

  /// Clears all active tracking requests
  func clearTracking()

  /// Clears all active tracking requests except the specified one
  /// - Parameter keep: The tracking request to keep
  func clearTrackingExcept(_ keep: VNTrackObjectRequest)

  /// Checks if there are any active tracking requests
  var hasActiveTracking: Bool { get }

  /// Creates a tracking request for the given observation
  /// - Parameters:
  ///   - observation: The observation to track
  /// - Returns: The tracking request
  func createTrackingRequest(
    for observation: VNDetectedObjectObservation
  ) -> VNTrackObjectRequest
}
