import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var showAdvancedSettings = false
    
    var body: some View {
        NavigationView {
            List {
                // MARK: - Navigation Settings
                Section(header: Text("Navigation Feedback")) {
                    Toggle("Audio Beeps", isOn: $settings.enableAudio)
                    Toggle("Speech Guidance", isOn: $settings.enableSpeech)
                    Toggle("Haptic Feedback", isOn: $settings.enableHaptics)
                    
                    if settings.enableSpeech {
                        VStack(alignment: .leading) {
                            Text("Speech Rate: \(String(format: "%.1f", settings.speechRate))")
                            Slider(value: $settings.speechRate, in: -1...1, step: 0.1)
                                .accessibilityLabel("Speech Rate")
                        }
                    }
                }
                
                // MARK: - Direction Settings
                Section(header: Text("Direction Settings")) {
                    VStack(alignment: .leading) {
                        Text("Left Threshold: \(Int(settings.directionLeftThreshold * 100))%")
                        Slider(value: $settings.directionLeftThreshold, in: 0.1...0.4, step: 0.01)
                            .accessibilityLabel("Left Threshold")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Right Threshold: \(Int(settings.directionRightThreshold * 100))%")
                        Slider(value: $settings.directionRightThreshold, in: 0.6...0.9, step: 0.01)
                            .accessibilityLabel("Right Threshold")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Repeat Interval: \(String(format: "%.1f", settings.speechRepeatInterval))s")
                        Slider(value: $settings.speechRepeatInterval, in: 1...10, step: 0.5)
                            .accessibilityLabel("Repeat Interval")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Change Interval: \(String(format: "%.1f", settings.speechChangeInterval))s")
                        Slider(value: $settings.speechChangeInterval, in: 0.5...5, step: 0.5)
                            .accessibilityLabel("Change Interval")
                    }
                }
                
                // MARK: - Beep Settings
                Section(header: Text("Beep Settings")) {
                    VStack(alignment: .leading) {
                        Text("Min Interval: \(String(format: "%.2f", settings.beepIntervalMin))s")
                        Slider(value: $settings.beepIntervalMin, in: 0.05...0.5, step: 0.01)
                            .accessibilityLabel("Minimum Beep Interval")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Max Interval: \(String(format: "%.1f", settings.beepIntervalMax))s")
                        Slider(value: $settings.beepIntervalMax, in: 0.5...2.0, step: 0.1)
                            .accessibilityLabel("Maximum Beep Interval")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Smoothing: \(String(format: "%.2f", settings.smoothingAlpha))")
                        Slider(value: $settings.smoothingAlpha, in: 0.05...0.5, step: 0.05)
                            .accessibilityLabel("Beep Smoothing")
                    }
                }
                
                // MARK: - Distance Settings
                Section(header: Text("Distance Feedback")) {
                    Picker("Volume Curve", selection: $settings.volumeCurve) {
                        ForEach(VolumeCurve.allCases) { curve in
                            Text(curve.rawValue).tag(curve)
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Min Distance: \(String(format: "%.1f", settings.distanceMin))m")
                        Slider(value: $settings.distanceMin, in: 0.1...1.0, step: 0.1)
                            .accessibilityLabel("Minimum Distance")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Max Distance: \(String(format: "%.1f", settings.distanceMax))m")
                        Slider(value: $settings.distanceMax, in: 1.0...5.0, step: 0.5)
                            .accessibilityLabel("Maximum Distance")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Min Volume: \(Int(settings.volumeMin * 100))%")
                        Slider(value: $settings.volumeMin, in: 0.0...0.5, step: 0.05)
                            .accessibilityLabel("Minimum Volume")
                    }
                }
                
                // MARK: - Developer Mode Toggle
                Section {
                    Toggle("Developer Mode", isOn: $settings.developerMode)
                        .onChange(of: settings.developerMode) {
                          if !settings.developerMode {
                                showAdvancedSettings = false
                            }
                        }
                    
                    if settings.developerMode {
                        Toggle("Show Advanced Settings", isOn: $showAdvancedSettings)
                    }
                }
                
                // MARK: - Advanced Settings (Developer Mode)
                if settings.developerMode && showAdvancedSettings {
                    Section(header: Text("Detection Settings")) {
                        VStack(alignment: .leading) {
                            Text("Confidence: \(String(format: "%.2f", settings.confidenceThreshold))")
                            Slider(value: $settings.confidenceThreshold, in: 0.1...0.9, step: 0.05)
                                .accessibilityLabel("Confidence Threshold")
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Verification Cooldown: \(String(format: "%.1f", settings.verificationCooldown))s")
                            Slider(value: $settings.verificationCooldown, in: 0.5...5.0, step: 0.5)
                                .accessibilityLabel("Verification Cooldown")
                        }
                        
                        Stepper("Target Lifetime: \(settings.targetLifetime) frames", 
                                value: $settings.targetLifetime, 
                                in: 100...2000,
                                step: 100)
                        
                        Stepper("Max Lost Frames: \(settings.maxLostFrames)", 
                                value: $settings.maxLostFrames, 
                                in: 1...10)
                    }
                    
                    Section(header: Text("Tracking Drift Thresholds")) {
                        VStack(alignment: .leading) {
                            Text("Min IoU: \(String(format: "%.2f", settings.minIouThreshold))")
                            Slider(value: $settings.minIouThreshold, in: 0.1...0.8, step: 0.05)
                                .accessibilityLabel("Minimum IoU Threshold")
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Max Center Shift: \(String(format: "%.2f", settings.maxCenterShift))")
                            Slider(value: $settings.maxCenterShift, in: 0.05...0.5, step: 0.05)
                                .accessibilityLabel("Maximum Center Shift")
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Max Area Shift: \(String(format: "%.2f", settings.maxAreaShift))")
                            Slider(value: $settings.maxAreaShift, in: 0.1...0.8, step: 0.05)
                                .accessibilityLabel("Maximum Area Shift")
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Min Tracking Confidence: \(String(format: "%.2f", settings.minTrackingConfidence))")
                            Slider(value: $settings.minTrackingConfidence, in: 0.1...0.8, step: 0.05)
                                .accessibilityLabel("Minimum Tracking Confidence")
                        }
                    }
                    
                    Section(header: Text("Performance")) {
                        Toggle("Battery Saver Mode", isOn: $settings.batterySaver)
                        
                        Stepper("FPS Window: \(settings.fpsWindow) frames", 
                                value: $settings.fpsWindow, 
                                in: 5...30,
                                step: 5)
                    }
                }
                
                // MARK: - Reset Section
                Section {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resetToDefaults() {
        let defaultSettings = Settings()
        
        // Copy all default values
        settings.beepIntervalMin = defaultSettings.beepIntervalMin
        settings.beepIntervalMax = defaultSettings.beepIntervalMax
        settings.directionLeftThreshold = defaultSettings.directionLeftThreshold
        settings.directionRightThreshold = defaultSettings.directionRightThreshold
        settings.speechRepeatInterval = defaultSettings.speechRepeatInterval
        settings.speechChangeInterval = defaultSettings.speechChangeInterval
        settings.distanceMin = defaultSettings.distanceMin
        settings.distanceMax = defaultSettings.distanceMax
        settings.volumeMin = defaultSettings.volumeMin
        settings.volumeMax = defaultSettings.volumeMax
        settings.volumeCurve = defaultSettings.volumeCurve
        settings.confidenceThreshold = defaultSettings.confidenceThreshold
        settings.verificationCooldown = defaultSettings.verificationCooldown
        settings.targetLifetime = defaultSettings.targetLifetime
        settings.maxLostFrames = defaultSettings.maxLostFrames
        settings.minIouThreshold = defaultSettings.minIouThreshold
        settings.maxCenterShift = defaultSettings.maxCenterShift
        settings.maxAreaShift = defaultSettings.maxAreaShift
        settings.minTrackingConfidence = defaultSettings.minTrackingConfidence
        settings.enableAudio = defaultSettings.enableAudio
        settings.enableHaptics = defaultSettings.enableHaptics
        settings.enableSpeech = defaultSettings.enableSpeech
        settings.speechRate = defaultSettings.speechRate
        settings.smoothingAlpha = defaultSettings.smoothingAlpha
        settings.fpsWindow = defaultSettings.fpsWindow
        settings.batterySaver = defaultSettings.batterySaver
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: Settings())
    }
}
