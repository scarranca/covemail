import XCTest

@testable import CoveCore

final class EventDescriptionTests: XCTestCase {
  let zone = TimeZone(identifier: "America/Mexico_City")!
  let now = ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z")!  // Thu 9:00 local

  func testFillsTitleTimesGuestsAndMeet() throws {
    let event = try EventDescription.parse(#"""
      ```json
      {"title":"Lunch with Maya","start":"2026-10-02T13:00:00-06:00","end":"2026-10-02T14:00:00-06:00","guests":["Maya","ana@example.com"],"meet":false,"question":""}
      ```
      """#, now: now, timeZone: zone)
    XCTAssertEqual(event.title, "Lunch with Maya")
    XCTAssertEqual(event.end!.timeIntervalSince(event.start!), 3_600)
    XCTAssertEqual(event.guests, ["Maya", "ana@example.com"])
    XCTAssertFalse(event.meet)
    XCTAssertNil(event.question)
  }

  func testMissingEndDefaultsToHalfAnHourAndMissingTimeAsks() throws {
    let short = try EventDescription.parse(#"{"title":"Call","start":"2026-10-02T10:00:00-06:00","end":"","meet":true}"#, now: now, timeZone: zone)
    XCTAssertEqual(short.end!.timeIntervalSince(short.start!), 1_800)
    XCTAssertTrue(short.meet)
    let vague = try EventDescription.parse(#"{"title":"Coffee with Luis","start":"","end":"","question":"Which day?"}"#, now: now, timeZone: zone)
    XCTAssertNil(vague.start)
    XCTAssertEqual(vague.question, "Which day?")
  }

  func testAPastStartIsNotUsedAndProseFails() throws {
    let past = try EventDescription.parse(#"{"title":"Standup","start":"2026-09-01T10:00:00-06:00","end":"2026-09-01T10:15:00-06:00"}"#, now: now, timeZone: zone)
    XCTAssertNil(past.start, "a misread date in the past never fills the editor")
    XCTAssertNotNil(past.question)
    XCTAssertThrowsError(try EventDescription.parse("Sure, I scheduled it!", now: now, timeZone: zone))
    XCTAssertTrue(AIIntent.describeEvent.instructions.contains("never invent or complete an address"))
  }
}

final class EventDescriptionFreeSpotTests: XCTestCase {
  func testFirstOpenSpotLeavesTheTimeToCove() throws {
    let zone = TimeZone(identifier: "America/Mexico_City")!
    let event = try EventDescription.parse(#"{"title":"Call with Manuel","start":"2026-10-02T10:00:00-06:00","end":"","guests":["Manuel"],"meet":true,"free":{"day":"","durationMinutes":30}}"#,
                                           now: ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z")!, timeZone: zone)
    XCTAssertNil(event.start, "the model never picks a free time itself")
    XCTAssertEqual(event.free, .init(day: nil, durationMinutes: 30, startMinute: 540, endMinute: 1020))
    XCTAssertNil(event.question)
    XCTAssertTrue(AIIntent.describeEvent.instructions.contains("first/next/earliest free or open spot"))
  }
}
