import CoveCore
import XCTest
@testable import Cove

@MainActor final class AssistantComposeTests: XCTestCase {
  func testIntroRouteParsesAndNeverCarriesInventedAddressesIntoTheDraft() async throws {
    let agent = AssistantCalendar(complete: { prompt in
      XCTAssertTrue(prompt.system.contains("never invent, complete or guess an email address"))
      return #"{"action":"compose","recipients":["Alberto","Maya Chen"],"subject":"","purpose":"Connect them about invoicing","intro":true}"#
    }, calendar: { _, _ in [] }, calendarAvailable: false)
    guard case .compose(let request) = try await agent.respond("make an intro between Alberto and Maya", progress: { _ in })
    else { return XCTFail() }
    XCTAssertEqual(request.recipients, ["Alberto", "Maya Chen"])
    XCTAssertTrue(request.intro)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveCompose-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.mails = [
      Mail(id: "a", sender: "Alberto Díaz", senderEmail: "alberto@example.com", subject: "Factura", body: "Hola"),
      Mail(id: "m", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Invoices", body: "Hi"),
    ]
    var updated = store.preferences
    updated.voiceProfile = VoiceProfile(summary: "Warm and brief.", learnedAt: Date(), sampleCount: 5, model: "m")
    store.preferences = updated
    var instruction = ""
    let outcome = try await store.draftNewEmail(request, question: "make an intro between Alberto and Maya") { prompt in
      if prompt.system.contains("You plan read-only evidence lookups") { return #"{"tools":[]}"# }
      instruction = prompt.user
      return "Hi Alberto and Maya,\n\nYou two should talk about invoicing.\n\nBest,"
    }
    guard case .opened(let people, let subject) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(people.map(\.email), ["alberto@example.com", "maya@example.com"])
    XCTAssertEqual(subject, "Intro: Alberto ⟷ Maya")
    XCTAssertTrue(instruction.contains("This is an introduction"))
    XCTAssertTrue(instruction.contains("Warm and brief."))
    let draft = try XCTUnwrap(store.mails.first { $0.id == store.composeID })
    XCTAssertEqual(draft.to, "Alberto Díaz <alberto@example.com>, Maya Chen <maya@example.com>")
    XCTAssertTrue(draft.labels.contains("DRAFT"))
    XCTAssertTrue(store.showComposer)
    XCTAssertFalse(store.mails.contains { $0.labels.contains("SENT") })

    var single = ""
    _ = try await store.draftNewEmail(.init(recipients: ["Maya"], subject: "", purpose: "Introduce myself", intro: true),
      question: "introduce me to Maya") { prompt in
        if prompt.system.contains("You plan read-only evidence lookups") { return #"{"tools":[]}"# }
        single = prompt.user; return "Hi Maya," }
    XCTAssertFalse(single.contains("This is an introduction"), "A one-person intro is a normal new email")
    let unknown = try await store.draftNewEmail(
      .init(recipients: ["Luis"], subject: "", purpose: "", intro: false), question: "email Luis") { _ in
        XCTFail("Nothing is written until recipients are known"); return ""
      }
    guard case .clarification(let question) = unknown else { return XCTFail() }
    XCTAssertTrue(question.contains("Luis"))
  }
}
