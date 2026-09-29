import XCTest

@testable import CoveCore

final class OAuthCalendarTests: XCTestCase {
  func testPKCEAndOAuthCallbackValidation() {
    XCTAssertEqual(
      OAuthSupport.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    XCTAssertEqual(
      OAuthSupport.response(
        request:
          "GET /oauth/callback?state=expected&code=abc%2F123 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        expectedState: "expected"), .code("abc/123"))
    XCTAssertNil(
      OAuthSupport.response(
        request: "GET /oauth/callback?state=wrong&code=abc HTTP/1.1", expectedState: "expected"))
    XCTAssertNil(
      OAuthSupport.response(
        request: "GET /oauth/callback?state=expected&state=wrong&code=abc HTTP/1.1",
        expectedState: "expected"))
    XCTAssertNil(
      OAuthSupport.response(
        request: "POST /oauth/callback?state=expected&code=abc HTTP/1.1", expectedState: "expected")
    )
    XCTAssertEqual(
      OAuthSupport.response(
        request: "GET /oauth/callback?state=expected&error=access_denied HTTP/1.1",
        expectedState: "expected"), .denied)
  }
  func testCalendarAuthorizationKeepsGrantedScopesForConnectedAccount() {
    func items(_ url: URL) -> [String: String] {
      Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
    }
    let add = items(OAuthSupport.authorizationURL(
      clientID: "id.apps.googleusercontent.com", redirect: "http://127.0.0.1:1/oauth/callback",
      state: "s", challenge: "c", includeCalendar: true, includeCloud: false, loginHint: "alex@example.com"))
    XCTAssertEqual(add["scope"], OAuthSupport.gmailScope + " " + OAuthSupport.calendarScope)
    XCTAssertEqual(add["login_hint"], "alex@example.com")
    XCTAssertEqual(add["include_granted_scopes"], "true")
    XCTAssertEqual(add["access_type"], "offline")
    XCTAssertEqual(add["code_challenge_method"], "S256")
    let first = items(OAuthSupport.authorizationURL(
      clientID: "id.apps.googleusercontent.com", redirect: "http://127.0.0.1:1/oauth/callback",
      state: "s", challenge: "c", includeCalendar: false, includeCloud: true))
    XCTAssertEqual(first["scope"], OAuthSupport.gmailScope + " openid email")
    XCTAssertNil(first["login_hint"])
    XCTAssertNil(first["include_granted_scopes"])
  }
  func testCalendarOverlapAndMidnightClipping() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = Date(timeIntervalSince1970: 0)
    let events = [
      LocalEvent(
        title: "A", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(11 * 3600)),
      LocalEvent(
        title: "B", start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(12 * 3600)
      ),
      LocalEvent(
        title: "C", start: day.addingTimeInterval(12 * 3600), end: day.addingTimeInterval(13 * 3600)
      ),
      LocalEvent(
        title: "Overnight", start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600)),
    ]
    let layout = CalendarLayout.arrange(events, on: day, calendar: calendar)
    XCTAssertEqual(layout.first?.startMinute, 0)
    XCTAssertEqual(layout.first?.endMinute, 60)
    let overlapping = layout.filter { $0.event.title == "A" || $0.event.title == "B" }
    XCTAssertEqual(Set(overlapping.map(\.column)).count, 2)
    XCTAssertTrue(overlapping.allSatisfy { $0.columns == 2 })
    XCTAssertEqual(layout.last?.columns, 1)
  }
}
