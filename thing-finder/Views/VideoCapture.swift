//  Ultralytics YOLO 🚀 - AGPL-3.0 License
//
//  Video Capture for Ultralytics YOLOv8 Preview on iOS
//  Part of the Ultralytics YOLO app, this file defines the VideoCapture class to interface with the device's camera,
//  facilitating real-time video capture and frame processing for YOLOv8 model previews.
//  Licensed under AGPL-3.0. For commercial use, refer to Ultralytics licensing: https://ultralytics.com/license
//  Access the source code: https://github.com/ultralytics/yolo-ios-app
//
//  This class encapsulates camera initialization, session management, and frame capture delegate callbacks.
//  It dynamically selects the best available camera device, configures video input and output, and manages
//  the capture session. It also provides methods to start and stop video capture and delivers captured frames
//  to a delegate implementing the VideoCaptureDelegate protocol.

import AVFoundation
import Combine
import CoreVideo
import SwiftUI
import UIKit

// Defines the protocol for handling video frame capture events.
public protocol VideoCaptureDelegate: AnyObject {
  func onNewData(_ capture: VideoCapture, imageBuffer: CVPixelBuffer, depthData: AVDepthData?)
}

// Identifies the best available camera device based on user preferences and device capabilities.
func bestCaptureDevice() -> AVCaptureDevice {
  if let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
    print("LiDAR depth camera found")
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInTelephotoCamera, for: .video, position: .back)
  {
    print("telephoto")
    return device
  } else if let device = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
    print("dual")
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInWideAngleCamera, for: .video, position: .back)
  {
    print("wide angle")
    return device
  } else {
    fatalError("Expected back camera device is not available.")
  }
}

public class VideoCapture: NSObject {
  public var previewLayer: AVCaptureVideoPreviewLayer?
  public weak var delegate: VideoCaptureDelegate?

  let captureDevice = bestCaptureDevice()
  let captureSession = AVCaptureSession()
  let videoOutput = AVCaptureVideoDataOutput()
  /// High-resolution still capture.
  var cameraOutput = AVCapturePhotoOutput()
  /// Depth / disparity capture (LiDAR or dual-camera).
  private let depthOutput = AVCaptureDepthDataOutput()
  let queue = DispatchQueue(label: "camera-queue")
  private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
  // Configures the camera and capture session with optional session presets.
  public func setUp(
    sessionPreset: AVCaptureSession.Preset = .photo, completion: @escaping (Bool) -> Void
  ) {
    queue.async {
      let success = self.setUpCamera(sessionPreset: sessionPreset)
      DispatchQueue.main.async {
        completion(success)
      }
    }
  }

  // Internal method to configure camera inputs, outputs, and session properties.
  private func setUpCamera(sessionPreset: AVCaptureSession.Preset) -> Bool {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = sessionPreset

    guard let videoInput = try? AVCaptureDeviceInput(device: captureDevice) else {
      return false
    }

    if captureSession.canAddInput(videoInput) {
      captureSession.addInput(videoInput)
    }

    let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.videoGravity = .resizeAspectFill
    // Possible bug here
    self.updateVideoOrientation()
    self.previewLayer = previewLayer

    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]

    videoOutput.videoSettings = settings
    videoOutput.alwaysDiscardsLateVideoFrames = true
    // videoOutput.setSampleBufferDelegate(self, queue: queue)
    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }
    // First ensure video output is properly connected
    guard videoOutput.connection(with: .video) != nil else {
      print("Error: Video output does not have a valid connection")
      return false
    }

    // Configure depth output if available
    var outputs: [AVCaptureOutput] = [videoOutput]
    if captureSession.canAddOutput(depthOutput) {
      depthOutput.isFilteringEnabled = true
      depthOutput.alwaysDiscardsLateDepthData = true

      if captureSession.canAddOutput(depthOutput) {
        captureSession.addOutput(depthOutput)

        // Only add depth output if it has a valid connection
        if depthOutput.connection(with: .depthData) != nil {
          outputs.append(depthOutput)
        } else {
          print("Warning: Depth output added but no valid connection")
        }
      }
    }

    // Create synchronizer with only outputs that have valid connections
    outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: outputs)
    outputSynchronizer?.setDelegate(self, queue: queue)

    // ---------------------------------------------------------------------
    if captureSession.canAddOutput(cameraOutput) {
      captureSession.addOutput(cameraOutput)
    }

    do {
      try captureDevice.lockForConfiguration()
      captureDevice.focusMode = .continuousAutoFocus
      captureDevice.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      captureDevice.exposureMode = .continuousAutoExposure
      captureDevice.unlockForConfiguration()
    } catch {
      print("Unable to configure the capture device.")
      return false
    }

    captureSession.commitConfiguration()
    return true
  }

  // Starts the video capture session.
  public func start() {
    queue.async { [weak self] in
      guard let self = self, !self.captureSession.isRunning else { return }

      // If we're in the middle of configuration, commit it first
      self.captureSession.commitConfiguration()
      self.captureSession.startRunning()
    }
  }

  // Stops the video capture session.
  public func stop() {
    if captureSession.isRunning {
      captureSession.stopRunning()
    }
  }
  func updateVideoOrientation() {
    guard let connection = videoOutput.connection(with: .video) else { return }
    switch UIDevice.current.orientation {
    case .portrait:
      connection.videoRotationAngle = 90
    case .portraitUpsideDown:
      connection.videoRotationAngle = 270
    case .landscapeRight:
      connection.videoRotationAngle = 180
    case .landscapeLeft:
      connection.videoRotationAngle = 0
    default:
      return
    }
    self.previewLayer?.connection?.videoRotationAngle = connection.videoRotationAngle
  }

  /// Converts a rectangle from metadata output coordinates to the preview layer's coordinate system
  /// - Parameter rect: The rectangle in metadata output coordinates
  /// - Returns: The rectangle converted to the preview layer's coordinate system
  func convertFromMetadataOutputRect(_ rect: CGRect) -> CGRect {
    guard let previewLayer = previewLayer else { return .zero }
    return previewLayer.layerRectConverted(fromMetadataOutputRect: rect)
  }

  public func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
    let settings = AVCapturePhotoSettings()
    if #available(iOS 16.0, *) {
      let dims = captureDevice.activeFormat.supportedMaxPhotoDimensions
      settings.maxPhotoDimensions = dims[0]
    } else {
      settings.isHighResolutionPhotoEnabled = true
    }
    cameraOutput.capturePhoto(with: settings, delegate: delegate)
  }
}

// Extension to handle AVCaptureVideoDataOutputSampleBufferDelegate events.
// MARK: - AVCapture Delegates
extension VideoCapture: AVCaptureDataOutputSynchronizerDelegate {
  // public func captureOutput(
  //   _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
  //   from connection: AVCaptureConnection
  // ) {
  //   delegate?.videoCapture(self, didCaptureVideoFrame: sampleBuffer)
  // }

  public func dataOutputSynchronizer(
    _ synchronizer: AVCaptureDataOutputSynchronizer,
    didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
  ) {
    // Retrieve the synchronized depth and sample buffer container objects.
    let syncedDepthData =
      synchronizedDataCollection.synchronizedData(for: depthOutput)
      as? AVCaptureSynchronizedDepthData
    let syncedVideoData =
      synchronizedDataCollection.synchronizedData(for: videoOutput)
      as? AVCaptureSynchronizedSampleBufferData

    guard let pixelBuffer = syncedVideoData?.sampleBuffer.imageBuffer else { return }

    // Package the captured data.
    delegate?.onNewData(self, imageBuffer: pixelBuffer, depthData: syncedDepthData?.depthData)
  }

  // public func captureOutput(
  //   _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
  //   from connection: AVCaptureConnection
  // ) {
  //   // Optionally handle dropped frames, e.g., due to full buffer.
  // }
}
