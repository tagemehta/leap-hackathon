//
//  DeviceRotationViewModifier.swift
//  thing-finder
//
//  Created by Sam Mehta on 6/16/25.
//
import SwiftUI

// Creating an onRotate function for all views
struct DeviceRotationViewModifier: ViewModifier {

  let action: (UIDeviceOrientation) -> Void

  func body(content: Content) -> some View {
    content
      .onAppear()
      .onReceive(
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
      ) { _ in
        action(UIDevice.current.orientation)
      }
  }
}

// A View wrapper to make the modifier easier to use
extension View {
  func onRotate(perform action: @escaping (UIDeviceOrientation) -> Void) -> some View {
    self.modifier(DeviceRotationViewModifier(action: action))
  }
}
