import AVFoundation
import SwiftUI

struct ContentView: View {
  @State private var isCameraRunning = true

  @StateObject private var detectionModel = DetectionViewModel(targetClasses: ["car"])

  var body: some View {
    VStack {
      ZStack {
        let cPreview = CameraPreviewWrapper(
          isRunning: $isCameraRunning, delegate: detectionModel)

        cPreview.frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(20)

        BoundingBoxViewOverlay(
          boxes: $detectionModel.boundingBoxes
        )
      }
      .padding()

    }
  }
}

#Preview {
  ContentView()
}
