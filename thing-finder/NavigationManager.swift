//
//  DetectionManager.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/12/25.
//

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
}
class NavigationManager {
  var lastDirection: Direction?
  var timeLastSpoken = Date()
  let speaker = Speaker()
  func handle(_ event: NavEvent, box: BoundingBox? = nil, in imageSpace: (width: Int, height: Int)? = nil) {
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
      speaker.speak(text: "No match")
      timeLastSpoken = Date()
      break
    case .lost:
      speaker.speak(text: "Lost")
      timeLastSpoken = Date()
      break
    case .found:
      navigate(to: box!, in: imageSpace!)
    }
  }

  private func navigate(to box: BoundingBox, in imageSpace: (width: Int, height: Int)) {
    let normalizedBox = NormalizedRect(
      imageRect: box.imageRect, in: CGSize(width: imageSpace.width, height: imageSpace.height)
    ).cgRect
    let midx = normalizedBox.midX
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
