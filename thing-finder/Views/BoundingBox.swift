//
//  BoundingBox.swift
//  thing-finder
//
//  Created by Tage Mehta on 6/9/25.
//
import SwiftUI
import Vision

struct BoundingBoxView: View {
  let box: BoundingBox
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        // Box background
        Rectangle()
          .strokeBorder(box.color, lineWidth: 4)
          .frame(
            width: box.viewRect.width,
            height: box.viewRect.height
          )
          .position(
            x: box.viewRect.midX,
            y: box.viewRect.midY
          )
          .opacity(box.alpha)

        // Label background
        if !box.label.isEmpty {
          Text(box.label + " " + String(format: "%.2f", box.alpha))
            .font(.caption)
            .padding(4)
            .background(box.color.opacity(0.8))
            .foregroundColor(.white)
            .cornerRadius(4)
            .position(
              x: box.viewRect.minX + 4,
              y: box.viewRect.minY - 10
            )
            .fixedSize()
        }
      }
    }
  }
}

struct BoundingBoxViewOverlay: View {
  @Binding var boxes: [BoundingBox]
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        ForEach(boxes) { box in
          BoundingBoxView(
            box: box
          )
        }
      }
    }
    .allowsHitTesting(false)
  }
}
