import Foundation

public struct GoogleCalendarClient {
  public var transport: HTTPTransport
  public init(transport: HTTPTransport = LiveHTTP()) { self.transport = transport }
  public struct Event: Decodable {
    public struct Moment: Decodable {
      var dateTime: String?
      var date: String?
    }
    public var id: String
    public var etag: String?
    public var recurringEventId: String?
    public struct Organizer: Decodable {
      public var displayName: String?
      public var email: String?
      public var isSelf: Bool?
      enum CodingKeys: String, CodingKey { case displayName, email; case isSelf = "self" }
    }
    public var organizer: Organizer?
    public var summary: String?
    public var start: Moment?
    public var end: Moment?
    public var status: String?
    public var htmlLink: String?
    public var hangoutLink: String?
    public var transparency: String?
    public var description: String?
    public var location: String?
    public struct Attendee: Decodable {
      var isSelf: Bool?
      var responseStatus: String?
      var displayName: String?
      var email: String?
      enum CodingKeys: String, CodingKey {
        case isSelf = "self", responseStatus, displayName, email
      }
    }
    public var attendees: [Attendee]?
    public func local() -> LocalEvent? {
      func parse(_ moment: Moment?) -> Date? {
        if let time = moment?.dateTime {
          let formatter = ISO8601DateFormatter()
          if let date = formatter.date(from: time) { return date }
          formatter.formatOptions.insert(.withFractionalSeconds)
          return formatter.date(from: time)
        }
        if let day = moment?.date {
          let formatter = DateFormatter()
          formatter.locale = Locale(identifier: "en_US_POSIX")
          formatter.dateFormat = "yyyy-MM-dd"
          return formatter.date(from: day)
        }
        return nil
      }
      guard status != "cancelled", let startDate = parse(start), let endDate = parse(end) else {
        return nil
      }
      var event = LocalEvent(title: summary ?? "Untitled event", start: startDate, end: endDate)
      event.id = "google-\(id)"
      event.googleID = id
      event.allDay = start?.date != nil
      event.webURL = htmlLink
      event.meetURL = hangoutLink
      event.details = description.map(GmailMessage.stripHTML)
      event.location = location
      event.attendees = attendees?.map {
        CalendarAttendee(name: $0.displayName, email: $0.email, response: $0.responseStatus, isSelf: $0.isSelf)
      }
      event.isOrganizer = organizer?.isSelf
      event.organizerName = organizer?.displayName
      event.organizerEmail = organizer?.email
      event.recurringEventID = recurringEventId
      event.blocksTime = transparency != "transparent"
        && attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) != true
      return event
    }
  }
  private func request(
    path: String = "", token: String, method: String = "GET", query: [URLQueryItem] = [],
    body: [String: Any]? = nil, etag: String? = nil
  ) async throws -> Data {
    var url = URLComponents(
      string: "https://www.googleapis.com/calendar/v3/calendars/primary/events\(path)")!
    if !query.isEmpty { url.queryItems = query }
    var request = URLRequest(url: url.url!)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return try await checked(request, transport: transport)
  }
  public func events(token: String, from: Date, to: Date, maxPages: Int? = nil) async throws -> [LocalEvent] {
    struct Page: Decodable {
      var items: [Event]?
      var nextPageToken: String?
    }
    var pageToken: String?
    var result: [LocalEvent] = []
    var pages = 0
    var seenTokens = Set<String>()
    repeat {
      try Task.checkCancellation()
      var query = [
        URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: from)),
        URLQueryItem(name: "timeMax", value: ISO8601DateFormatter().string(from: to)),
        URLQueryItem(name: "singleEvents", value: "true"),
        URLQueryItem(name: "showHiddenInvitations", value: "true"),
        URLQueryItem(name: "orderBy", value: "startTime"),
        URLQueryItem(name: "maxResults", value: "250"),
      ]
      if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(
        Page.self, from: await request(token: token, query: query))
      if maxPages != nil, (page.items ?? []).contains(where: {
        // A zero-length event (a reminder, a pin) can't overlap anything; only an event without times is unsafe.
        $0.status != "cancelled" && ($0.local().map { $0.end < $0.start } ?? true)
      }) {
        throw CoveError.message("Calendar returned an incomplete event. Availability could not be verified.")
      }
      result += (page.items ?? []).compactMap { $0.local() }
      pageToken = page.nextPageToken
      pages += 1
      if let pageToken {
        guard seenTokens.insert(pageToken).inserted,
          maxPages.map({ pages < $0 }) ?? true else {
          throw CoveError.message("Calendar results are incomplete. Try a shorter date range.")
        }
      }
    } while pageToken != nil
    return result
  }
  /// Google's free-text event search (titles, descriptions, locations, guests' names and addresses) over a
  /// long range, for questions like "did I meet with Manuel this year?". Newest pages first are not
  /// guaranteed, so it stops after `maxPages` and reports whether more remain.
  public func search(token: String, query: String, from: Date, to: Date, maxPages: Int = 4) async throws
    -> (events: [LocalEvent], complete: Bool) {
    struct Page: Decodable { var items: [Event]?; var nextPageToken: String? }
    var pageToken: String?
    var result: [LocalEvent] = []
    var pages = 0
    repeat {
      try Task.checkCancellation()
      var items = [
        URLQueryItem(name: "q", value: String(query.prefix(200))),
        URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: from)),
        URLQueryItem(name: "timeMax", value: ISO8601DateFormatter().string(from: to)),
        URLQueryItem(name: "singleEvents", value: "true"),
        URLQueryItem(name: "orderBy", value: "startTime"),
        URLQueryItem(name: "maxResults", value: "250"),
      ]
      if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let page = try JSONDecoder().decode(Page.self, from: await request(token: token, query: items))
      result += (page.items ?? []).compactMap { $0.local() }
      pageToken = page.nextPageToken
      pages += 1
    } while pageToken != nil && pages < maxPages
    return (result, pageToken == nil)
  }

  public func create(token: String, title: String, start: Date, end: Date) async throws
    -> LocalEvent
  {
    let body: [String: Any] = [
      "summary": title, "start": ["dateTime": ISO8601DateFormatter().string(from: start)],
      "end": ["dateTime": ISO8601DateFormatter().string(from: end)],
    ]
    let result = try JSONDecoder().decode(
      Event.self, from: await request(token: token, method: "POST", body: body))
    guard let event = result.local() else {
      throw CoveError.message(
        "The event was created, but its details could not be read. Sync your calendar before trying again."
      )
    }
    return event
  }
  public func update(token: String, event: LocalEvent, title: String, start: Date, end: Date)
    async throws -> LocalEvent
  {
    guard let id = event.googleID,
      id.rangeOfCharacter(
        from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted) == nil
    else { throw CoveError.message("Invalid calendar event ID.") }
    let body: [String: Any] = [
      "summary": title, "start": ["dateTime": ISO8601DateFormatter().string(from: start)],
      "end": ["dateTime": ISO8601DateFormatter().string(from: end)],
    ]
    let result = try JSONDecoder().decode(
      Event.self, from: await request(path: "/\(id)", token: token, method: "PATCH", body: body))
    guard let updated = result.local() else {
      throw CoveError.message("The event was updated. Sync your calendar to view its details.")
    }
    return updated
  }
  /// Fetch current self identity/ETag, then change only that participant's response.
  public func respond(token: String, id: String, response: CalendarRSVP) async throws -> LocalEvent {
    guard !id.isEmpty, id.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted) == nil else {
      throw CoveError.message("Invalid calendar event ID.")
    }
    let current = try JSONDecoder().decode(Event.self, from: await request(path: "/\(id)", token: token))
    guard current.status != "cancelled", current.organizer?.isSelf != true,
      let participant = current.attendees?.first(where: { $0.isSelf == true }),
      let email = participant.email, ContactDirectory.isValidEmail(email), let etag = current.etag else {
      throw CoveError.message("This event no longer has an invitation you can respond to. Refresh Calendar.")
    }
    if participant.responseStatus == response.rawValue, let event = current.local() { return event }
    try Task.checkCancellation()
    let data = try await request(path: "/\(id)", token: token, method: "PATCH",
      query: [URLQueryItem(name: "sendUpdates", value: "all")],
      body: ["attendeesOmitted": true, "attendees": [["email": email, "responseStatus": response.rawValue]]], etag: etag)
    let updated = try JSONDecoder().decode(Event.self, from: data)
    guard updated.id == id, updated.attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == response.rawValue }) == true,
      let event = updated.local() else {
      throw CoveError.message("Google received the response but couldn’t confirm the result. Refresh Calendar before responding again.")
    }
    return event
  }
  public func delete(token: String, id: String) async throws {
    guard
      id.rangeOfCharacter(
        from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted) == nil
    else { throw CoveError.message("Invalid calendar event ID.") }
    _ = try await request(path: "/\(id)", token: token, method: "DELETE")
  }
}
