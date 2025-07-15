//  EmbeddingComputer.swift
//  thing-finder
//
//  Stateless helper that wraps the Vision feature-print request used for
//  computing 128-D embeddings from image crops.  Kept as a lightweight
//  utility (not a full DI service) so callers can be unit-tested easily and
//  we avoid premature abstraction.
//
//  If future requirements demand caching or a different embedding model, this
//  helper can be promoted to a protocol-backed service without touching call
//  sites.

import CoreGraphics
import CoreVideo
import Vision

public enum EmbeddingComputer {
  /// Computes a Vision feature-print embedding for a given `CGImage` crop.
  /// ‑ Returns: `VNFeaturePrintObservation` on success, else `nil`.
  public static func compute(cgImage: CGImage) -> VNFeaturePrintObservation? {
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNGenerateImageFeaturePrintRequest()
    do {
      try handler.perform([request])
      return request.results?.first as? VNFeaturePrintObservation
    } catch {
      return nil
    }
  }

  /// Convenience that crops the pixel buffer using the **normalized** bounding
  /// box and forwards to `compute(cgImage:)`.
  public static func compute(
    cgImage: CGImage,
    boundingBox: CGRect,  // normalised (0-1, Vision)
    orientation: CGImagePropertyOrientation,
    imgUtils: ImageUtilities = .shared,
    imageSize: CGSize
  ) -> VNFeaturePrintObservation? {
    let (imageRect, _) = imgUtils.unscaledBoundingBoxes(
      for: boundingBox,
      imageSize: imageSize,
      viewSize: imageSize, // wrong but doesn't matter because not using
      orientation: orientation
    )
    
    guard let crop = cgImage.cropping(to: imageRect) else { return nil }

    return compute(cgImage: crop)
  }
}
