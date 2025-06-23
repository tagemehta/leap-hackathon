//  ARVideoCapture.swift
//  Drop-in replacement for VideoCapture, with depth closure API.
//  Requires iOS 14+ and ARKit.

import ARKit
import CoreVideo
import RealityKit
import UIKit
import simd

protocol ARVideoCaptureDelegate: AnyObject {
  /// - imageBuffer: the live camera frame
  /// - depthData: a closure you can call with any point in view coords to get its depth (in meters).
  ///              On LiDAR devices this reads the sceneDepth map; otherwise it raycasts.
  func processFrame(
    _ capture: ARVideoCapture,
    frame: ARFrame,
    imageBuffer: CVPixelBuffer,
    depthData: @escaping (CGPoint) -> Float?)
}

class ARVideoCapture: NSObject, ARSessionDelegate, FrameProvider {

  var sourceType = CaptureSourceType.arkit
  
  // MARK: - Public Properties
  
  /// Indicates whether the AR session is running.
  public private(set) var isRunning: Bool = false
  
  // MARK: - Private Properties
  
  /// The AR session being used for capture
  private let arSession: ARSession
  
  /// The AR configuration being used
  private var arConfiguration: ARWorldTrackingConfiguration
  
  /// The AR view that displays the camera feed and AR content
  private let previewARView: ARView
  
  /// Public preview view that can be added to the view hierarchy
  public var previewView: UIView { previewARView }

  /// Delegate to receive frames + depth closure.
  public weak var delegate: FrameProviderDelegate?

  override init() {
    // Initialize AR configuration
    self.arConfiguration = ARWorldTrackingConfiguration()
    
    // Initialize AR session
    self.arSession = ARSession()
    
    // Initialize AR view
    self.previewARView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    
    super.init()
    
    // Set up the AR view with our session
    previewARView.session = arSession
    previewARView.session.delegate = self
  }

  deinit {
    previewARView.session.pause()
  }

  // MARK: - Session Management
  
  /// Call once to start camera+tracking.
  public func start() {
    guard !isRunning else { 
      print("AR session already running")
      return 
    }
    
    // Ensure session is configured
    if arConfiguration.planeDetection.isEmpty {
      setupSession()
    }
    
    // Run the session
    print("Starting AR session with configuration: \(arConfiguration)")
    arSession.run(arConfiguration, options: [.resetTracking, .removeExistingAnchors])
    isRunning = true
    print("AR session started")
  }

  /// Call to stop session.
  public func stop() {
    print("Stopping AR session...")
    guard isRunning else { 
      print("AR session already stopped")
      return 
    }
    
    // Pause the session and reset tracking
    arSession.pause()
    
    // Reset the configuration to clear any existing anchors
    arConfiguration = ARWorldTrackingConfiguration()
    
    isRunning = false
    print("AR session stopped")
  }
  
  // MARK: - FrameProvider
  
  /// Configures the AR session with the desired settings.
  /// This can be called before `start()` to customize the session configuration.
  public func setupSession() {
    // Configure AR session
    arConfiguration.planeDetection = [.horizontal, .vertical]
    
    // Enable scene depth if available
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      arConfiguration.frameSemantics.insert(.sceneDepth)
    }
    
    // Set video format for optimal performance
    if let format = ARWorldTrackingConfiguration.supportedVideoFormats
      .filter({ $0.framesPerSecond == 30 })
      .first 
    {
      arConfiguration.videoFormat = format
    }
    
    // Configure environment texturing if available
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      arConfiguration.environmentTexturing = .automatic
    }
    
    print("AR session configured with plane detection: \(arConfiguration.planeDetection)")
    if arConfiguration.frameSemantics.contains(.sceneDepth) {
      print("Scene depth is enabled")
    }
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

      if let query = self?.previewARView.makeRaycastQuery(
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

    func imageToViewRect(_ rect: CGRect, _ sizes: (CGSize, CGSize)) -> CGRect {
      let (_, viewSize) = sizes
      let transform = frame.displayTransform(
        for: UIInterfaceOrientation(UIDevice.current.orientation), viewportSize: viewSize)
      let normalizedRect = rect.applying(transform)
      return VNImageRectForNormalizedRect(normalizedRect, Int(viewSize.width), Int(viewSize.height))
    }

    // Fire delegate
    delegate?.processFrame(
      self,
      buffer: pixelBuffer,
      depthAt: depthProvider,
      imageToViewRect: imageToViewRect
    )
  }
}
