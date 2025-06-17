import AVFoundation
import Foundation

/// A simplified, beat-preserving beeper.
///
/// Design goals (matches project principles):
/// • Safe from bugs   – one timer, no busy-loop, race-free reschedule logic.
/// • Easy to understand – play → schedule next, only five core vars.
/// • Ready for change   – all timing contained in `scheduleNextBeep()`.
final class SmoothBeeper {
  // MARK: – Public configuration
  private let alpha: Double = 0.2  // Smoothing factor for EMA
  private let minInterval: TimeInterval = 0.1

  // MARK: – Private state
  private var player: AVAudioPlayer?
  private var timer: Timer?
  private var lastBeepTime: Date = .distantPast
  private var currentInterval: TimeInterval = 0.5
  private var targetInterval: TimeInterval = 0.5

  // MARK: – Init / Deinit
  init() {
    // Prepare click sound once.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beep.wav")
    self.soundURL = url
    configureAudioSession()
    generateClickSound()
  }

  deinit { stop() }

  // MARK: – Public API
  /// Begin beeping at the supplied interval.
  func start(interval: TimeInterval) {
    stop()  // Clean slate
    currentInterval = max(minInterval, interval)
    targetInterval = currentInterval
    lastBeepTime = Date()
    playBeep()  // Play immediately
    scheduleNextBeep(after: currentInterval)
  }

  /// Stop any ongoing beeps.
  func stop() {
    timer?.invalidate()
    timer = nil
    player?.stop()
  }

  /// Request the beeper to move toward a new interval.  If `smoothly==false` the
  /// change is immediate; otherwise an exponential-moving-average is applied and
  /// the next beat is rescheduled so the rhythm stays continuous.
  func updateInterval(to newInterval: TimeInterval, smoothly: Bool = true) {
    let safe = max(minInterval, newInterval)
    targetInterval = safe
    if !smoothly {
      currentInterval = safe
      rescheduleTimer()
      return
    }
    // EMA smoothing.
    currentInterval = (1 - alpha) * currentInterval + alpha * targetInterval
    rescheduleTimer()
  }

  // MARK: – Private – Timing helpers
  private func rescheduleTimer() {
    guard timer != nil else { return }  // Nothing scheduled yet.
    let elapsed = Date().timeIntervalSince(lastBeepTime)
    let remaining = max(0.0, currentInterval - elapsed)
    scheduleNextBeep(after: remaining)
  }

  private func scheduleNextBeep(after delay: TimeInterval) {
    timer?.invalidate()
    let newTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      self?.handleTimerFire()
    }
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer
  }

  private func handleTimerFire() {
    playBeep()
    scheduleNextBeep(after: currentInterval)  // schedule following beat
  }

  private func playBeep() {
    guard let p = player else { return }
    p.currentTime = 0
    _ = p.play()
    lastBeepTime = Date()
  }

  // MARK: – Private – Audio setup
  private let soundURL: URL

  private func configureAudioSession() {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try? session.setActive(true)
    #endif
  }

  private func generateClickSound() {
    guard !FileManager.default.fileExists(atPath: soundURL.path) else {
      player = try? AVAudioPlayer(contentsOf: soundURL)
      player?.prepareToPlay()
      return
    }
    let sampleRate: Double = 44100
    let duration: Double = 0.03
    let frequency: Double = 1000
    let numSamples = Int(duration * sampleRate)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(numSamples))!
    buffer.frameLength = AVAudioFrameCount(numSamples)
    let channel = buffer.floatChannelData![0]
    for i in 0..<numSamples {
      let t = Double(i) / sampleRate
      let envelope = sin(.pi * Double(i) / Double(numSamples))
      channel[i] = Float(sin(2 * .pi * frequency * t) * envelope)
    }
    if let file = try? AVAudioFile(forWriting: soundURL, settings: format.settings) {
      try? file.write(from: buffer)
    }
    player = try? AVAudioPlayer(contentsOf: soundURL)
    player?.prepareToPlay()
  }
}
