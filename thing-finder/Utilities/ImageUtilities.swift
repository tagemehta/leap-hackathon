//
//  ImageUtilities.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/10/25.
//

import ARKit.ARFrame
import CoreMedia
import SwiftUI

struct ImageUtilities {
  static private var ciImageContext: CIContext = CIContext()

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
  static func mapBoundingBox(
    boundingBox bbox: CGRect,
    frame: ARFrame,
    viewSize: CGSize,
    uiOrientation: UIInterfaceOrientation
  ) -> (imageRect: CGRect, viewRect: CGRect) {
    // ------------------------------------------------------------------
    // A. Rotate Vision’s box (portrait) -> buffer orientation (.right / .left / .up / .down)
    // ------------------------------------------------------------------
    let cgOri = ImageUtilities.cgOrientation(for: uiOrientation)
    let bufRectBL = ImageUtilities.rotate(bbox, to: cgOri)  // still bottom-left origin

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

  static func cgOrientation(for uiOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
          switch uiOrientation {
          case .portrait:           return .right
          case .portraitUpsideDown: return .left
          case .landscapeLeft:      return .down
          case .landscapeRight:     return .up
          default:                  return .right
          }
  }

  static private func rotate(_ r: CGRect, to o: CGImagePropertyOrientation) -> CGRect {
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

  static func cropBoxFromBuffer(image: CGImage, box: CGRect, bufferDims: (width: Int, height: Int))
    -> String
  {
    // Ensure the box is within the bounds of the image
    let boundSafeBox = CGRect(
      x: max(0, min(box.origin.x, CGFloat(bufferDims.width))),
      y: max(0, min(box.origin.y, CGFloat(bufferDims.height))),
      width: max(0, min(box.width, CGFloat(bufferDims.width) - box.origin.x)),
      height: max(0, min(box.height, CGFloat(bufferDims.height) - box.origin.y))
    )

    guard let croppedImage = image.cropping(to: boundSafeBox) else { return "" }
    let uiImage = UIImage(cgImage: croppedImage)
    return uiImage.jpegData(compressionQuality: 1)?.base64EncodedString() ?? ""
  }

  static func cvPixelBuffertoCGImage(buffer: CVPixelBuffer) -> CGImage {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    return ciImageContext.createCGImage(ciImage, from: ciImage.extent)!
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
