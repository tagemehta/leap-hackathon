//
//  NavigationManager.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/12/25.
//

import AVFoundation
import CoreHaptics
import Foundation
import Vision

enum NavEvent {
  case start(targetClasses: [String], targetTextDescription: String)
  case searching
  case noMatch
  case lost
  case found
  case expired
}
class NavigationManager {
  // Settings for configurable parameters
  private let settings: Settings
  var lastDirection: Direction?
  var timeLastSpoken = Date()
  let speaker = Speaker()
  private let beeper = SmoothBeeper()
  private var currentInterval: TimeInterval?

  init(settings: Settings = Settings()) {
    self.settings = settings
  }
  func handle(
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
}
