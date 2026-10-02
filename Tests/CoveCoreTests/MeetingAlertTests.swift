import XCTest

@testable import CoveCore

final class MeetingAlertTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_790_900_000)
  func event(_ title: String, in minutes: Double, length: Double = 30, guests: Bool = false, meet: String? = nil,
             location: String? = nil, response: String? = nil) -> LocalEvent {
    var e = LocalEvent(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60))
    e.meetURL = meet; e.location = location
    var attendees = [CalendarAttendee(name: "Me", email: "me@example.com", response: response ?? "accepted", isSelf: true)]
    if guests { attendees.append(CalendarAttendee(name: "Maya", email: "maya@example.com", response: "accepted", isSelf: nil)) }
    e.attendees = attendees
    return e
  }

  func testLevelsAndProminence() throws {
    let standup = event("Standup", in: 8, guests: true, meet: "https://meet.google.com/abc-defg-hij")
    let alert = try XCTUnwrap(MeetingAlert.next(in: [standup], now: now))
    XCTAssertEqual(alert.level, .soon)
    XCTAssertEqual(alert.title(), "Standup in 8m")
    XCTAssertTrue(alert.prominent)
    XCTAssertFalse(alert.urgent)
    let soonNow = try XCTUnwrap(MeetingAlert.next(in: [event("Standup", in: 0.5, guests: true, meet: "https://meet.google.com/x")], now: now))
    XCTAssertEqual(soonNow.level, .now)
    XCTAssertTrue(soonNow.urgent)
    XCTAssertEqual(soonNow.title(), "Join Standup")
    let focus = try XCTUnwrap(MeetingAlert.next(in: [event("Focus", in: 0)], now: now))
    XCTAssertFalse(focus.prominent, "no guests, no call: a quiet reminder")
    XCTAssertEqual(focus.title(), "Focus now")
    XCTAssertEqual(MeetingAlert.next(in: [event("Later", in: 90)], now: now)?.level, .later)
  }

  func testSkipsDeclinedAllDayFreeAndLongStarted() {
    var allDay = event("Holiday", in: 2); allDay.allDay = true
    var free = event("FYI", in: 2); free.blocksTime = false
    let declined = event("Sync", in: 3, response: "declined")
    let started = event("Old", in: -20)
    XCTAssertNil(MeetingAlert.next(in: [allDay, free, declined, started], now: now))
    XCTAssertEqual(MeetingAlert.next(in: [started, event("Next", in: 4), event("Late join", in: -3)], now: now)?.event.title, "Late join")
  }

  func testFindsCallLinksInLocationOrDetailsOnlyOnMeetingHosts() {
    XCTAssertEqual(MeetingLink.url(for: event("Zoom", in: 5, location: "https://us02web.zoom.us/j/123?pwd=x"))?.host, "us02web.zoom.us")
    var teams = event("Teams", in: 5); teams.details = "Join: https://teams.microsoft.com/l/meetup-join/19%3a123 (Teams)"
    XCTAssertEqual(MeetingLink.url(for: teams)?.host, "teams.microsoft.com")
    XCTAssertNil(MeetingLink.url(for: event("Office", in: 5, location: "https://evil.example.com/zoom.us")))
    XCTAssertNil(MeetingLink.url(for: event("Plain", in: 5, location: "http://meet.google.com/abc")), "https only")
  }
}
