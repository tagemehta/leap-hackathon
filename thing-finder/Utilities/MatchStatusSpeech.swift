//  MatchStatusSpeech.swift
//  thing-finder
//
//  Maps MatchStatus values to short, class-agnostic speech messages.
//
//  Created by Cascade AI on 2025-07-17.

import Foundation

func compareAngles(_ then: Double, _ now: Double) -> Double
{
    var diff = now - then
    if diff > 180.0 {diff = diff - 360}
    if diff < -180.0 {diff = diff + 360}
    return diff // if diff>0 then is to the right of now, diff<0 left
}

enum MatchStatusSpeech {
  static func phrase(
    for status: MatchStatus, recognisedText: String? = nil, detectedDescription: String? = nil,
    rejectReason: String? = nil, lastDirection: Double = -1
  ) -> String? {
    switch status {
    case .waiting:
      return "Waiting for verification"
    case .partial:
      if let desc = detectedDescription {
        return "Found \(desc). Warning: Plate not visible yet"
      }
      return "Plate not visible yet"
    case .full:
      if let plate = recognisedText {
        return "Found matching plate \(plate)"
      }
      if let desc = detectedDescription {
        return "Found \(desc)"
      }
      return "Found match"
    case .rejected:
      if let desc = detectedDescription, let reason = rejectReason {
        return "\(desc) – " + prettyReason(reason)
      }
      return "Verification failed"
    case .unknown:
      return nil
    case .lost:
        let angle = round(compareAngles(lastDirection, CompassHeading.shared.degrees))
        if abs(angle) > 60.0
        {
            if angle > 0
            {return "car was last seen \(Int((abs(angle) / 30).rounded()*30)) degrees to the right"}
            if angle < 0
            {return "car was last seen \(Int((abs(angle) / 30).rounded()*30)) degrees to the left"}
        }
        return nil
    }
  }

  private static func prettyReason(_ raw: String) -> String {
    switch raw {
    case "unclear_image": return "image unclear"
    case "wrong_object_class": return "different object"
    case "wrong_model_or_color": return "different model or color"
    case "license_plate_not_visible": return "plate not visible"
    case "license_plate_mismatch": return "license plate mismatch"
    case "success": return "found"
    default: return "does not match"
    }
  }
}
