import AVFoundation
import SwiftUI
import UIKit

/// A SwiftUI view that wraps the VideoCapture for camera preview and frame capture
struct CameraPreviewView: UIViewControllerRepresentable {
  @Binding var isRunning: Bool
  let videoCapture: VideoCapture
  weak var delegate: VideoCaptureDelegate?
  
  // Coordinator to handle orientation changes and view controller lifecycle
  class Coordinator: NSObject {
    var parent: CameraPreviewView
    private var orientationObserver: NSObjectProtocol?
    weak var viewController: UIViewController?
    
    init(_ parent: CameraPreviewView) {
      self.parent = parent
      super.init()
      
      // Observe device orientation changes
      orientationObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main) { [weak self] _ in
          self?.handleOrientationChange()
      }
    }
    
    deinit {
      if let observer = orientationObserver {
        NotificationCenter.default.removeObserver(observer)
      }
    }
    
    private func handleOrientationChange() {
      // Update the video orientation
      parent.videoCapture.updateVideoOrientation()
      
      // Update the preview layer's frame after a short delay to ensure the view has finished rotating
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.updatePreviewFrame()
      }
    }
    
    func updatePreviewFrame() {
      guard let view = viewController?.view, let previewLayer = parent.videoCapture.previewLayer else { return }
      
      // Animate the frame change for smooth rotation
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      
      // Update the preview layer's frame to match the view's bounds
      previewLayer.frame = view.bounds
      
      // Ensure the preview fills the container while maintaining aspect ratio
      previewLayer.videoGravity = .resizeAspectFill
      
      // Force layout update
      previewLayer.layoutIfNeeded()
      
      CATransaction.commit()
      
      // Update the video orientation after frame update
      parent.videoCapture.updateVideoOrientation()
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  init(isRunning: Binding<Bool> = .constant(false), delegate: VideoCaptureDelegate? = nil) {
    self._isRunning = isRunning
    self.videoCapture = VideoCapture()
    self.delegate = delegate
  }

  func makeUIViewController(context: Context) -> UIViewController {
    let viewController = UIViewController()
    viewController.view.backgroundColor = .black
    
    // Store a reference to the view controller in the coordinator
    context.coordinator.viewController = viewController
    
    // Set up the video capture
    videoCapture.setUp { success in
      
      if success, let previewLayer = self.videoCapture.previewLayer {
        // Configure the preview layer
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.contentsGravity = .resizeAspectFill
        previewLayer.frame = viewController.view.layer.bounds
        
        // Add the preview layer to the view's layer
        viewController.view.layer.insertSublayer(previewLayer, at: 0)
        
        // Initial orientation and frame update
        self.videoCapture.updateVideoOrientation()
        context.coordinator.updatePreviewFrame()
        
        // Start the capture session if needed
        if self.isRunning {
          self.videoCapture.start()
        }
      }
    }
    
    // Set the delegate for frame capture
    videoCapture.delegate = delegate
    
    return viewController
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // Update the view controller reference in case it changed
    context.coordinator.viewController = uiViewController
    
    // Update the preview layer frame when the view size changes
    context.coordinator.updatePreviewFrame()
    
    // Start or stop the capture session based on the isRunning binding
    if isRunning {
      videoCapture.start()
    } else {
      videoCapture.stop()
    }
    
    // Update the delegate if it changes
    videoCapture.delegate = delegate
  }

  static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
    // Clean up when the view is removed from the hierarchy
    if let previewLayer =
      (uiViewController.view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer })
    {
      previewLayer.removeFromSuperlayer()
    }
  }
}

// MARK: - Preview Provider
#if DEBUG
  struct CameraPreviewView_Previews: PreviewProvider {
    static var previews: some View {
      // Use a placeholder view in preview to prevent camera access
      Color.black
        .frame(height: 300)
        .cornerRadius(20)
        .padding()
        .previewLayout(.sizeThatFits)
        .overlay(
          Text("Camera Preview")
            .foregroundColor(.white)
        )
    }
  }
#endif
