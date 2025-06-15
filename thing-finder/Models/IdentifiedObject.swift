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
  var lostInTracking: Int  // Number of frames it's been lost for
  var box: BoundingBox

  // reference types
  var observation: VNRecognizedObjectObservation
  var trackingRequest: VNTrackObjectRequest
  var imageEmbedding: VNFeaturePrintObservation?
  init(
    box: BoundingBox,
    observation: VNRecognizedObjectObservation,
    trackingRequest: VNTrackObjectRequest,
    imageEmbedding: VNFeaturePrintObservation? = nil,
    lostInTracking: Int = 0
  ) {
    self.box = box
    self.observation = observation
    self.trackingRequest = trackingRequest
    self.lostInTracking = lostInTracking
    self.imageEmbedding = imageEmbedding
  }
  // Objects that occupy the same space are considered the same
  // WARNING: HARD CODED IOU THRESHOLD
  static func == (lhs: IdentifiedObject, rhs: IdentifiedObject) -> Bool {
    return lhs.box.viewRect.iou(with: rhs.box.viewRect) > 0.85
  }
}
