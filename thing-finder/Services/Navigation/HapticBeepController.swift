import Foundation

/// Converts distance → tone frequency & volume and drives a concrete `Beeper`.
final class HapticBeepController {
    private let beeper: Beeper
    private let settings: Settings
    private var isBeeping = false

    init(beeper: Beeper, settings: Settings) {
        self.beeper = beeper
        self.settings = settings
    }

    /// Call every frame.
    /// - Parameter distance: optional distance to target in metres.
    func tick(distance: Double?, timestamp: Date) {
        guard settings.enableAudio else {
            stopIfNeeded(); return
        }
        guard let dist = distance else {
            stopIfNeeded(); return
        }
        // Map distance to frequency: closer → faster.
        let freq = max(1.0, 3.0 / max(0.3, dist)) * 2.0 // arbitrary tuning
        let vol = Float(settings.mapDistanceToVolume(dist))
        if !isBeeping {
            beeper.start(frequency: freq, volume: vol)
            isBeeping = true
        } else {
            // Use beeper APIs to update.
            (beeper as? SmoothBeeper)?.updateInterval(to: 1.0 / freq, smoothly: true)
            (beeper as? SmoothBeeper)?.updateVolume(to: Double(vol))
        }
    }

    private func stopIfNeeded() {
        if isBeeping { beeper.stop(); isBeeping = false }
    }
}
