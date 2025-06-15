//
//  Debugging.swift
//  thing-finder
//
//  Created by Sam Mehta on 6/15/25.
//

// Goes before the other vision request in detection manager to make sure photos are going in the right orientation
// MARK: - Process image with Image2Image model
//      lazy var visionRequest2: VNCoreMLRequest = {
//        do {
//          let visionModel = try VNCoreMLModel(for: Image2Image().model)
//
//          let request = VNCoreMLRequest(
//            model: visionModel,
//            completionHandler: { [weak self] request, error in
//              if let results = request.results as? [VNPixelBufferObservation],
//                 let pixelBuffer = results.first?.pixelBuffer {
//
//                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
//                let context = CIContext()
//
//                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
//                  let uiImage = UIImage(cgImage: cgImage)
//
//                  // Request permission to save to photo library
//                  PHPhotoLibrary.requestAuthorization { status in
//                    if status == .authorized {
//                      // Save the image to the photo library
//                      PHPhotoLibrary.shared().performChanges({
//                        PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
//                      }) { success, error in
//                        if success {
//                          print("✅ Successfully saved image to photo library")
//                        } else if let error = error {
//                          print("❌ Error saving image to photo library: \(error.localizedDescription)")
//                        }
//                      }
//                    } else {
//                      print("❌ No permission to save to photo library")
//                    }
//                  }
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

// Uncomment the line below to enable image processing and saving
// try handler.perform([visionRequest2])
