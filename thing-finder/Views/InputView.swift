import AVFoundation
import SwiftUI

struct InputView: View {
  @State private var searchMode: SearchMode = .uberFinder
  @State private var selectedClass: String = "car"
  @State private var description: String = ""
  @State private var isShowingCamera = false

  // Vehicle classes for Uber Finder
  private let vehicleClasses = ["car", "truck", "bus"].sorted()

  // Full YOLO class list for Object Finder
  private let yoloClasses = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog",
    "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
    "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
    "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich",
    "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
    "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote",
    "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
    "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
  ].sorted()

  var selectedClasses: [String] {
    searchMode == .uberFinder ? vehicleClasses : [selectedClass]
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text("Search Mode")) {
          Picker("Mode", selection: $searchMode) {
            ForEach(SearchMode.allCases) { mode in
              VStack(alignment: .leading) {
                Text(mode.rawValue)
                  .font(.headline)
                Text(mode.description)
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              .tag(mode)
            }
          }
          .pickerStyle(.inline)
        }

        Section(
          header: Text(
            searchMode == .uberFinder ? "Vehicle Description" : "What are you looking for?")
        ) {
          if searchMode == .objectFinder {
            Picker("Object Class", selection: $selectedClass) {
              ForEach(yoloClasses, id: \.self) { className in
                Text(className.capitalized).tag(className)
              }
            }
            .pickerStyle(MenuPickerStyle())
          }

          TextField(
            searchMode == .uberFinder
              ? "Describe your ride (e.g., 'white Toyota Camry with license plate ABC123')"
              : "Describe it in detail (e.g., 'silver laptop with a white and green laptop sticker')",
            text: $description,
            axis: .vertical
          )
          .textFieldStyle(RoundedBorderTextFieldStyle())
          .lineLimit(3, reservesSpace: true)
        }

        Section {
          Button(searchMode == .uberFinder ? "Find My Ride" : "Start Searching") {
            isShowingCamera = true
          }
          .frame(maxWidth: .infinity, alignment: .center)
          .buttonStyle(.borderedProminent)
        }
      }
      .navigationTitle("Find My Thing")
      .navigationDestination(isPresented: $isShowingCamera) {
        ContentView(
          selectedClass: selectedClass,
          description: description,
          searchMode: searchMode,
          targetClasses: selectedClasses
        )
      }
    }
  }
}

#Preview {
  InputView()
}
