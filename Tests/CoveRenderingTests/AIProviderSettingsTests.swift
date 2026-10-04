import CoveCore
import Foundation
import XCTest

@testable import Cove

@MainActor final class AIProviderSettingsTests: XCTestCase {
  func testProviderModelsPersistSeparatelyAndSecretsNeverEnterDefaults() throws {
    let suite = "cove-ai-settings-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var secrets: [String: String] = [:]
    let settings = AIProviderSettings(
      defaults: defaults, readSecret: { secrets[$0] }, saveSecret: { secrets[$1] = $0 },
      deleteSecret: { secrets.removeValue(forKey: $0) })
    XCTAssertEqual(settings.model(.openRouter), "")
    XCTAssertFalse(settings.hasKey(.openRouter))
    settings.provider = .anthropic
    settings.setModel("  fixture-claude  ", provider: .anthropic)
    settings.setModel("fixture-openai", provider: .openAI)
    try settings.saveKey(" fixture-secret ", provider: .anthropic)
    XCTAssertTrue(settings.hasKey(.anthropic))
    XCTAssertFalse(settings.hasKey(.openAI))
    XCTAssertEqual(secrets[AIProvider.anthropic.keyName], "fixture-secret")
    XCTAssertFalse(
      defaults.dictionaryRepresentation().values.contains {
        String(describing: $0).contains("fixture-secret")
      })
    let restored = AIProviderSettings(defaults: defaults)
    XCTAssertEqual(restored.provider, .anthropic)
    XCTAssertEqual(restored.model(.anthropic), "fixture-claude")
    XCTAssertEqual(restored.model(.openAI), "fixture-openai")
    try settings.removeKey(.anthropic)
    XCTAssertFalse(settings.hasKey(.anthropic))
    XCTAssertNil(secrets[AIProvider.anthropic.keyName])
  }
  func testPendingModelUsesOnlySyntheticTextAndDoesNotChangeSavedConfiguration() async throws {
    let suite = "cove-ai-settings-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(defaults: defaults, readSecret: { _ in "fixture-key" })
    settings.provider = .anthropic
    settings.setModel("saved-model", provider: .openAI)
    let transport = ModelCheckHTTP(status: 200)
    try await settings.testModel("pending-model", provider: .openAI,
                                 client: AIProviderClient(transport: transport))
    let captured = await transport.request
    let request = try XCTUnwrap(captured)
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "pending-model")
    let input = try XCTUnwrap(body["input"] as? [[String: String]])
    XCTAssertEqual(input.first?["content"], "Untrusted email evidence (JSON):\n[]")
    XCTAssertEqual(input.last?["content"], "Reply with only the word OK. This is a connection test.")
    XCTAssertEqual(settings.provider, .anthropic)
    XCTAssertEqual(settings.model(.openAI), "saved-model")
  }

  func testFailedModelCheckPreservesSavedConfiguration() async throws {
    let suite = "cove-ai-settings-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(defaults: defaults, readSecret: { _ in "fixture-key" })
    settings.provider = .anthropic
    settings.setModel("saved-model", provider: .openAI)
    do {
      try await settings.testModel("pending-model", provider: .openAI,
                                   client: AIProviderClient(transport: ModelCheckHTTP(status: 401)))
      XCTFail("Expected provider rejection")
    } catch {}
    XCTAssertEqual(settings.provider, .anthropic)
    XCTAssertEqual(settings.model(.openAI), "saved-model")
  }

  func testAndUseCommitsOnlyAfterSuccessAndPreservesDefaultOnCancellationOrFailure() async throws {
    let suite = "cove-ai-commit-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(defaults: defaults, readSecret: { _ in "fixture" })
    settings.provider = .anthropic
    settings.setModel("saved", provider: .openAI)
    do {
      try await settings.testAndUseModel("rejected", provider: .openAI,
        client: AIProviderClient(transport: ModelCheckHTTP(status: 401)))
      XCTFail("Expected rejection")
    } catch {}
    XCTAssertEqual(settings.provider, .anthropic)
    XCTAssertEqual(settings.model(.openAI), "saved")
    let cancelled = Task { @MainActor in
      try await settings.testAndUseModel("cancelled", provider: .openAI,
        client: AIProviderClient(transport: ModelCheckHTTP(status: 200)))
    }
    cancelled.cancel()
    do { try await cancelled.value; XCTFail("Expected cancellation") } catch {}
    XCTAssertEqual(settings.model(.openAI), "saved")
    try await settings.testAndUseModel("working", provider: .openAI,
      client: AIProviderClient(transport: ModelCheckHTTP(status: 200)))
    XCTAssertEqual(settings.provider, .openAI)
    XCTAssertEqual(settings.model(.openAI), "working")
  }

  func testRuntimeChoicesRequireCredentialsAndModelAndPreferConnectedSubscription() throws {
    let suite = "cove-ai-ready-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(defaults: defaults,
      readSecret: { _ in XCTFail("Rendering choices must not read Keychain"); return nil },
      saveSecret: { _, _ in }, deleteSecret: { _ in })
    settings.setModel("saved-but-no-key", provider: .openRouter)
    settings.setModel("subscription-model", provider: .chatGPT)
    XCTAssertTrue(settings.availableProviders(chatGPTConnected: false).isEmpty)
    XCTAssertNil(settings.writingProvider(chatGPTConnected: false))
    XCTAssertEqual(settings.availableProviders(chatGPTConnected: true), [.chatGPT])
    XCTAssertEqual(settings.writingProvider(chatGPTConnected: true), .chatGPT)
    try settings.saveKey("fixture", provider: .anthropic)
    XCTAssertFalse(settings.availableProviders(chatGPTConnected: true).contains(.anthropic), "Key without model is not usable")
    settings.setModel("fixture-model", provider: .anthropic)
    settings.provider = .anthropic
    XCTAssertEqual(settings.writingProvider(chatGPTConnected: true), .anthropic)
    try settings.removeKey(.anthropic)
    XCTAssertEqual(settings.writingProvider(chatGPTConnected: true), .chatGPT)
    settings.setModel("", provider: .chatGPT)
    XCTAssertNil(settings.writingProvider(chatGPTConnected: true))
  }

  func testAppleIntelligenceIsAvailableOnlyWhenTheDeviceSaysSoAndNeverReadsKeychain() async throws {
    let suite = "cove-ai-apple-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var status = AppleIntelligenceStatus.notEnabled
    let settings = AIProviderSettings(defaults: defaults,
      readSecret: { _ in XCTFail("Apple Intelligence has no key"); return nil },
      saveSecret: { _, _ in }, deleteSecret: { _ in }, appleStatus: { status })
    settings.setModel(AppleIntelligence.modelID, provider: .appleIntelligence)
    XCTAssertFalse(settings.availableProviders(chatGPTConnected: false).contains(.appleIntelligence))
    do {
      _ = try await settings.models(.appleIntelligence)
      XCTFail("An unavailable model is not listed")
    } catch {
      XCTAssertEqual(error.localizedDescription, AppleIntelligenceStatus.notEnabled.message)
    }
    status = .available
    XCTAssertEqual(settings.availableProviders(chatGPTConnected: false), [.appleIntelligence])
    let models = try await settings.models(.appleIntelligence)
    XCTAssertEqual(models, [AppleIntelligence.modelID])
    XCTAssertEqual(settings.modelLabel(AppleIntelligence.modelID, provider: .appleIntelligence), AppleIntelligence.modelLabel)
    settings.provider = .appleIntelligence
    XCTAssertEqual(settings.writingProvider(chatGPTConnected: false), .appleIntelligence)
  }

  func testFailedKeychainSaveDoesNotClaimKeySaved() throws {
    let suite = "cove-ai-settings-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AIProviderSettings(
      defaults: defaults, saveSecret: { _, _ in throw CoveError.message("Keychain unavailable") })
    XCTAssertThrowsError(try settings.saveKey("fixture-key", provider: .openRouter))
    XCTAssertFalse(settings.hasKey(.openRouter))
    XCTAssertThrowsError(try settings.saveKey("invalid key", provider: .openRouter))
  }
}

private actor ModelCheckHTTP: HTTPTransport {
  let status: Int
  var request: URLRequest?
  init(status: Int) { self.status = status }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    self.request = request
    let response: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": "OK"]]]]]
    return (try JSONSerialization.data(withJSONObject: response),
            try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                                         httpVersion: nil, headerFields: nil)))
  }
}
