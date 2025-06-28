//
//  DetectionState.swift
//  thing-finder
//
//  Created by Sam Mehta on 6/25/25.
//


enum DetectionState: Equatable {
  case searching
  case verifying(candidates: [IdentifiedObject])
  case found(target: IdentifiedObject)
  var displayAllBoxes: Bool {
    switch self {
    case .searching: return true
    case .verifying(_): return true
    case .found(_): return false
    }
  }
}