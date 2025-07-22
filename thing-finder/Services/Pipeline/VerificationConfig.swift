//  VerificationConfig.swift
//  thing-finder
//
//  Defines configurable parameters controlling the secondary license-plate OCR
//  verification flow.
//
//  Created by Cascade AI on 2025-07-17.

import Foundation

public struct VerificationConfig {
  /// The exact license plate we expect (uppercase, no spaces). Optional.
  public var expectedPlate: String?

  /// Validation regex for recognised text. Defaults to US-style 5–8 alphanumerics.
  public var regex: NSRegularExpression

  /// Minimum confidence from Vision OCR [0,1].
  public var ocrConfidenceMin: Double

  /// Maximum times we will attempt OCR on a candidate before rejecting.
  public var maxOCRRetries: Int

  /// Time after which partial/full candidates should be re-verified (seconds).
  public var reverifyInterval: TimeInterval
  
  /// Whether we should run OCR for this verification cycle.
  public var shouldRunOCR: Bool

  /// Cool-down after a rejection to avoid spamming.
  public var cooldownAfterRejectSecs: TimeInterval

  public init(
    expectedPlate: String?,
    regex: NSRegularExpression = try! NSRegularExpression(
      pattern: "^[A-Z0-9]{5,8}$", options: .caseInsensitive),
    ocrConfidenceMin: Double = 0.2,  // What are the odds you get an almost exact match on a license plate w/ the same make model at the same time in the same place
    maxOCRRetries: Int = 30,
    cooldownAfterRejectSecs: TimeInterval = 10,
    shouldRunOCR: Bool = false,
    reverifyInterval: TimeInterval = 5
  ) {
    self.expectedPlate = expectedPlate?.uppercased()
    self.regex = regex
    self.ocrConfidenceMin = ocrConfidenceMin
    self.maxOCRRetries = maxOCRRetries
    self.cooldownAfterRejectSecs = cooldownAfterRejectSecs
    self.shouldRunOCR = shouldRunOCR
    self.reverifyInterval = reverifyInterval
  }
}
