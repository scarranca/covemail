import XCTest
import CoveCore
@testable import Cove

@MainActor final class VoiceLearningTests: XCTestCase {
  func testLearnedVoiceIsSavedEncryptedAndReloadedAfterReopeningTheMailbox() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveVoice-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 7, count: 32)
    let url = root.appendingPathComponent("mail.sqlite")
    let store = try AppStore(database: Database(url: url, encryptionKey: key, namespace: "voice"),
      accountEmail: "me@example.com", gmail: GmailClient(transport: VoiceHTTP()),
      gmailTokenProvider: { "fixture" }, syncClock: { Date(timeIntervalSince1970: 100) })
    store.mails = (1...16).map {
      Mail(id: "s\($0)", sender: "Me", senderEmail: "me@example.com", subject: "Update",
        body: "Hi team,\n\nQuick update number \($0): all good on my side.\n\nBest,\nMe\n\nOn Mon, X wrote:\n> secret quoted text",
        date: Date(timeIntervalSince1970: Double($0)), labels: ["SENT"])
    }
    var captured: AIPrompt?
    store.voiceWriter = { prompt in
      captured = prompt
      return #"{"summary":"Brief, friendly updates.","greetings":["Hi team,"],"signoffs":["Best,"],"traits":["Short"],"phrases":[],"languages":["English"]}"#
    }
    let profile = try await store.learnVoice()
    XCTAssertEqual(profile.sampleCount, 16)
    let prompt = try XCTUnwrap(captured)
    XCTAssertFalse(prompt.emails.contains("secret quoted text"))
    XCTAssertTrue(prompt.system.contains("Describe HOW the user writes"))
    // Reopen the same encrypted store, as after disconnecting and signing in again.
    let reopened = try AppStore(database: Database(url: url, encryptionKey: key, namespace: "voice"),
      accountEmail: "me@example.com", gmail: GmailClient(transport: VoiceHTTP()),
      gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    XCTAssertEqual(reopened.preferences.voiceProfile, profile)
    let instruction = ComposeSuggestion.instruction("Reply yes", voice: "Warm", instructions: [], selection: false,
      profile: reopened.preferences.voiceProfile)
    XCTAssertTrue(instruction.contains("Brief, friendly updates."))
    reopened.forgetVoice()
    XCTAssertNil(reopened.preferences.voiceProfile)
  }

  func testFewStoredSentEmailsFetchRecentSentMailWithoutRedownloadingStoredOnes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveVoice-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let http = SentPageHTTP()
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.mails = [Mail(id: "stored", sender: "Me", senderEmail: "me@example.com", subject: "S",
      body: "A stored note I wrote that is long enough to learn from.", labels: ["SENT"])]
    var sampled: [String] = []
    store.voiceWriter = { prompt in
      sampled = prompt.sourceMails.map(\.id)
      return #"{"summary":"Concise."}"#
    }
    try await store.learnVoice()
    XCTAssertEqual(Set(sampled), ["stored", "f1", "f2"])
    let requests = await http.requests
    XCTAssertEqual(requests.first { $0.contains("/messages?") }?.contains("labelIds=SENT"), true)
    XCTAssertTrue(requests.contains { $0.contains("/messages/stored?") && $0.contains("format=minimal") })
    XCTAssertFalse(requests.contains { $0.contains("/messages/stored?") && $0.contains("format=full") })
  }
}

private actor SentPageHTTP: HTTPTransport {
  var requests: [String] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!.absoluteString
    requests.append(url)
    let id = request.url!.lastPathComponent
    let object: [String: Any]
    if id == "messages" {
      object = ["messages": [["id": "stored"], ["id": "f1"], ["id": "f2"]]]
    } else if id == "stored" {
      object = ["labelIds": ["SENT"]]
    } else {
      let body = Data("Hi,\n\nThanks for the note \(id). I will follow up tomorrow morning.\n\nBest".utf8).base64URL
      object = ["id": id, "threadId": id, "labelIds": ["SENT"], "internalDate": "1000",
        "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "Me <me@example.com>"],
          ["name": "Subject", "value": "Re"]], "body": ["data": body]]]
    }
    return (try JSONSerialization.data(withJSONObject: object),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private struct VoiceHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("Stored sent mail should be enough: \(request.url!)")
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
  }
}
