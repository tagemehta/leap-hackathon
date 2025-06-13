//
//  IdentifiedObject.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/12/25.
//

import SwiftUI
import Vision

struct IdentifiedObject: Identifiable, Equatable {
  let id = UUID()
  var box: BoundingBox
  var observation: VNRecognizedObjectObservation
  var trackingRequest: VNTrackObjectRequest
  var lostInTracking: Int  // Number of frames it's been lost for
  init(
    box: BoundingBox,
    observation: VNRecognizedObjectObservation,
    trackingRequest: VNTrackObjectRequest,
    lostInTracking: Int = 0
  ) {
    self.box = box
    self.observation = observation
    self.trackingRequest = trackingRequest
    self.lostInTracking = lostInTracking
  }
  // Objects that occupy the same space are considered the same
  // WARNING: HARD CODED IOU THRESHOLD
  static func == (lhs: IdentifiedObject, rhs: IdentifiedObject) -> Bool {
    return lhs.box.viewRect.iou(with: rhs.box.viewRect) > 0.85
  }
}
