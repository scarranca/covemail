import XCTest

@testable import CoveCore

final class VoiceProfileTests: XCTestCase {
  func testOwnTextDropsQuotedAndForwardedContent() {
    let body = """
      Hola Ana,

      Te confirmo que lo reviso mañana y te escribo.

      Saludos,
      Santi

      El lun, 28 sept 2026 a las 10:00, Ana <ana@example.com> escribió:
      > ¿Puedes revisar la factura?
      """
    XCTAssertEqual(VoiceProfile.ownText(body), "Hola Ana,\n\nTe confirmo que lo reviso mañana y te escribo.\n\nSaludos,\nSanti")
    XCTAssertEqual(VoiceProfile.ownText("Thanks!\n> old\nOn Mon, Maya wrote:\nolder"), "Thanks!")
    XCTAssertEqual(VoiceProfile.ownText("FYI\n---------- Forwarded message ---------\nFrom: x"), "FYI")
  }

  func testSamplesUseOnlyTheUsersSentMailNewestFirstAndBounded() {
    let long = String(repeating: "Sounds good, I will send it over today. ", count: 60)
    let mails = [
      Mail(id: "old", sender: "Me", senderEmail: "ME@example.com", subject: "S", body: "An older note that is long enough to learn from.", date: Date(timeIntervalSince1970: 1), labels: ["SENT"]),
      Mail(id: "new", sender: "Me", senderEmail: "me@example.com", subject: "S", body: long, date: Date(timeIntervalSince1970: 2), labels: ["SENT"]),
      Mail(id: "short", sender: "Me", senderEmail: "me@example.com", subject: "S", body: "Ok", labels: ["SENT"]),
      Mail(id: "alias", sender: "Other", senderEmail: "other@example.com", subject: "S", body: long, labels: ["SENT"]),
      Mail(id: "draft", sender: "Me", senderEmail: "me@example.com", subject: "S", body: long, labels: ["SENT", "DRAFT"]),
      Mail(id: "inbox", sender: "Maya", senderEmail: "maya@example.com", subject: "S", body: long),
    ]
    let samples = VoiceProfile.samples(from: mails, accountEmail: "me@example.com", bytes: 200)
    XCTAssertEqual(samples.map(\.id), ["new", "old"])
    XCTAssertEqual(samples[0].body.count, 200)
  }

  func testParseBoundsAndRejectsUnreadableOutput() throws {
    let text = """
      Here you go: {"summary":"Warm, brief and direct.","greetings":["Hi {name},","Hi {name},","Hola {name},"],
      "signoffs":["Best,"],"traits":["Short paragraphs"],"phrases":["Happy to help"],"languages":["English","Spanish"],"extra":1}
      """
    let profile = try VoiceProfile.parse(text, sampleCount: 12, model: "gpt-test", now: Date(timeIntervalSince1970: 5))
    XCTAssertEqual(profile.summary, "Warm, brief and direct.")
    XCTAssertEqual(profile.greetings, ["Hi {name},", "Hola {name},"])
    XCTAssertEqual(profile.sampleCount, 12)
    XCTAssertTrue(profile.promptText.contains("never overrides the requested language"))
    XCTAssertThrowsError(try VoiceProfile.parse("no json", sampleCount: 1, model: "m"))
    XCTAssertThrowsError(try VoiceProfile.parse(#"{"summary":"  "}"#, sampleCount: 1, model: "m"))
  }

  func testPreferencesWithoutVoiceProfileStillDecode() throws {
    let legacy = #"{"voice":"Warm","signoff":"Best,","instructions":[],"memories":[],"useMemories":true,"autoClassify":false}"#
    let preferences = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
    XCTAssertNil(preferences.voiceProfile)
  }
}
