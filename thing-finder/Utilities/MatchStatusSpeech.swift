//  MatchStatusSpeech.swift
//  thing-finder
//
//  Maps MatchStatus values to short, class-agnostic speech messages.
//
//  Created by Cascade AI on 2025-07-17.

import Foundation

enum MatchStatusSpeech {
  static func phrase(
    for status: MatchStatus, recognisedText: String? = nil, detectedDescription: String? = nil,
    rejectReason: RejectReason? = nil, normalizedXPosition: CGFloat? = nil, settings: Settings? = nil
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
        // Add directional information for wrong make/model
        if reason == .wrongModelOrColor, let normalizedX = normalizedXPosition, let settings = settings
        {
          let direction = settings.getDirection(normalizedX: normalizedX)
          return "\(desc) – \(reason.userFriendlyDescription) \(direction.rawValue)"
        }
        return "\(desc) – \(reason.userFriendlyDescription)"
      }
      return "Verification failed"
    case .unknown:
      return nil
    }
  }

  /// Get a phrase to announce when retrying due to a specific reason
  static func retryPhrase(for reason: RejectReason) -> String? {
    switch reason {
    case .unclearImage: return "Picture too blurry, trying again"
    case .insufficientInfo: return "Need a better view, retrying"
    case .lowConfidence: return "Not sure yet, taking another shot"
    case .apiError: return "Detection error, retrying"
    case .licensePlateNotVisible: return "Can't see the plate, retrying"
    case .ambiguous: return "Results unclear, retrying"
    default: return nil  // no speech for hard rejects
    }
  }
}
