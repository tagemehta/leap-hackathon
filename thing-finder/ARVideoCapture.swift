//  ARVideoCapture.swift
//  Drop-in replacement for VideoCapture, with depth closure API.
//  Requires iOS 14+ and ARKit.

import ARKit
import CoreVideo
import RealityKit
import UIKit
import simd

public protocol ARVideoCaptureDelegate: AnyObject {
  /// - imageBuffer: the live camera frame
  /// - depthData: a closure you can call with any point in view coords to get its depth (in meters).
  ///              On LiDAR devices this reads the sceneDepth map; otherwise it raycasts.
  func processFrame(
    _ capture: ARVideoCapture,
    frame: ARFrame,
    imageBuffer: CVPixelBuffer,
    depthData: @escaping (CGPoint) -> Float?)
}

public class ARVideoCapture: NSObject, ARSessionDelegate {
  // MARK: Public API

  /// Embed this ARView into your view hierarchy to show live preview.
  public let previewView: ARView

  /// Delegate to receive frames + depth closure.
  public weak var delegate: ARVideoCaptureDelegate?

  public override init() {
    print("init")
    self.previewView = ARView(frame: .zero)
    super.init()
    previewView.session.delegate = self
  }

  deinit {
    print("deinit")
    previewView.session.pause()
  }

  /// Call once to start camera+tracking.
  public func start() {
    let config = ARWorldTrackingConfiguration()
    // Enable plane detection
    config.planeDetection = [.horizontal, .vertical]

    if let format = ARWorldTrackingConfiguration.supportedVideoFormats.filter({
      $0.framesPerSecond == 30
    }).first {
      config.videoFormat = format
    }

    // If device supports scene reconstruction, enable it
    // if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
    //   config.sceneReconstruction = .mesh
    // }

    previewView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
  }

  /// Call to stop session.
  public func stop() {
    previewView.session.pause()
  }

  // MARK: ARSessionDelegate

  public func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let pixelBuffer = frame.capturedImage
    let cameraTransform = frame.camera.transform
    // Capture the latest depthMap if available
    let depthBuffer = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap

    // Build our depth‐lookup closure
    let depthProvider: (CGPoint) -> Float? = { [weak self] point in
      // 1) LiDAR depth‐map path
      if let depthMap = depthBuffer, let view = self?.previewView {
        let viewSize = view.bounds.size
        // normalize to [0–1]
        let xNorm = point.x / viewSize.width
        let yNorm = point.y / viewSize.height
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let px = min(max(Int(xNorm * CGFloat(w)), 0), w - 1)
        let py = min(max(Int(yNorm * CGFloat(h)), 0), h - 1)

        CVPixelBufferLockBaseAddress(depthMap, [])
        defer { CVPixelBufferUnlockBaseAddress(depthMap, []) }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let floatsPerRow = rowBytes / MemoryLayout<Float32>.size
        let base = unsafeBitCast(
          CVPixelBufferGetBaseAddress(depthMap),
          to: UnsafeMutablePointer<Float32>.self)
        let depth = base[py * floatsPerRow + px]
        return depth
      }

      // 2) Raycast fallback
      if let view = self?.previewView,
        let query = view.makeRaycastQuery(
          from: point,
          allowing: .estimatedPlane,
          alignment: .any
        ),
        let result = session.raycast(query).first
      {
        let camPos = cameraTransform.columns.3
        let hitPos = result.worldTransform.columns.3
        return simd_distance(camPos, hitPos)
      }

      return nil
    }

    // Fire delegate
    delegate?.processFrame(
      self,
      frame: frame,
      imageBuffer: pixelBuffer,
      depthData: depthProvider)
  }
}
