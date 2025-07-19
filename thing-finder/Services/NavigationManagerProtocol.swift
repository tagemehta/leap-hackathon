/*/// NavigationManager
/// -----------------------
/// Provides user-facing navigation feedback (speech + haptics) based on
/// `NavEvent`s emitted from `FramePipelineCoordinator`.
///
/// High-level logic:
/// * `.start` – announces search target classes / description.
/// * `.searching` – periodically repeats "Searching" to reassure the user.
/// * `.found` – converts candidate bounding-box → auditory beeps & spoken
///   direction/distance.
/// * `.lost`, `.expired`, `.noMatch` – stop feedback & speak status.
///
/// The navigation policy is intentionally simple and UI-agnostic; concrete UI
/// layers (SwiftUI, UIKit) subscribe to the `NavigationManager` interface only
/// for side-effectful feedback.
///
/// Thread-safety: All public methods are expected on main thread (they interact
/// with AVSpeechSynthesizer & CoreHaptics).
///

import AVFoundation
import CoreHaptics
import Foundation
import Vision

// NavEvent is defined centrally in PipelineProtocols.swift

public class LegacyNavigationManager: NavigationManagerProtocol  {
  // Settings for configurable parameters
  let settings: Settings
  var lastDirection: Direction?
  var timeLastSpoken = Date()
  /// Tracks last phrase spoken per candidate id to suppress repeats.
  private var lastPhraseByCandidate: [CandidateID: (phrase: String, time: Date)] = [:]
  /// Global last phrase to suppress identical phrases across candidates.
  var lastGlobalPhrase: (phrase: String, time: Date)? = nil
  /// Tracks last announced status per candidate
  private var lastStatusByCandidate: [CandidateID: MatchStatus] = [:]
  /// Indicates whether "waiting for verification" has been spoken globally since last progress.
  private var hasSpokenWaiting = false
  let speaker = Speaker()
  private let beeper = SmoothBeeper()
  private var currentInterval: TimeInterval?

  init(settings: Settings = Settings()) {
    self.settings = settings
  }
  public func handle(
    _ event: NavEvent,
    box: CGRect? = nil,
    distanceMeters: Double? = nil
  ) {
    switch event {
    case .start(let targetClasses, let targetTextDescription):
      speaker.speak(
        text:
          "Searching for a \(targetClasses.joined(separator: ", or")) with description: \(targetTextDescription)"
      )
      timeLastSpoken = Date()
      break
    case .searching:
      if Date().timeIntervalSince(timeLastSpoken) > settings.speechRepeatInterval {
        speaker.speak(text: "Searching")
        timeLastSpoken = Date()
      }
      break
    case .noMatch:
      beeper.stop()
      currentInterval = nil
      speaker.speak(text: "No match")
      timeLastSpoken = Date()
      break
    case .lost:
      beeper.stop()
      currentInterval = nil
      speaker.speak(text: "Lost")
      timeLastSpoken = Date()
      break
    case .expired:
      beeper.stop()
      currentInterval = nil
      speaker.speak(text: "Expired")
      timeLastSpoken = Date()
      break
    case .found:
      if let box = box {
        navigate(to: box, distanceMeters: distanceMeters)
      } else {
        beeper.stop()
        currentInterval = nil
      }
    }
  }

  private func navigate(
    to box: CGRect, distanceMeters: Double?
  ) {
    let midx = box.midX

    // Calculate distance from center (0.0 to 0.5)
    let distanceFromCenter = abs(midx - 0.5)

    // Calculate interval based on settings and distance from center
    let newInterval = settings.calculateBeepInterval(distanceFromCenter: distanceFromCenter)

    // Smooth transition between intervals
    if currentInterval == nil {
      // First time, just start with the calculated interval
      beeper.start(interval: newInterval)
      currentInterval = newInterval
    } else {
      beeper.updateInterval(to: newInterval, smoothly: true)
      currentInterval = newInterval
    }

    // ---------------- Volume with distance ------------------
    if let dist = distanceMeters, settings.enableAudio {
      let volume = settings.mapDistanceToVolume(dist)
      beeper.updateVolume(to: volume)
    }

    // Continue with existing direction-based speech
    let newDirection = settings.getDirection(normalizedX: midx)

    let timePassed = Date().timeIntervalSince(timeLastSpoken)
    if !settings.enableSpeech {
      // Skip speech if disabled
      lastDirection = newDirection
    } else if newDirection == lastDirection && timePassed > settings.speechRepeatInterval {
      timeLastSpoken = Date()
      lastDirection = newDirection
      speaker.speak(text: "Still " + newDirection.rawValue, rate: Float(settings.speechRate))
    } else if newDirection != lastDirection && timePassed > settings.speechChangeInterval {
      timeLastSpoken = Date()
      lastDirection = newDirection
      speaker.speak(text: newDirection.rawValue, rate: Float(settings.speechRate))
    }
  }
  
  public func announce(candidate: Candidate) {
    // Build phrase first
    guard let phrase = MatchStatusSpeech.phrase(
      for: candidate.matchStatus,
      recognisedText: candidate.ocrText,
      detectedDescription: candidate.detectedDescription,
      rejectReason: candidate.rejectReason) else { return }
    let now = Date()
    // Global waiting logic – say only once until progress.
    switch candidate.matchStatus {
    case .waiting:
      if hasSpokenWaiting { return }
      hasSpokenWaiting = true
    case .partial, .full:
      hasSpokenWaiting = false
    default:
      break
    }

    // Skip if status hasn't changed for this candidate
    if lastStatusByCandidate[candidate.id] == candidate.matchStatus {
      return
    }
    lastStatusByCandidate[candidate.id] = candidate.matchStatus

    // Global suppression
    if let g = lastGlobalPhrase, g.phrase == phrase,
       now.timeIntervalSince(g.time) < settings.speechRepeatInterval {
      return
    }
    if let last = lastPhraseByCandidate[candidate.id], last.phrase == phrase,
       now.timeIntervalSince(last.time) < settings.speechRepeatInterval {
      return // skip repeat within interval for same candidate
    }
    // speak and record
    speaker.speak(text: phrase)
    lastPhraseByCandidate[candidate.id] = (phrase, now)
    lastGlobalPhrase = (phrase, now)
  }
}
*/
