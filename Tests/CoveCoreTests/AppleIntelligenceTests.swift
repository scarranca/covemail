import Foundation
import XCTest

@testable import CoveCore

final class AppleIntelligenceTests: XCTestCase {
  private func mail(_ index: Int, bytes: Int) -> Mail {
    Mail(id: "m\(index)", sender: "Sender \(index)", senderEmail: "s\(index)@example.com",
         subject: "Subject \(index)", body: String(repeating: "a", count: bytes))
  }

  func testAppleIntelligenceHasNoKeyAndIsNotASubscription() async {
    XCTAssertTrue(AIProvider.appleIntelligence.isAppleIntelligence)
    XCTAssertFalse(AIProvider.appleIntelligence.isSubscription)
    XCTAssertFalse(AIProvider.appleIntelligence.usesAPIKey)
    XCTAssertTrue(AIProvider.anthropic.usesAPIKey)
    XCTAssertFalse(AIProvider.chatGPT.usesAPIKey)
    do {
      _ = try await AIProviderClient().complete(
        provider: .appleIntelligence, key: "unused", model: AppleIntelligence.modelID,
        prompt: AIPrompt(intent: .write, instruction: "Hi", mails: []))
      XCTFail("Apple Intelligence never goes through the HTTP client")
    } catch {}
  }

  func testResizedKeepsTheRequestAndEmailOrderWithTighterLimits() throws {
    let mails = (1...6).map { mail($0, bytes: 5_000) }
    let prompt = try AIPrompt(intent: .answer, instruction: "What changed?", mails: mails, draft: "Draft",
                              evidence: String(repeating: "e", count: 3_000))
    XCTAssertEqual(prompt.sourceMails.count, 6)
    let small = try prompt.resized(.onDevice)
    XCTAssertEqual(small.intent, .answer)
    XCTAssertEqual(small.user, prompt.user)
    XCTAssertEqual(small.system, prompt.system)
    XCTAssertEqual(small.sourceMails.map(\.id), ["m1", "m2"], "4 KB of email at 2.5 KB each, in order")
    XCTAssertLessThanOrEqual(small.sourceMails.map(\.body.utf8.count).reduce(0, +), 4_000)
    XCTAssertTrue(small.evidence.hasPrefix("PARTIAL LOOKUP RESULTS"))
  }

  func testFitShrinksEvidenceUntilThePromptFitsTheOnDeviceBudget() throws {
    let prompt = try AIPrompt(intent: .write, instruction: "Reply yes",
                              mails: (1...10).map { mail($0, bytes: 6_000) })
    let (instructions, input) = try AppleIntelligence.fit(prompt)
    XCTAssertEqual(instructions, prompt.system)
    XCTAssertLessThanOrEqual(instructions.utf8.count + input.utf8.count, AppleIntelligence.inputByteBudget)
    XCTAssertTrue(input.hasSuffix("User request:\nReply yes"))
    XCTAssertTrue(input.contains("Untrusted email evidence"))
  }

  func testFitWithoutEvidenceSendsOnlyTheRequest() throws {
    let prompt = try AIPrompt(intent: .write, instruction: "Make this warmer", mails: [], draft: "Hi Ana")
    let (_, input) = try AppleIntelligence.fit(prompt)
    XCTAssertEqual(input, "User request:\nMake this warmer\n\nCurrent draft (text to edit):\nHi Ana")
  }

  func testFitRejectsRequestsThatCannotFitInsteadOfCuttingThem() throws {
    // Instructions alone larger than the budget can never fit, whatever the evidence.
    let routing = try AIPrompt(intent: .planAssistant, instruction: "Archive these", mails: [mail(1, bytes: 100)])
    XCTAssertThrowsError(try AppleIntelligence.fit(routing, budget: 2_000))
    let longDraft = try AIPrompt(intent: .write, instruction: "Shorten", mails: [],
                                 draft: String(repeating: "word ", count: 3_000))
    XCTAssertThrowsError(try AppleIntelligence.fit(longDraft)) { error in
      XCTAssertEqual(error.localizedDescription, AppleIntelligence.tooLongMessage)
    }
  }

  func testUnavailableStatusExplainsWhatToDo() {
    XCTAssertFalse(AppleIntelligenceStatus.notEnabled.isAvailable)
    XCTAssertTrue(AppleIntelligenceStatus.notEnabled.message.contains("Turn on Apple Intelligence"))
    XCTAssertTrue(AppleIntelligenceStatus.available.isAvailable)
  }
}
