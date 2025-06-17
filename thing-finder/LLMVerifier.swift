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

  public func verify(imageData: String) -> AnyPublisher<Bool, Error> {
    lastVerifiedDate = Date()
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = ChatCompletionRequest(
      model: "gpt-4o",
      messages: [
        Message(role: "system", content: [MessageContent(text: "You are an AI assistant...")]),
        Message(
          role: "user",
          content: [
            MessageContent(
              text:
                "Does this image, focusing on \(targetClasses.joined(separator: ", or")), match the following description? \(targetTextDescription)"
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
              ],
              required: ["match", "confidence"]
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
          return matchResult.match && matchResult.confidence > 0.8
        } else {
          return false
        }
      }
      .eraseToAnyPublisher()
  }

  public func timeSinceLastVerification() -> TimeInterval {
    return Date().timeIntervalSince(lastVerifiedDate)
  }
}
