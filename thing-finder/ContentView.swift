import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var isCameraRunning = true
    @State private var frameCount = 0
    
    var body: some View {
        VStack {
            CameraPreviewView(isRunning: $isCameraRunning)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(20)
            .padding()
            
            Button(action: {
                isCameraRunning.toggle()
            }) {
                Text(isCameraRunning ? "Stop Camera" : "Start Camera")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isCameraRunning ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            .padding(.bottom)
            
            Text("Frame count: \(frameCount)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}


#Preview {
  ContentView()
}
