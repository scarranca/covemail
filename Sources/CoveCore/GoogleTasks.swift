import Foundation

/// A Google Task. Cove only creates tasks and marks them done; it never deletes them.
public struct GoogleTask: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var notes: String?
  public var due: String?
  public var status: String?
  public var webViewLink: String?
  public init(id: String, title: String, notes: String? = nil, due: String? = nil, status: String? = nil, webViewLink: String? = nil) {
    self.id = id; self.title = title; self.notes = notes; self.due = due; self.status = status; self.webViewLink = webViewLink
  }
  public var isCompleted: Bool { status == "completed" }
  /// The due date as a local calendar day (Google stores tasks' due dates without a time).
  /// Google keeps only the date (as midnight UTC); read it as that calendar day in the local time zone.
  public var dueDay: Date? { dueDay(calendar: .current) }
  public func dueDay(calendar: Calendar) -> Date? {
    guard let due, due.count >= 10 else { return nil }
    let parts = due.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}

public struct GoogleTasksClient {
  public var transport: HTTPTransport
  public init(transport: HTTPTransport = LiveHTTP()) { self.transport = transport }


  func request(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil,
               query: [URLQueryItem] = []) async throws -> Data {
    var components = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/\(path)")!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // Same backoff as Gmail: rate-limited requests were not performed, so they are safe to retry.
    let live = transport is LiveHTTP
    var attempt = 0
    while true {
      do { return try await checked(request, transport: transport) } catch let failure as HTTPFailure {
        guard failure.isRateLimited, attempt < 4 else { throw failure }
        let seconds = live ? min(16, pow(2, Double(attempt))) + Double.random(in: 0..<1) : 0
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        attempt += 1
      }
    }
  }

  /// Creates a task in the user's default list. `due` is a local day; Google keeps only the date.
  public func create(title: String, notes: String?, due: Date?, token: String, calendar: Calendar = .current) async throws -> GoogleTask {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 300 else { throw CoveError.message("A task needs a short title.") }
    var body: [String: Any] = ["title": clean]
    if let notes, !notes.isEmpty { body["notes"] = String(notes.prefix(4_000)) }
    if let due {
      let parts = calendar.dateComponents([.year, .month, .day], from: due)
      body["due"] = String(format: "%04d-%02d-%02dT00:00:00.000Z", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
    return try JSONDecoder().decode(GoogleTask.self,
      from: await request("lists/@default/tasks", token: token, method: "POST", body: body))
  }

  /// Open tasks first, from the default list (up to 100).
  public func list(token: String, includeCompleted: Bool = false) async throws -> [GoogleTask] {
    struct Page: Decodable { let items: [GoogleTask]? }
    let data = try await request("lists/@default/tasks", token: token, query: [
      URLQueryItem(name: "maxResults", value: "100"),
      URLQueryItem(name: "showCompleted", value: includeCompleted ? "true" : "false"),
      URLQueryItem(name: "showHidden", value: "false"),
    ])
    return try JSONDecoder().decode(Page.self, from: data).items ?? []
  }

  public func setCompleted(_ task: GoogleTask, completed: Bool, token: String) async throws -> GoogleTask {
    guard task.id.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted) == nil else {
      throw CoveError.message("Invalid task ID.")
    }
    let body: [String: Any] = completed ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
    return try JSONDecoder().decode(GoogleTask.self,
      from: await request("lists/@default/tasks/\(task.id)", token: token, method: "PATCH", body: body))
  }
}
