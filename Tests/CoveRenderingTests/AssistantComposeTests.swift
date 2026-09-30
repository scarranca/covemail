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

    // From the assistant, the draft is saved but stays closed so the chat can show it inline.
    store.showComposer = false
    _ = try await store.draftNewEmail(request, question: "make an intro between Alberto and Maya", present: false) { prompt in
      prompt.system.contains("You plan read-only evidence lookups") ? #"{"tools":[]}"# : "Hi both,\n\nMeet each other."
    }
    XCTAssertFalse(store.showComposer)
    XCTAssertEqual(store.mails.first { $0.id == store.composeID }?.body, "Hi both,\n\nMeet each other.")
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

  func testTwoMarthasAskOnceThenTheChosenOneGetsTheDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveCompose-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.mails = [
      Mail(id: "g", sender: "Martha Salazar", senderEmail: "martha@gigstack.io", subject: "Account", body: "Hi"),
      Mail(id: "i", sender: "Martha Cayetano Rico", senderEmail: "mpcrico@icloud.com", subject: "Hola", body: "Hola"),
    ]
    let write: (AIPrompt) async throws -> String = { prompt in
      prompt.system.contains("You plan read-only evidence lookups") ? #"{"tools":[]}"# : "Hi Martha,\n\nHow are the account and process going?"
    }
    let ask = AssistantCalendar.ComposeRequest(recipients: ["Martha"], subject: "", purpose: "Ask how the account is going", intro: false)
    let first = try await store.draftNewEmail(ask, question: "Write an email to Martha", present: false, write: write)
    guard case .ambiguous(let name, let candidates) = first else { return XCTFail("\(first)") }
    XCTAssertEqual(name, "Martha")
    let chosen = try XCTUnwrap(RecipientResolver.pick(from: candidates, reply: "@gigstack one"))
    let resumed = AssistantCalendar.ComposeRequest(recipients: [chosen.email], subject: "", purpose: ask.purpose, intro: false)
    let second = try await store.draftNewEmail(resumed, question: "Write an email to Martha", present: false, write: write)
    guard case .opened(let people, _) = second else { return XCTFail("\(second)") }
    XCTAssertEqual(people.map(\.email), ["martha@gigstack.io"])
    XCTAssertEqual(store.mails.first { $0.id == store.composeID }?.to, "Martha Salazar <martha@gigstack.io>")
    XCTAssertFalse(store.mails.contains { $0.labels.contains("SENT") })
  }
}
