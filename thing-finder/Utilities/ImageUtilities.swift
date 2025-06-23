//
//  ImageUtilities.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/10/25.
//

import ARKit.ARFrame
import CoreMedia
import SwiftUI

class ImageUtilities {
  private var ciImageContext: CIContext = CIContext()

  // https://machinethink.net/blog/bounding-boxes/
  // Bounding boxes are relative to the warped scaleFilled box in 0-1 space
  // assuming .scaleFill/videoGravity=resizeAspectFill.

  /// Maps one Vision box →
  ///   • `imageRect`  – pixel coords in the raw CVPixelBuffer (for cropping)
  ///   • `viewRect`   – pixel coords in the preview view      (for drawing)
  ///
  /// - Parameters:
  ///   - normalizedRect: Vision’s 0-1 rectangle (portrait-up).
  ///   - imageSize:      CGSize(width: CVPixelBufferGetWidth, height: CVPixelBufferGetHeight)
  ///                     *as delivered* by the camera/ARKit.
  ///   - viewSize:       previewView.bounds.size.
  ///   - bufferOri:      The orientation you passed to Vision for *this* buffer
  ///                     (e.g. `.right` when the device is portrait).
  ///   - viewOri:        The UI’s current interface orientation, expressed as
  ///                     a `CGImagePropertyOrientation` (`.up` is safest).
  ///
  func mapBoundingBox(
    boundingBox bbox: CGRect,
    frame: ARFrame,
    viewSize: CGSize,
    uiOrientation: UIInterfaceOrientation
  ) -> (imageRect: CGRect, viewRect: CGRect) {
    // ------------------------------------------------------------------
    // A. Rotate Vision’s box (portrait) -> buffer orientation (.right / .left / .up / .down)
    // ------------------------------------------------------------------
    let cgOri = self.cgOrientation(for: uiOrientation)
    let bufRectBL = self.inverseRotation(bbox, for: cgOri)  // still bottom-left origin

    // ------------------------------------------------------------------
    // B. Flip to TOP-LEFT origin (what CoreGraphics & ARKit expect)
    // ------------------------------------------------------------------
    let bufRectTL = CGRect(
      x: bufRectBL.origin.x,
      y: 1 - bufRectBL.origin.y - bufRectBL.height,
      width: bufRectBL.width,
      height: bufRectBL.height)

    // ------------------------------------------------------------------
    // C. IMAGE-SPACE RECT  (crop from CVPixelBuffer)
    // ------------------------------------------------------------------
    let res = frame.camera.imageResolution  // e.g. 1920 × 1440
    let imgX = bufRectTL.origin.x * CGFloat(res.width)
    let imgY = bufRectTL.origin.y * CGFloat(res.height)
    let imgW = bufRectTL.width * CGFloat(res.width)
    let imgH = bufRectTL.height * CGFloat(res.height)
    let imageRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)

    // ------------------------------------------------------------------
    // D. VIEW-SPACE RECT  (overlay)
    // ------------------------------------------------------------------
    let vpSize = viewSize  // NOT the camera resolution!
    let tx = frame.displayTransform(
      for: uiOrientation,
      viewportSize: vpSize)

    let viewNorm = bufRectTL.applying(tx)  // still 0-1
    let viewRect = CGRect(
      x: viewNorm.origin.x * vpSize.width,
      y: viewNorm.origin.y * vpSize.height,
      width: viewNorm.width * vpSize.width,
      height: viewNorm.height * vpSize.height)

    return (imageRect, viewRect)
  }

  func cgOrientation(for uiOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation
  {
    switch uiOrientation {
    case .portrait: return .right
    case .portraitUpsideDown: return .left
    case .landscapeLeft: return .down
    case .landscapeRight: return .up
    default: return .right
    }
  }

  // MARK: - Rectangle rotation helpers (normalized ↔︎ pixel)
  /**
   Returns a rectangle transformed from upright (Vision) coordinates **to the buffer’s
   coordinate system** when the rectangle is already expressed in *normalised* (0-1)
   space.
   */
  public func inverseRotation(_ r: CGRect, for o: CGImagePropertyOrientation) -> CGRect {
    // https://developer.apple.com/documentation/imageio/cgimagepropertyorientation
    // Converts a rectangle in an upright buffer to the image space buffer
    // If you needed to rotate the buffer right to be upright.
    // Then to go from a box that is upright to one in buffer space you go left
    switch o {
    case .up: return r
    case .down: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)

    case .left:
      return CGRect(
        x: r.minY,
        y: 1 - r.maxX,
        width: r.height,
        height: r.width)

    case .right:
      return CGRect(
        x: 1 - r.maxY,
        y: r.minX,
        width: r.height,
        height: r.width)

    case .upMirrored: return CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    case .downMirrored: return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    case .leftMirrored:
      return CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)
    case .rightMirrored: return CGRect(x: r.minY, y: r.maxX, width: r.height, height: r.width)

    @unknown default: return r
    }
  }

  /**
   Pixel-aware variant of `inverseRotation(_:for:)`.

   - Parameters:
     - r: The rectangle specified in **pixel coordinates** relative to an *upright* image.
     - imageSize: Size of the pixel buffer (width × height in pixels).
     - o: Orientation that the *buffer* must be rotated **to become upright**
           (same meaning as when you call Vision).

   This performs the same logical remapping as the normalised version but uses the
   buffer width/height instead of the unit square so it can be applied directly to
   pixel-space rectangles (e.g. those you want to crop).
   */
  public func inverseRotation(
    _ r: CGRect, in imageSize: CGSize, for o: CGImagePropertyOrientation
  ) -> CGRect {
    let W = imageSize.width
    let H = imageSize.height

    switch o {
    case .up:  // no rotation
      return r

    case .down:  // 180°
      return CGRect(
        x: W - r.maxX,
        y: H - r.maxY,
        width: r.width,
        height: r.height)

    case .left:  // 90° CCW (buffer had to rotate left to be upright ⇒ we rotate right)
      return CGRect(
        x: r.minY,
        y: W - r.maxX,
        width: r.height,
        height: r.width)

    case .right:  // 90° CW
      return CGRect(
        x: H - r.maxY,
        y: r.minX,
        width: r.height,
        height: r.width)

    case .upMirrored:
      return CGRect(
        x: W - r.maxX,
        y: r.minY,
        width: r.width,
        height: r.height)
    case .downMirrored:
      return CGRect(
        x: r.minX,
        y: H - r.maxY,
        width: r.width,
        height: r.height)
    case .leftMirrored:
      return CGRect(
        x: H - r.maxY,
        y: W - r.maxX,
        width: r.height,
        height: r.width)
    case .rightMirrored:
      return CGRect(
        x: r.minY,
        y: r.maxX,
        width: r.height,
        height: r.width)
    @unknown default:
      return r
    }
  }

  /// Convenience wrapper: rotates a *pixel-space* rectangle from buffer → upright.
  public func rotation(_ r: CGRect, in imageSize: CGSize, for o: CGImagePropertyOrientation)
    -> CGRect
  {
    let inv = self.inverseOrientation(o)
    return self.inverseRotation(r, in: imageSize, for: inv)
  }

  public func rotation(_ r: CGRect, for o: CGImagePropertyOrientation) -> CGRect {
    let ori = self.inverseOrientation(o)
    return self.inverseRotation(r, for: ori)
  }

  func unscaledBoundingBoxes(
    for normalizedRect: CGRect,
    imageSize: CGSize,  // e.g. (width: CVPixelBufferGetWidth, height: CVPixelBufferGetHeight)
    viewSize: CGSize,  // e.g. videoPreview.bounds.size
    imageToView: (CGRect, (CGSize, CGSize)) -> CGRect,
    options: ScalingOptions
  ) -> (imageRect: CGRect, viewRect: CGRect) {
    // -----------------------------------------------------------------------------------------
    // A. Vision outputs upright. Rotate back to buffer orientation (if buffer isn't upright)
    // -----------------------------------------------------------------------------------------
    let bufRectBL: CGRect
    switch options {
    case .arkit(let cgOri):
      bufRectBL = self.inverseRotation(normalizedRect, for: cgOri)
    case .avfoundation:
      bufRectBL = normalizedRect
    }

    // ------------------------------------------------------------------
    // B. Flip to TOP-LEFT origin (what CoreGraphics & ARKit expect)
    // ------------------------------------------------------------------
    let bufRectTL = CGRect(
      x: bufRectBL.origin.x,
      y: 1 - bufRectBL.origin.y - bufRectBL.height,
      width: bufRectBL.width,
      height: bufRectBL.height)

    // ------------------------------------------------------------------
    // C. IMAGE-SPACE RECT  (crop from CVPixelBuffer)
    // ------------------------------------------------------------------
    let imageRect = VNImageRectForNormalizedRect(
      bufRectTL, Int(imageSize.width), Int(imageSize.height))
    // ------------------------------------------------------------------
    // D. VIEW-SPACE RECT  (overlay)
    // ------------------------------------------------------------------
    let viewRect: CGRect
    switch options {
    case .arkit(_):
      // For ARKit, bufRectTL is already in the buffer’s orientation.
      viewRect = imageToView(bufRectTL, (imageSize, viewSize))
    case .avfoundation:
      viewRect = imageToView(imageRect, (imageSize, viewSize))
    }
    return (imageRect, viewRect)
  }

  func inverseOrientation(_ ori: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    switch ori {
    case .up: return .down
    case .down: return .up
    case .left: return .right
    case .right: return .left
    case .upMirrored: return .downMirrored
    case .downMirrored: return .upMirrored
    case .leftMirrored: return .rightMirrored
    case .rightMirrored: return .leftMirrored
    @unknown default: return ori
    }
  }

  func cvPixelBuffertoCGImage(buffer: CVPixelBuffer) -> CGImage {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    return self.ciImageContext.createCGImage(ciImage, from: ciImage.extent)!
  }
}

extension UIInterfaceOrientation {
  init(_ deviceOrientation: UIDeviceOrientation) {
    switch deviceOrientation {
    case .portrait: self = .portrait
    case .portraitUpsideDown: self = .portraitUpsideDown
    case .landscapeLeft: self = .landscapeRight
    case .landscapeRight: self = .landscapeLeft
    default: self = .portrait
    }
  }
}

enum ScalingOptions {
  case avfoundation
  case arkit(CGImagePropertyOrientation)
}
