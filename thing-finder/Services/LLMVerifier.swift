import Combine
import Foundation

final class LLMVerifier {
  private var lastVerifiedDate = Date()
  private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
  private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    return encoder
  }()
  private let jsonDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    return decoder
  }()
  private let apiKey = Bundle.main.infoDictionary!["OPENAI_API"] as! String

  let targetClasses: [String]
  let targetTextDescription: String

  init(targetClasses: [String], targetTextDescription: String) {
    self.targetClasses = targetClasses
    self.targetTextDescription = targetTextDescription
  }

  public struct VerificationOutcome {
    public let isMatch: Bool
    public let description: String
    public let rejectReason: String?
  }

  public func verify(imageData: String) -> AnyPublisher<VerificationOutcome, Error> {
    lastVerifiedDate = Date()
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = ChatCompletionRequest(
      model: "gpt-4o",
      messages: [
        Message(
          role: "system",
          content: [
            MessageContent(
              text:
                """
                You are an AI assistant that determines 
                if the object in the pictured image matches the description.
                Respond strictly in JSON format as per the provided schema.
                You are doing this for a blind audience in an app that helps them navigate to objects.
                Accuracy is mission critical.

                Example: Does this image, focusing on a car, match the following description? Silver honda crv with license plate 123456789.

                IMPORTANT: IF THE PLATE IS NOT VISIBLE, BUT THE REST OF THE DESCRIPTION IS CORRECT, RETURN {"match": true, "confidence": (you determine)}

                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a different model or color of car, return {"match": false, "confidence": (you determine)}
                if the license plate does not match, return {"match": false, "confidence": (you determine)}

                if the license plate is visible but wrong, return {"match": false, "confidence": (you determine)}
                For cars, we run a secondary license plate verification step.

                Example: Does this image of a black jeep wrangler match the following description? A black jeep wrangler
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a different model or color of jeep, return {"match": false, "confidence": (you determine)}

                Example: Does this image focusing on a bottle, match the following description? White and red tylenol bottle
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a bottle of advil, return {"match": false, "confidence": (you determine)}

                Example: Does this image, focusing on a laptop, match the following description? Silver macbook air
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a different model or color of laptop, return {"match": false, "confidence": (you determine)}

                """
            )
          ]),
        Message(
          role: "user",
          content: [
            MessageContent(
              text:
                "Does this image, focusing on \(targetClasses.joined(separator: ", or ")), match the following description? \(targetTextDescription)"
            ),
            MessageContent(imageURL: "data:image/png;base64,\(imageData)"),
          ]),
      ],
      tools: [
        Tool(
          function: Function(
            name: "match_object",
            description: "Determines if the image matches the given description.",
            parameters: FunctionParameters(
              type: "object",
              properties: [
                "match": FunctionProperty(
                  type: "boolean", description: "Indicates if the image matches the description."),
                "confidence": FunctionProperty(
                  type: "number", description: "How confident are you in this prediction"),
                "reason": FunctionProperty(
                  type: "string", description: "If match=false, why not? One enum value.",
                  enumValues: [
                    "success",
                    "unclear_image",
                    "wrong_object_class",
                    "wrong_model_or_color",
                    // "license_plate_not_visible",
                    "license_plate_mismatch",
                    "other_mismatch",
                  ]),
                "description": FunctionProperty(
                  type: "string", description: "Short natural-language description of the object"),
              ],
              required: ["match", "confidence", "description", "reason"]
            )
          ))
      ],
      max_tokens: 50
    )

    do {
      request.httpBody = try jsonEncoder.encode(payload)
    } catch {
      return Fail(error: error).eraseToAnyPublisher()
    }
    return URLSession.shared.dataTaskPublisher(for: request)
      .tryMap(\.data)
      .decode(type: ChatCompletionResponse.self, decoder: jsonDecoder)
      .tryMap { [weak self] response in

        if let argsString = response.choices.first?.message.tool_calls?[0].function.arguments {
          let argsData = argsString.data(using: .utf8)!
          let matchResult = try self!.jsonDecoder.decode(MatchResult.self, from: argsData)
          let rej: String? = matchResult.match ? nil : matchResult.reason
          let v = VerificationOutcome(
            isMatch: matchResult.match, description: matchResult.description,
            rejectReason: rej)
          return v
        } else {
          return VerificationOutcome(isMatch: false, description: "", rejectReason: nil)
        }
      }
      .eraseToAnyPublisher()
  }

  public func timeSinceLastVerification() -> TimeInterval {
    return Date().timeIntervalSince(lastVerifiedDate)
  }
}
