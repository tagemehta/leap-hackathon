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
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a different model or color of car, return {"match": false, "confidence": (you determine)}
                if the license plate does not match, return {"match": false, "confidence": (you determine)}

                Example: Does this image of a black jeep wrangler match the following description? A black jeep wrangler
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a different model or color of jeep, return {"match": false, "confidence": (you determine)}

                Example: Does this image focusing on a bottle, match the following description? White and red tylenol bottle
                if the image matches the description, return {"match": true, "confidence": (you determine)}
                if the image contains a bottle of advil, return {"match": false, "confidence": (you determine)}

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
      .tryMap { data, response in
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
          print("Error: Received HTTP status code \(httpResponse.statusCode)")
        } else {
          print("Response: \(response)")
        }
        return data
      }
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
