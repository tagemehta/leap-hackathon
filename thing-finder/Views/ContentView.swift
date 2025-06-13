import AVFoundation
import SwiftUI
import Foundation

// Import the SearchMode from the Models module

struct  ContentView: View {
    @State private var isCameraRunning = true
    let selectedClass: String
    let description: String
    let searchMode: SearchMode
    let targetClasses: [String]
    
    @StateObject private var detectionModel: CameraViewModel
    
    init(
        selectedClass: String = "person",
        description: String = "",
        searchMode: SearchMode = .objectFinder,
        targetClasses: [String] = ["person"]
    ) {
        self.selectedClass = selectedClass
        self.description = description
        self.searchMode = searchMode
        self.targetClasses = targetClasses
        
        let descriptionText: String
        if searchMode == .uberFinder {
            descriptionText = description.isEmpty ? "a vehicle" : "a vehicle with \(description)"
        } else {
            descriptionText = description.isEmpty ? "a \(selectedClass)" : "\(selectedClass) with \(description)"
        }
        
        _detectionModel = StateObject(
            wrappedValue: CameraViewModel(
                targetClasses: targetClasses,
                targetTextDescription: descriptionText
            )
        )
    }
    
    var title: String {
        searchMode == .uberFinder ? "Finding Your Ride" : "Finding: \(selectedClass.capitalized)"
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
            }
        }
        .navigationBarTitle(title, displayMode: .inline)
    }
}

#Preview {
  NavigationView {
    ContentView(selectedClass: "person", description: "wearing a red shirt")
  }
}
