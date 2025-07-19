import AVFoundation

class Speaker: SpeechOutput {
  private let synthesizer = AVSpeechSynthesizer()

  public func speak(_ text: String, rate: Float = 0.5) {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)  // Interrupt immediately
    }

    // Create an utterance with the text
    let utterance = AVSpeechUtterance(string: text)

    // Configure the utterance (optional)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")  // Set the language
    utterance.rate = rate// Speed of speech (0.0 to 1.0)
    utterance.pitchMultiplier = 1.0  // Pitch (0.5 to 2.0)

    // Speak the utterance
    synthesizer.speak(utterance)
  }
}
