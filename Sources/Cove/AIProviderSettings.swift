import CoveCore
import Foundation
import Observation

@MainActor @Observable final class AIProviderSettings {
  static let shared = AIProviderSettings()
  private let defaults: UserDefaults
  private let client: AIProviderClient
  let claude: ClaudeConnection
  private let readSecret: (String) throws -> String?
  private let saveSecret: (String, String) throws -> Void
  private let deleteSecret: (String) throws -> Void
  /// Whether Apple Intelligence can run on this Mac now (injectable for tests).
  let appleStatus: () -> AppleIntelligenceStatus
  var provider: AIProvider {
    didSet { defaults.set(provider.rawValue, forKey: "ai.selectedProvider") }
  }
  var revision = 0
  let modelCatalog = AssistantModelCatalog()
  init(
    defaults: UserDefaults = .standard,
    readSecret: @escaping (String) throws -> String? = { try Vault.read($0) },
    saveSecret: @escaping (String, String) throws -> Void = { try Vault.save($0, name: $1) },
    deleteSecret: @escaping (String) throws -> Void = { try Vault.delete($0) },
    client: AIProviderClient = AIProviderClient(),
    claude: ClaudeConnection? = nil,
    appleStatus: @escaping () -> AppleIntelligenceStatus = { AppleIntelligence.status }
  ) {
    self.defaults = defaults
    self.appleStatus = appleStatus
    self.claude = claude ?? .shared
    self.client = client
    self.readSecret = readSecret
    self.saveSecret = saveSecret
    self.deleteSecret = deleteSecret
    provider =
      AIProvider(rawValue: defaults.string(forKey: "ai.selectedProvider") ?? "")
      ?? .openRouter
  }
  func model(_ provider: AIProvider) -> String {
    _ = revision
    return defaults.string(forKey: "ai.model." + provider.rawValue) ?? ""
  }
  func setModel(_ model: String, provider: AIProvider) {
    defaults.set(
      model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model." + provider.rawValue
    )
    revision += 1
  }
  func saveKey(_ key: String, provider: AIProvider) throws {
    let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, !cleaned.contains(where: \.isWhitespace) else {
      throw CoveError.message("Enter a valid API key.")
    }
    try saveSecret(cleaned, provider.keyName)
    modelCatalog.clear(provider)
    defaults.set(true, forKey: "ai.saved." + provider.rawValue)
    revision += 1
  }
  func hasKey(_ provider: AIProvider) -> Bool {
    _ = revision
    return defaults.bool(forKey: "ai.saved." + provider.rawValue)
  }
  func removeKey(_ provider: AIProvider) throws {
    try deleteSecret(provider.keyName)
    modelCatalog.clear(provider)
    defaults.removeObject(forKey: "ai.saved." + provider.rawValue)
    revision += 1
  }
  /// Runtime choices only include providers with both a model and an account/key.
  /// Keychain is read when executing, never while SwiftUI evaluates its body.
  func availableProviders(chatGPTConnected: Bool? = nil) -> [AIProvider] {
    AIProvider.allCases.filter {
      !model($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && ($0 == .chatGPT ? (chatGPTConnected ?? ChatGPTConnection.shared.connected) : $0 == .claudeSubscription ? claude.connected
          : $0 == .appleIntelligence ? appleStatus().isAvailable : hasKey($0))
    }
  }
  func writingProvider(chatGPTConnected: Bool? = nil) -> AIProvider? {
    let available = availableProviders(chatGPTConnected: chatGPTConnected)
    if available.contains(provider) { return provider }
    return available.contains(.chatGPT) ? .chatGPT : available.first
  }
  /// A saved, tested subscription default counts as set up while the CLI's sign-in check is still running,
  /// so setup doesn't flash "not connected" at launch. A finished check that finds no sign-in ends that.
  var hasWorkingDefault: Bool {
    if writingProvider() != nil { return true }
    guard !model(provider).isEmpty else { return false }
    switch provider {
    case .chatGPT: return !ChatGPTConnection.shared.checked
    case .claudeSubscription: return !claude.checked
    default: return false
    }
  }
  func restoreWritingConnection() async {
    if !model(.claudeSubscription).isEmpty, !claude.connected { try? await claude.refresh() }
    guard !model(.chatGPT).isEmpty, !ChatGPTConnection.shared.connected else { return }
    // Restore the existing subscription session; never start a login flow from Compose.
    try? await ChatGPTConnection.shared.refresh()
  }
  func models(_ provider: AIProvider) async throws -> [String] {
    let available: [String]
    if provider == .chatGPT { available = try await ChatGPTConnection.shared.models() }
    else if provider == .claudeSubscription { available = try await claude.models() }
    else if provider == .appleIntelligence {
      let status = appleStatus()
      guard status.isAvailable else { throw CoveError.message(status.message) }
      available = [AppleIntelligence.modelID]
    } else {
      available = try await client.models(provider: provider, key: readSecret(provider.keyName) ?? "")
    }
    try Task.checkCancellation()
    modelCatalog.replaceModels(available, for: provider)
    return modelCatalog.models[provider] ?? []
  }
  func modelLabel(_ model: String, provider: AIProvider) -> String {
    provider == .claudeSubscription ? claude.modelLabel(model)
      : provider == .appleIntelligence && model == AppleIntelligence.modelID ? AppleIntelligence.modelLabel : model
  }
  /// Validates a pending selection using synthetic text without changing the active configuration.
  func testModel(_ model: String, provider: AIProvider, client: AIProviderClient = AIProviderClient()) async throws {
    let prompt = try AIPrompt(
      intent: .write, instruction: "Reply with only the word OK. This is a connection test.", mails: [])
    if provider == .chatGPT {
      _ = try await ChatGPTConnection.shared.complete(model: model, prompt: prompt)
    } else if provider == .claudeSubscription {
      _ = try await claude.complete(model: model, prompt: prompt)
    } else if provider == .appleIntelligence {
      _ = try await AppleIntelligence.complete(prompt)
    } else {
      _ = try await client.complete(provider: provider, key: readSecret(provider.keyName) ?? "",
                                    model: model, prompt: prompt)
    }
  }
  /// Commit only after the synthetic test succeeds; failures and cancellation keep the old default.
  func testAndUseModel(_ model: String, provider: AIProvider, client: AIProviderClient = AIProviderClient()) async throws {
    try await testModel(model, provider: provider, client: client)
    try Task.checkCancellation()
    setModel(model, provider: provider)
    self.provider = provider
  }
  func complete(_ prompt: AIPrompt, provider: AIProvider? = nil, model: String? = nil,
                onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
    // Asked while the subscription's sign-in check is still starting up: finish that check first.
    if provider == nil, writingProvider() == nil, hasWorkingDefault { await restoreWritingConnection() }
    guard let selected = provider ?? writingProvider() else {
      throw CoveError.message("Connect a writing provider and save a model in Integrations first.")
    }
    let selectedModel = model ?? self.model(selected)
    if selected == .chatGPT {
      return try await ChatGPTConnection.shared.complete(model: selectedModel, prompt: prompt, onPartial: onPartial)
    }
    if selected == .claudeSubscription {
      return try await claude.complete(model: selectedModel, prompt: prompt)
    }
    if selected == .appleIntelligence {
      return try await AppleIntelligence.complete(prompt, onPartial: onPartial)
    }
    return try await client.complete(
      provider: selected, key: readSecret(selected.keyName) ?? "", model: selectedModel,
      prompt: prompt)
  }
}
