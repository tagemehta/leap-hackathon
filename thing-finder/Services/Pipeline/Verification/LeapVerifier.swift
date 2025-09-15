import Combine
import LeapSDK
import SwiftUI

// Define the constrained generation type for verification results
@Generatable("Verification result for an object in an image")
struct ObjectVerificationResult: Codable {
  @Guide(
    "Whether the object in the image matches the description. True if it matches or is similar to the user described object"
  )
  let match: Bool

  @Guide("Confidence level from 0.0 to 1.0 that this is a match")
  let confidence: Double

  @Guide("Short description of what was seen in the image. 8 words or less")
  let description: String

  @Guide(
    "Reason for the match result. Use 'success' for matches, otherwise provide a specific reason. Keep it to 7 words or less"
  )
  let reason: String? = "unknown"
}

public final class LeapVerifier: ImageVerifier {
  public func timeSinceLastVerification() -> TimeInterval {
    return Date().timeIntervalSince(lastVerifiedDate)
  }

  private var lastVerifiedDate = Date()
  private var visionModelRunner: ModelRunner?
  private var chatModelRunner: ModelRunner?
  private var isReady = false

  public let targetClasses: [String]
  public let targetTextDescription: String
  private let confidenceThreshold: Double = 0.86

  public init(targetClasses: [String], targetTextDescription: String) {
    self.targetClasses = targetClasses
    self.targetTextDescription = targetTextDescription
    Task {
      await setupModel()
    }
  }

  private func setupModel() async {
    do {
      guard
        let visionModelURL = Bundle.main.url(
          forResource: "LFM2-VL-450M_8da4w",
          withExtension: "bundle"
        ),
        let chatModelURL = Bundle.main.url(
          forResource: "LFM2-350M-8da4w_output_8da8w-seq_4096",
          withExtension: "bundle"
        )
      else {
        print("Could not find model bundle")
        return
      }

      visionModelRunner = try await Leap.load(url: visionModelURL)
      chatModelRunner = try await Leap.load(url: chatModelURL)
      isReady = true
    } catch {
      print("Failed to load model: \(error)")
    }
  }

  public func verify(image: UIImage) -> AnyPublisher<VerificationOutcome, Error> {
    lastVerifiedDate = Date()
    print("[LeapVerifier] Starting verification process")

    // Create a subject to publish the verification result
    let subject = PassthroughSubject<VerificationOutcome, Error>()
    if !isReady {
      print("[LeapVerifier] Model not ready, sending failure")
      subject.send(
        completion: .failure(
          NSError(
            domain: "LeapVerifier", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])))
      return subject.eraseToAnyPublisher()  // <- don’t proceed
    }

    // Start the verification process asynchronously on a high priority background thread
    Task(priority: .userInitiated) {
      do {
        print("[LeapVerifier] Starting async verification task")
        let result = try await verifyImage(image)
        print("[LeapVerifier] Got verification result: \(result), sending to subject")

        // Make sure we're on the main thread for Combine operations
        await MainActor.run {
          subject.send(result)
          print("[LeapVerifier] Sent result to subject, sending completion")
          subject.send(completion: .finished)
          print("[LeapVerifier] Sent completion to subject")
        }
      } catch {
        print("[LeapVerifier] Error in verification: \(error)")
        await MainActor.run {
          subject.send(completion: .failure(error))
        }
      }
    }

    print("[LeapVerifier] Returning publisher")
    return subject.eraseToAnyPublisher()
  }

  private func verifyImage(_ image: UIImage) async throws -> VerificationOutcome {
    guard let visionRunner = visionModelRunner else {
      throw NSError(
        domain: "LeapVerifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
    }

    // Convert image to base64 for processing
    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
      throw NSError(
        domain: "LeapVerifier", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
    }

    // -------- Step 1: Vision model produces a detailed natural-language description --------
    let visionConv = Conversation(modelRunner: visionRunner, history: [])
    let visionPrompt =
      "Describe the main object in this image in rich, unstructured detail. Focus on color, shape, size, make/model if a vehicle, and any distinguishing marks."
    let visionMessage = ChatMessage(
      role: .user,
      content: [
        .text(visionPrompt),
        .image(imageData),
      ])
    func generateVisionDescription() async throws -> String {
      var visionDescription = ""
      for try await part in visionConv.generateResponse(message: visionMessage) {
        switch part {
        case .chunk(let token):
          visionDescription += token
        case .complete(let fullText, _):
          print("complete: \(fullText)")
          continue
        default:
          break
        }
      }
      return visionDescription
    }

    let visionDescription = try await generateVisionDescription()
    return try await verifyTextDescription(visionDescription)
  }
  private func verifyTextDescription(_ visionDescription: String) async throws
    -> VerificationOutcome
  {
    guard let chatRunner = chatModelRunner else {
      throw NSError(
        domain: "LeapVerifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
    }

    print("FINISHED VISION \(visionDescription)")

    // -------- Step 2: Chat model determines if description matches target --------
    let systemPrompt = """
      You are an expert object verification system. Your task is to determine if an object described by a vision model matches what a user is looking for.

      IMPORTANT RULES:
      1. If the vision model describes the same TYPE of object the user is looking for, set match to true, even if some details differ.
      2. If your explanation is consistent with the user's you MUST set match to true
      3. The confidence should reflect how closely the details match (higher = better match).
      4. Always provide a short description of what was seen.
      """

    let chatConv = Conversation(
      modelRunner: chatRunner,
      history: [ChatMessage(role: .system, content: [.text(systemPrompt)])])

    let userQuery = """
      Given the following user target description: \(targetTextDescription)

      And the vision model's observed description: \(visionDescription)

      You must determine if the vision model's description matches what the user is looking for.
      If the vision model describes something that matches or is similar to what the user described, set match to true.
      If the vision model describes something different from what the user described, set match to false.

      Important: If the vision model describes the same type of object that the user is looking for, you should set match to true.
      Show bias towards being a match in all reasonable scenarios
      """
    let chatMessage = ChatMessage(role: .user, content: [.text(userQuery)])

    var options = GenerationOptions()
    options.temperature = 0.4
    try options.setResponseFormat(type: ObjectVerificationResult.self)

    var structured: ObjectVerificationResult?
    var fullText = ""
    for try await resp in chatConv.generateResponse(
      message: chatMessage, generationOptions: options)
    {
      switch resp {
      case .chunk(let text):
        fullText += text
      default: continue
      }
    }

    structured = try? JSONDecoder().decode(
      ObjectVerificationResult.self, from: fullText.data(using: .utf8)!)
    print("FINISHED CHAT \(fullText)")

    guard let result = structured else {
      print("booohooo")
      throw NSError(
        domain: "LeapVerifier", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Failed to decode structured response"])
    }
    print("MATCH \(result)")
    // Map structured result to VerificationOutcome
    let rejectReason: RejectReason? = result.match ? nil : .wrongModelOrColor

    // Apply confidence threshold
    //    if result.match && result.confidence < confidenceThreshold {
    //      return VerificationOutcome(
    //        isMatch: false,
    //        description: result.description,
    //        rejectReason: .lowConfidence
    //      )
    //    }

    return VerificationOutcome(
      isMatch: result.match || result.confidence > confidenceThreshold,
      description: result.description,
      rejectReason: rejectReason
    )
  }
}
