//  CandidateStore.swift
//  thing-finder
//
//  Observable collection of candidates accessed by all pipeline services.
//  Thread-safe with main-thread publishes for SwiftUI.
//
//  NOTE: Mutation helpers run synchronously – callers are responsible for
//  ensuring they execute on the main thread.  Background queues must wrap
//  calls in `DispatchQueue.main.async { ... }`.

import Combine
import Foundation

/// Store publishes snapshots so observers have value-type semantics.
public final class CandidateStore: ObservableObject {
  /// Current candidates keyed by id.
  @Published private(set) public var candidates: [CandidateID: Candidate] = [:]

  public init() {}

  // MARK: Mutation helpers
  public func upsert(_ candidate: Candidate) {
    candidates[candidate.id] = candidate
  }

  public func remove(id: CandidateID) {
    candidates.removeValue(forKey: id)
  }

  public func update(id: CandidateID, _ modify: (inout Candidate) -> Void) {
    guard var value = candidates[id] else { return }
    modify(&value)
    value.lastUpdated = Date()
    candidates[id] = value
  }

  public func clear() {
    candidates.removeAll()
  }

  // Utility: check if this is likely a duplicate of an existing candidate using IoU and center distance
  public func containsDuplicateOf(
    _ bbox: CGRect, iouThreshold: CGFloat = 0.6, centerDistanceThreshold: CGFloat = 0.15
  ) -> Bool {
    for cand in candidates.values {
      // Check IoU overlap first (fast)
      if cand.lastBoundingBox.iou(with: bbox) > iouThreshold {
        return true
      }

      // If IoU check passes, also check center distance (handles cases where boxes shifted but centers close)
      let centerX1 = Double(bbox.midX)
      let centerY1 = Double(bbox.midY)
      let centerX2 = Double(cand.lastBoundingBox.midX)
      let centerY2 = Double(cand.lastBoundingBox.midY)

      let distance = sqrt(pow(centerX1 - centerX2, 2) + pow(centerY1 - centerY2, 2))
      if distance < Double(centerDistanceThreshold) {
        return true
      }
    }
    return false
  }

  public subscript(id: CandidateID) -> Candidate? {
    get { candidates[id] }
    set { candidates[id] = newValue }
  }
}
