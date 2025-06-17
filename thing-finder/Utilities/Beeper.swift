import AVFoundation

final class Beeper {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let soundURL: URL
    
    init() {
        // Create a temporary URL for the click sound
        self.soundURL = FileManager.default.temporaryDirectory.appendingPathComponent("click.caf")
        
        // Generate and save the click sound
        generateClickSound()
    }
    
    private func generateClickSound() {
        let sampleRate: Double = 44100
        let duration: Double = 0.03 // 30ms
        let frequency: Double = 1000 // 1kHz
        let numSamples = Int(duration * sampleRate)
        
        // Create audio format
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                 sampleRate: sampleRate,
                                 channels: 1,
                                 interleaved: false)!
        
        // Create buffer
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))!
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
        
        // Fill buffer with sine wave
        let channelData = pcmBuffer.int16ChannelData![0]
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            let sample = sin(2 * .pi * frequency * t) * Double(Int16.max)
            channelData[i] = Int16(clamping: Int(sample))
        }
        
        // Write to file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: soundURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            try audioFile.write(from: pcmBuffer)
            
            // Initialize player with the saved file
            player = try AVAudioPlayer(contentsOf: soundURL)
            player?.prepareToPlay()
        } catch {
            print("Error creating beeper: \(error)")
        }
    }
    
    func start(interval: TimeInterval) {
        stop()
        
        // Ensure minimum interval to prevent audio overlap
        let safeInterval = max(0.1, interval)
        
        // Make sure we're on the main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Start a new timer
            self.timer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
                self?.player?.currentTime = 0
                self?.player?.play()
            }
            
            // Play immediately when starting
            self.player?.currentTime = 0
            self.player?.play()
        }
    }
    
    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }
    
    deinit {
        stop()
        try? FileManager.default.removeItem(at: soundURL)
    }
}
