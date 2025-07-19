import CoreGraphics
import Foundation

/// Emits plain direction words ("left", "right", "still") based on the
/// bounding box centre X normalised to 0–1.
final class DirectionSpeechController {
  private let config: NavigationFeedbackConfig
  private let speaker: SpeechOutput
  private var lastDirection: Direction = .center
  private var timeLastSpoken: Date = .distantPast

  init(config: NavigationFeedbackConfig, speaker: SpeechOutput) {
    self.config = config
    self.speaker = speaker
  }

  /// Pass `nil` when there is no active target against which to provide direction.
  func tick(targetBox: CGRect?, timestamp: Date, settings: Settings) {
    guard let box = targetBox else { return }
    let newDir = settings.getDirection(normalizedX: box.midX)
    let elapsed = timestamp.timeIntervalSince(timeLastSpoken)
    if newDir == lastDirection {
      if elapsed > config.speechRepeatInterval {
        speak(text: "Still " + newDir.rawValue)
      }
    } else {
      if elapsed > config.directionChangeInterval {
        speak(text: newDir.rawValue)
        lastDirection = newDir
      }
    }
  }

  private func speak(text: String) {
    timeLastSpoken = Date()
    speaker.speak(text, rate: 0.5) // TODO - settings config
  }
}
