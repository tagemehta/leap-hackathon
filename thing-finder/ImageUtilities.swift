//
//  ImageUtilities.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/10/25.
//

import CoreMedia
import SwiftUI

struct ImageUtilities {
  static private var ciImageContext: CIContext = CIContext()

  // https://machinethink.net/blog/bounding-boxes/
  // Bounding boxes are relative to the warped scaleFilled box in 0-1 space
  // assuming .scaleFill/videoGravity=resizeAspectFill.
  static func unscaledBoundingBoxes(
    for normalizedRect: CGRect,
    imageSize: CGSize,  // e.g. (width: CVPixelBufferGetWidth, height: CVPixelBufferGetHeight)
    viewSize: CGSize  // e.g. videoPreview.bounds.size
  ) -> (imageRect: CGRect, viewRect: CGRect) {
    // 1) flip Y & scale normalized → image pixels
    let imgX = normalizedRect.origin.x * imageSize.width
    let imgY = (1 - normalizedRect.origin.y - normalizedRect.height) * imageSize.height
    let imgW = normalizedRect.width * imageSize.width
    let imgH = normalizedRect.height * imageSize.height
    let imageRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)

    // 2) compute the uniform “fill” scale for image → view
    let scale = max(
      viewSize.width / imageSize.width,
      viewSize.height / imageSize.height
    )
    let scaledImageSize = CGSize(
      width: imageSize.width * scale,
      height: imageSize.height * scale
    )

    // 3) compute centering offsets
    let xOffset = (viewSize.width - scaledImageSize.width) / 2
    let yOffset = (viewSize.height - scaledImageSize.height) / 2

    // 4) map image-pixel rect into view-pixel rect
    let viewX = imageRect.minX * scale + xOffset
    let viewY = imageRect.minY * scale + yOffset
    let viewW = imageRect.width * scale
    let viewH = imageRect.height * scale
    let viewRect = CGRect(x: viewX, y: viewY, width: viewW, height: viewH)

    return (imageRect, viewRect)
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
