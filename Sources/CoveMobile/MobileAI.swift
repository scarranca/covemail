#if os(iOS)
import CoveCore
import Foundation
import Observation

/// AI on iPhone: Apple Intelligence (on device, no account) or the user's own API key. The ChatGPT and
/// Claude subscription connections run the official CLIs and stay on the Mac. Keys live in Keychain;
/// only the chosen provider and model names are in UserDefaults.
@MainActor @Observable final class MobileAI {
  static let providers: [AIProvider] = [.appleIntelligence, .anthropic, .openAI, .openRouter]
  private let defaults: UserDefaults
  private let client: AIProviderClient
  private let appleStatus: () -> AppleIntelligenceStatus
  private var revision = 0

  var provider: AIProvider {
    didSet { defaults.set(provider.rawValue, forKey: "ai.selectedProvider") }
  }

  init(defaults: UserDefaults = .standard, client: AIProviderClient = AIProviderClient(),
       appleStatus: @escaping () -> AppleIntelligenceStatus = { AppleIntelligence.status }) {
    self.defaults = defaults
    self.client = client
    self.appleStatus = appleStatus
    let saved = AIProvider(rawValue: defaults.string(forKey: "ai.selectedProvider") ?? "")
    // Apple Intelligence is the default: free, private, and ready with no setup on supported iPhones.
    provider = saved.flatMap { Self.providers.contains($0) ? $0 : nil } ?? .appleIntelligence
  }

  var apple: AppleIntelligenceStatus {
    _ = revision
    return appleStatus()
  }
  /// Re-reads Apple Intelligence's status (it changes in Settings while Cove is in the background).
  func refreshStatus() { revision += 1 }

  func model(_ provider: AIProvider) -> String {
    _ = revision
    if provider.isAppleIntelligence { return AppleIntelligence.modelID }
    return defaults.string(forKey: "ai.model." + provider.rawValue) ?? ""
  }
  func modelLabel(_ model: String, provider: AIProvider) -> String {
    provider.isAppleIntelligence ? AppleIntelligence.modelLabel : model
  }
  func setModel(_ model: String, provider: AIProvider) {
    defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model." + provider.rawValue)
    revision += 1
  }
  func hasKey(_ provider: AIProvider) -> Bool {
    _ = revision
    return defaults.bool(forKey: "ai.saved." + provider.rawValue)
  }
  func saveKey(_ key: String, provider: AIProvider) throws {
    let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard provider.usesAPIKey, !cleaned.isEmpty, !cleaned.contains(where: \.isWhitespace) else {
      throw CoveError.message("Enter a valid API key.")
    }
    try MobileKeychain.save(cleaned, name: provider.keyName)
    defaults.set(true, forKey: "ai.saved." + provider.rawValue)
    revision += 1
  }
  func removeKey(_ provider: AIProvider) throws {
    try MobileKeychain.delete(provider.keyName)
    defaults.removeObject(forKey: "ai.saved." + provider.rawValue)
    defaults.removeObject(forKey: "ai.model." + provider.rawValue)
    revision += 1
  }

  /// Connected (key saved, or Apple Intelligence ready). A model is still needed to use it.
  func isConnected(_ provider: AIProvider) -> Bool {
    provider.isAppleIntelligence ? apple.isAvailable : hasKey(provider)
  }
  func isReady(_ provider: AIProvider) -> Bool { isConnected(provider) && !model(provider).isEmpty }
  var ready: Bool { isReady(provider) }

  func models(_ provider: AIProvider) async throws -> [String] {
    if provider.isAppleIntelligence {
      guard apple.isAvailable else { throw CoveError.message(apple.message) }
      return [AppleIntelligence.modelID]
    }
    return try await client.models(provider: provider, key: MobileKeychain.read(provider.keyName) ?? "")
  }

  /// Tests a model with a short sample (no email), then makes it the default only if the test passes.
  func testAndUse(_ model: String, provider: AIProvider) async throws {
    let prompt = try AIPrompt(intent: .write, instruction: "Reply with only the word OK. This is a connection test.", mails: [])
    _ = try await run(prompt, provider: provider, model: model, onPartial: nil)
    try Task.checkCancellation()
    if !provider.isAppleIntelligence { setModel(model, provider: provider) }
    self.provider = provider
  }

  func complete(_ prompt: AIPrompt, onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
    guard ready else {
      throw CoveError.message(provider.isAppleIntelligence
        ? apple.message : "Choose an AI model in Settings → AI models first.")
    }
    return try await run(prompt, provider: provider, model: model(provider), onPartial: onPartial)
  }

  private func run(_ prompt: AIPrompt, provider: AIProvider, model: String,
                   onPartial: (@MainActor (String) -> Void)?) async throws -> String {
    if provider.isAppleIntelligence { return try await AppleIntelligence.complete(prompt, onPartial: onPartial) }
    return try await client.complete(provider: provider, key: MobileKeychain.read(provider.keyName) ?? "",
                                     model: model, prompt: prompt)
  }
}
#endif
