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
class NavigationManager {
  var lastDirection: Direction?
  var timeLastSpoken = Date()
  let speaker = Speaker()
  func navigate(to box: BoundingBox, in imageSpace: (width: Int, height: Int)) {
    let normalizedBox = NormalizedRect(imageRect: box.imageRect, in: CGSize(width: imageSpace.width, height: imageSpace.height)).cgRect
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
