//  VerifierService+OCR.swift
//  thing-finder
//
//  Adds licence-plate OCR verification to VerifierService.
//  Created by Cascade AI on 2025-07-17.

import CoreGraphics
import Foundation
import Vision

extension VerifierService {
  // MARK: - OCR Helper
  func enqueueOCR(
    for candidate: Candidate,
    fullImage: CGImage,
    imageSize: CGSize,
    orientation: CGImagePropertyOrientation,
    store: CandidateStore
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      // Re-map bbox to pixel rect (may be slightly outdated, acceptable)
      let (rect, _) = self.imgUtils.unscaledBoundingBoxes(
        for: candidate.lastBoundingBox,
        imageSize: imageSize,
        viewSize: imageSize,
        orientation: orientation)
      guard let crop = fullImage.cropping(to: rect) else { return }

      var recognized: String?
      var nextStatus: MatchStatus = .partial

      if let res = self.ocrEngine.recognize(crop: crop) {
        recognized = res.text
        let conf = res.confidence
        let regexOK =
          self.verificationConfig.regex.firstMatch(
            in: recognized!, options: [],
            range: NSRange(location: 0, length: recognized!.count)) != nil
        let plateMatch =
          self.verificationConfig.expectedPlate == nil
          || recognized == self.verificationConfig.expectedPlate
        if conf >= self.verificationConfig.ocrConfidenceMin && regexOK && plateMatch {
          nextStatus = .full
        }
//        else if regexOK && !plateMatch {
//          nextStatus = .rejected
//        }
      }

      // Update candidate on main queue
      DispatchQueue.main.async {
        store.update(id: candidate.id) { cand in
          cand.ocrAttempts += 1
          cand.ocrText = recognized
          if nextStatus == .partial && cand.ocrAttempts >= self.verificationConfig.maxOCRRetries {
            cand.matchStatus = .rejected
          } else {
            cand.matchStatus = nextStatus
          }
        }

      }
    }
  }
}

