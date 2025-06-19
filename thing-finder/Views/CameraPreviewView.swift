//
//  CameraPreviewView.swift
//  SwiftUI wrapper for ARVideoCapture to preview ARView and deliver frames + depth lookup
//
import SwiftUI
import UIKit
import RealityKit
import ARKit

/// SwiftUI wrapper to embed ARVideoCapture's previewView and receive depth-enabled frames.
struct CameraPreviewWrapper: View {
    @Binding var isRunning: Bool
    weak var delegate: ARVideoCaptureDelegate?

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            Color.black
                .overlay(Text("Camera Preview").foregroundColor(.white))
        } else {
            CameraPreviewView(isRunning: $isRunning, delegate: delegate)
        }
        #else
        CameraPreviewView(isRunning: $isRunning, delegate: delegate)
        #endif
    }
}
struct CameraPreviewView: UIViewControllerRepresentable {
    @Binding var isRunning: Bool
    weak var delegate: ARVideoCaptureDelegate?

    // 1️⃣ Remove your arCapture from here entirely

    /// 2️⃣ Create a coordinator that WILL hold it
    func makeCoordinator() -> Coordinator {
        Coordinator(delegate: delegate)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black

        // 3️⃣ use the coordinator’s ARVideoCapture
        let capture = context.coordinator.arCapture
        let preview = capture.previewView
        preview.frame = vc.view.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(preview)

        capture.delegate = delegate
        if isRunning { capture.start() }

        return vc
    }

    func updateUIViewController(_ uiVC: UIViewController, context: Context) {
        let capture = context.coordinator.arCapture
        if isRunning {
            capture.start()
        } else {
            capture.stop()
        }
        // in case delegate changed
        capture.delegate = delegate
    }

    // 4️⃣ Define the Coordinator
    class Coordinator {
        let arCapture: ARVideoCapture
        weak var delegate: ARVideoCaptureDelegate?

        init(delegate: ARVideoCaptureDelegate?) {
            self.delegate = delegate
            self.arCapture = ARVideoCapture()
            self.arCapture.delegate = delegate
        }
    }
}
