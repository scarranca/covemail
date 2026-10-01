import XCTest

@testable import CoveCore

final class CalendarMeetingsTests: XCTestCase {
  func testZeroLengthEventsNoLongerBreakTheBoundedRead() async throws {
    let item = #"{"id":"pin","summary":"Reminder","start":{"dateTime":"2026-09-24T18:00:00Z"},"end":{"dateTime":"2026-09-24T18:00:00Z"}}"#
    let client = GoogleCalendarClient(transport: MockHTTP { _ in Data("{\"items\":[\(item)]}".utf8) })
    let events = try await client.events(token: "synthetic", from: Date(timeIntervalSince1970: 1_790_000_000),
                                         to: Date(timeIntervalSince1970: 1_790_100_000), maxPages: 2)
    XCTAssertEqual(events.count, 1)
  }

  func testSearchSendsTheQueryAndKeepsGoingAcrossPages() async throws {
    let seen = Locked<[URLRequest]>([])
    let client = GoogleCalendarClient(transport: MockHTTP { request in
      seen.mutate { $0.append(request) }
      let second = request.url?.query?.contains("pageToken=p2") == true
      return Data((second
        ? #"{"items":[{"id":"b","summary":"Pricing","start":{"dateTime":"2026-05-02T16:00:00Z"},"end":{"dateTime":"2026-05-02T17:00:00Z"}}]}"#
        : #"{"items":[{"id":"a","summary":"Kickoff","start":{"dateTime":"2026-02-02T16:00:00Z"},"end":{"dateTime":"2026-02-02T17:00:00Z"}}],"nextPageToken":"p2"}"#).utf8)
    })
    let found = try await client.search(token: "synthetic", query: "contacto@grupo-amx.com",
                                        from: Date(timeIntervalSince1970: 1_760_000_000), to: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(found.events.map(\.title), ["Kickoff", "Pricing"])
    XCTAssertTrue(found.complete)
    let query = try XCTUnwrap(seen.value.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
    XCTAssertEqual(query.first { $0.name == "q" }?.value, "contacto@grupo-amx.com")
  }

  func testPersonMatchingByAddressOrName() {
    var withManuel = LocalEvent(title: "Weekly sync", start: Date(), end: Date().addingTimeInterval(1800))
    withManuel.attendees = [CalendarAttendee(name: "Manuel Pérez", email: "contacto@grupo-amx.com", response: "accepted", isSelf: nil)]
    var organized = LocalEvent(title: "Contract", start: Date(), end: Date().addingTimeInterval(1800))
    organized.organizerEmail = "CONTACTO@grupo-amx.com"
    let mentions = LocalEvent(title: "Notes about contacto@grupo-amx.com", start: Date(), end: Date().addingTimeInterval(1800))
    let other = LocalEvent(title: "Lunch", start: Date(), end: Date().addingTimeInterval(1800))
    let events = [withManuel, organized, mentions, other]
    XCTAssertEqual(CalendarSearch.with("contacto@grupo-amx.com", in: events).map(\.title), ["Weekly sync", "Contract"],
                   "an address must be a guest or the organizer, not a word in the title")
    XCTAssertEqual(CalendarSearch.with("manuel", in: events).map(\.title), ["Weekly sync"])
  }
}

final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
  func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

final class CalendarFilesTests: XCTestCase {
  func testGeminiNotesAndTranscriptsComeThroughAsLinks() throws {
    let json = #"""
    {"id":"demo","summary":"Demo gigstack","start":{"dateTime":"2026-07-01T22:00:00Z"},"end":{"dateTime":"2026-07-01T22:30:00Z"},
     "attachments":[
      {"fileUrl":"https://docs.google.com/document/d/abc/edit","title":"Notas de Gemini","mimeType":"application/vnd.google-apps.document"},
      {"fileUrl":"https://docs.google.com/document/d/def/edit","title":"Demo gigstack - Transcript","mimeType":"application/vnd.google-apps.document"},
      {"fileUrl":"https://drive.google.com/file/d/ghi/view","title":"Demo gigstack - Recording","mimeType":"video/mp4"},
      {"fileUrl":"https://evil.example.com/x","title":"Notes"}]}
    """#
    let event = try XCTUnwrap(JSONDecoder().decode(GoogleCalendarClient.Event.self, from: Data(json.utf8)).local())
    let files = try XCTUnwrap(event.files)
    XCTAssertEqual(files.map(\.kind), [.notes, .transcript, .recording, .file])
    XCTAssertNil(files[3].safeURL, "only Google's own file links open")
    XCTAssertNotNil(files[0].safeURL)
  }
}

final class CalendarGuestsTests: XCTestCase {
  private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
  }
  private let created = Data(#"{"id":"new1","summary":"Demo","start":{"dateTime":"2026-10-02T16:00:00Z"},"end":{"dateTime":"2026-10-02T16:30:00Z"}}"#.utf8)

  func testCreateInvitesGuestsAndAddsMeet() async throws {
    let seen = Locked<URLRequest?>(nil)
    let response = created
    let client = GoogleCalendarClient(transport: MockHTTP { request in seen.mutate { $0 = request }; return response })
    _ = try await client.create(token: "t", title: "Demo", start: Date(), end: Date().addingTimeInterval(1800),
                                guests: ["contacto@grupo-amx.com", "CONTACTO@grupo-amx.com", "ana@example.com"], addMeet: true)
    let request = try XCTUnwrap(seen.value)
    let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(items.contains(URLQueryItem(name: "sendUpdates", value: "all")))
    XCTAssertTrue(items.contains(URLQueryItem(name: "conferenceDataVersion", value: "1")))
    let attendees = try XCTUnwrap(body(request)["attendees"] as? [[String: Any]])
    XCTAssertEqual(attendees.compactMap { $0["email"] as? String }, ["contacto@grupo-amx.com", "ana@example.com"], "duplicates collapse")
  }

  func testCreateWithoutGuestsSendsNoInvitationsAndBadAddressesAreRefused() async throws {
    let seen = Locked<URLRequest?>(nil)
    let response = created
    let client = GoogleCalendarClient(transport: MockHTTP { request in seen.mutate { $0 = request }; return response })
    _ = try await client.create(token: "t", title: "Focus", start: Date(), end: Date().addingTimeInterval(1800))
    XCTAssertNil(seen.value?.url?.query, "no guests, no sendUpdates")
    XCTAssertNil(try body(XCTUnwrap(seen.value))["attendees"])
    XCTAssertThrowsError(try GoogleCalendarClient.guestList(["Manuel"]))
  }

  func testUpdateKeepsExistingGuestsResponsesAndInvitesOnlyNewOnes() async throws {
    let seen = Locked<URLRequest?>(nil)
    let response = created
    let client = GoogleCalendarClient(transport: MockHTTP { request in seen.mutate { $0 = request }; return response })
    var event = LocalEvent(title: "Demo", start: Date(), end: Date().addingTimeInterval(1800))
    event.googleID = "abc123"
    event.attendees = [CalendarAttendee(name: "Me", email: "me@example.com", response: "accepted", isSelf: true),
                       CalendarAttendee(name: "AMX", email: "contacto@grupo-amx.com", response: "accepted", isSelf: nil),
                       CalendarAttendee(name: "Old", email: "old@example.com", response: "needsAction", isSelf: nil)]
    _ = try await client.update(token: "t", event: event, title: "Demo", start: event.start, end: event.end,
                                guests: ["contacto@grupo-amx.com", "new@example.com"])
    let attendees = try XCTUnwrap(body(XCTUnwrap(seen.value))["attendees"] as? [[String: Any]])
    XCTAssertEqual(attendees.compactMap { $0["email"] as? String }, ["contacto@grupo-amx.com", "new@example.com", "me@example.com"])
    XCTAssertEqual(attendees[0]["responseStatus"] as? String, "accepted", "an existing guest's answer is kept")
    XCTAssertNil(attendees[1]["responseStatus"])
  }
}
