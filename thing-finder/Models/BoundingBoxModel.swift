//
//  BoundingBox.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/12/25.
//

import SwiftUI

struct BoundingBox: Identifiable, Hashable {
  let id = UUID()
  var imageRect: CGRect
  var viewRect: CGRect
  var label: String
  var color: Color
  var alpha: Double

  init(
    imageRect: CGRect, viewRect: CGRect, label: String, color: Color = .blue, alpha: Double = 0.3
  ) {
    self.imageRect = imageRect
    self.viewRect = viewRect
    self.label = label
    self.color = Color(color)
    self.alpha = alpha
  }
}
