import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why Apple Intelligence can or cannot answer on this device right now.
public enum AppleIntelligenceStatus: Equatable, Sendable {
  case available
  /// macOS before 26, iOS before 26, or a build made with an SDK that lacks Foundation Models.
  case unsupportedSystem
  case deviceNotEligible
  case notEnabled
  /// Apple Intelligence is on, but its model is still downloading or preparing.
  case modelNotReady
  case unavailable

  public var isAvailable: Bool { self == .available }
  public var message: String {
    switch self {
    case .available: "Ready on this device. Free, private, and no account needed."
    case .unsupportedSystem: "Apple Intelligence needs macOS 26 or iOS 26 or later."
    case .deviceNotEligible: "This device doesn’t support Apple Intelligence."
    case .notEnabled: "Turn on Apple Intelligence in System Settings to use it in Cove."
    case .modelNotReady: "Apple Intelligence is still getting ready. Try again in a few minutes."
    case .unavailable: "Apple Intelligence isn’t available right now."
    }
  }
}

/// Apple's on-device language model through the Foundation Models framework. Requests never leave the
/// device and need no key; the model is small, so prompts are rebuilt with tighter evidence limits.
public enum AppleIntelligence {
  /// The single model id Cove saves for this provider.
  public static let modelID = "apple-on-device"
  public static let modelLabel = "Apple on-device model"
  /// The on-device model shares about 4,096 tokens between instructions, the prompt and the reply.
  /// About 11 KB of text (roughly 3,000 tokens) leaves room for a reply of up to ~900 tokens.
  public static let inputByteBudget = 11_000
  public static let maximumResponseTokens = 900
  static let tooLongMessage =
    "This request is too long for Apple Intelligence on this device. Choose another model for it, or ask about fewer emails."

  public static var status: AppleIntelligenceStatus {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, *) { return liveStatus() }
    #endif
    return .unsupportedSystem
  }

  /// The instructions and the prompt text the model will see, shrinking the evidence until both fit.
  /// Throws when even the smallest version is too long (for example a long draft or a large routing prompt).
  public static func fit(_ prompt: AIPrompt, budget: Int = inputByteBudget) throws -> (instructions: String, input: String) {
    for limits in [AIPromptLimits.onDevice, .onDeviceMinimal] {
      let fitted = try prompt.resized(limits)
      let input = (fitted.hasEvidence ? fitted.dataMessage + "\n\n" : "") + "User request:\n" + fitted.user
      if fitted.system.utf8.count + input.utf8.count <= budget { return (fitted.system, input) }
    }
    throw CoveError.message(tooLongMessage)
  }

  /// Runs one request on the on-device model. `onPartial` receives the full text so far while it streams.
  public static func complete(_ prompt: AIPrompt, onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
    let current = Self.status
    guard current.isAvailable else { throw CoveError.message(current.message) }
    let (instructions, input) = try fit(prompt)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, *) {
      let text = try await run(instructions: instructions, input: input, onPartial: onPartial)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoveError.message("Apple Intelligence returned no text. Try rewording the request.")
      }
      return String(text.prefix(32_000))
    }
    #endif
    throw CoveError.message(AppleIntelligenceStatus.unsupportedSystem.message)
  }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
extension AppleIntelligence {
  static func liveStatus() -> AppleIntelligenceStatus {
    switch SystemLanguageModel.default.availability {
    case .available: return .available
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible: return .deviceNotEligible
      case .appleIntelligenceNotEnabled: return .notEnabled
      case .modelNotReady: return .modelNotReady
      @unknown default: return .unavailable
      }
    @unknown default: return .unavailable
    }
  }

  static func run(instructions: String, input: String, onPartial: (@MainActor (String) -> Void)?) async throws -> String {
    // A new session per request: Cove sends the whole context each time, like its other providers.
    let session = LanguageModelSession(model: .default, instructions: instructions)
    let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)
    do {
      guard let onPartial else { return try await session.respond(to: input, options: options).content }
      var latest = ""
      for try await snapshot in session.streamResponse(to: input, options: options) {
        latest = snapshot.content
        await onPartial(latest)
      }
      return latest
    } catch let error as LanguageModelSession.GenerationError {
      switch error {
      case .exceededContextWindowSize: throw CoveError.message(tooLongMessage)
      case .guardrailViolation:
        throw CoveError.message("Apple Intelligence declined this request. Try rewording it, or choose another model.")
      case .unsupportedLanguageOrLocale:
        throw CoveError.message("Apple Intelligence doesn’t support this language yet. Choose another model for it.")
      case .assetsUnavailable:
        throw CoveError.message(AppleIntelligenceStatus.modelNotReady.message)
      default:
        throw CoveError.message("Apple Intelligence couldn’t finish this request. Try again, or choose another model.")
      }
    }
  }
}
#endif
