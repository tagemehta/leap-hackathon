//
//  DetectionManager.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/12/25.
//

import AVFoundation
import Foundation
import Vision

enum Direction: String, Equatable {
  case right = "on your right"
  case left = "on your left"
  case center = "straight ahead"
}
enum NavEvent {
  case start(targetClasses: [String], targetTextDescription: String)
  case searching
  case noMatch
  case lost
  case found
  case expired
}
class NavigationManager {
  var lastDirection: Direction?
  var timeLastSpoken = Date()
  let speaker = Speaker()
  private let beeper = SmoothBeeper()
  private var currentInterval: TimeInterval?
  func handle(
    _ event: NavEvent, box: BoundingBox? = nil, in imageSpace: (width: Int, height: Int)? = nil
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
      if Date().timeIntervalSince(timeLastSpoken) > 4 {
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
      if let box = box, let imageSpace = imageSpace {
        navigate(to: box, in: imageSpace)
      } else {
        beeper.stop()
        currentInterval = nil
      }
    }
  }

  private func navigate(to box: BoundingBox, in imageSpace: (width: Int, height: Int)) {
    let midx = box.imageRect.midX / CGFloat(imageSpace.width)

    // Calculate distance from center (0.0 to 0.5)
    let distanceFromCenter = abs(midx - 0.5)

    // Use quadratic formula for interval calculation
    // Square the distance for quadratic effect (slower as it gets closer)
    // Base interval is now 0.2s (slower overall) up to 1.1s at edges
    let normalizedDistance = 1.0 - (distanceFromCenter * 2)  // 1.0 when centered, 0.0 at edges
    let quadraticFactor = normalizedDistance * normalizedDistance  // Quadratic effect
    let newInterval = 0.1 + (0.9 * (1.0 - quadraticFactor))  // 0.1s when centered, up to 1s at edges

    // Smooth transition between intervals
    if currentInterval == nil {
      // First time, just start with the calculated interval
      beeper.start(interval: newInterval)
      currentInterval = newInterval
    } else {
      beeper.updateInterval(to: newInterval, smoothly: true)
      currentInterval = newInterval
    }

    // Continue with existing direction-based speech
    var newDirection: Direction
    // Split screen into thirds navigate by object midpoint
    if midx < 0.33 {
      newDirection = .left
    } else if midx > 0.66 {
      newDirection = .right
    } else {
      newDirection = .center
    }

    let timePassed = Date().timeIntervalSince(timeLastSpoken)
    if newDirection == lastDirection && timePassed > 4 {
      timeLastSpoken = Date()
      lastDirection = newDirection
      speaker.speak(text: "Still " + newDirection.rawValue)
    } else if newDirection != lastDirection && timePassed > 2 {
      timeLastSpoken = Date()
      lastDirection = newDirection
      speaker.speak(text: newDirection.rawValue)
    }
  }
}
