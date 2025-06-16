import SwiftUI

struct ContentView: View {
  @State private var isCameraRunning = true
  let description: String
  let searchMode: SearchMode
  let targetClasses: [String]

  @StateObject private var detectionModel: CameraViewModel

  init(
    description: String = "",
    searchMode: SearchMode = .objectFinder,
    targetClasses: [String] = ["person"]
  ) {
    self.description = description
    self.searchMode = searchMode
    self.targetClasses = targetClasses

    let descriptionText: String
    if searchMode == .uberFinder {
      descriptionText = description.isEmpty ? "a vehicle" : "a vehicle with \(description)"
    } else {
      descriptionText =
        description.isEmpty
        ? "a \(targetClasses[0])" : "\(targetClasses[0]) with description: \(description)"
    }

    _detectionModel = StateObject(
      wrappedValue: CameraViewModel(
        targetClasses: targetClasses,
        targetTextDescription: descriptionText
      )
    )
  }

  var title: String {
    searchMode == .uberFinder ? "Finding Your Ride" : "Finding: \(targetClasses[0].capitalized)"
  }

  var body: some View {
    VStack {
      ZStack {
        CameraPreviewWrapper(
          isRunning: $isCameraRunning,
          delegate: detectionModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        BoundingBoxViewOverlay(
          boxes: $detectionModel.boundingBoxes
        )

        // FPS Display
        VStack {
          HStack {
            Spacer()
            Text(String(format: "%.1f FPS", detectionModel.currentFPS))
              .font(.system(size: 14, weight: .medium, design: .monospaced))
              .foregroundColor(.white)
              .padding(8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(8)
              .padding()
          }
          Spacer()
        }
      }
    }
    .navigationBarTitle(title, displayMode: .inline)
    .onRotate { newOrientation in
      detectionModel.handleOrientationChange()
    }
  }
}

#Preview {
  NavigationView {
    ContentView(description: "wearing a red shirt", targetClasses: ["person"])
  }
}
