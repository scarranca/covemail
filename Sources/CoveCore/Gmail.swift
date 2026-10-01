import CoreFoundation
import Foundation

public struct GmailMessage: Decodable {
  public struct Header: Decodable {
    public var name: String
    public var value: String
  }
  public struct Body: Decodable {
    public var data: String?
    public var attachmentId: String?
    public var size: Int?
  }
  public struct Part: Decodable {
    public var mimeType: String?
    public var filename: String?
    public var headers: [Header]?
    public var body: Body?
    public var parts: [Part]?
    private var contentID: String? {
      guard
        var value = headers?.first(where: {
          $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines)
      else { return nil }
      if value.hasPrefix("<"), value.hasSuffix(">") {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return value.isEmpty ? nil : value
    }
    private var isAttachment: Bool {
      let name = (filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let disposition = headers?.first {
        $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame
      }?.value.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return !name.isEmpty || disposition == "attachment"
    }
    func attachments(path: String = "0") -> [MailAttachment] {
      let name = (filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      var result: [MailAttachment] = []
      let inlineImage = (mimeType ?? "").lowercased().hasPrefix("image/") && contentID != nil
      if isAttachment || inlineImage {
        result.append(
          MailAttachment(
            id: "part-\(path)",
            filename: name.isEmpty ? (inlineImage ? "Inline image" : "Attachment") : name,
            mimeType: mimeType ?? "application/octet-stream", byteCount: body?.size,
            attachmentID: body?.attachmentId, data: body?.data, contentID: contentID))
      }
      for (index, child) in (parts ?? []).enumerated() {
        result += child.attachments(path: "\(path).\(index)")
      }
      return result
    }
    func text(mime: String, snippet: String? = nil) -> String? {
      // An attached HTML/text document (or an attached MIME subtree) is not the email body.
      guard !isAttachment else { return nil }
      if mimeType == mime, let encoded = body?.data, let data = Data(base64URL: encoded) {
        return decodedText(data, snippet: snippet)
      }
      return parts?.compactMap { $0.text(mime: mime, snippet: snippet) }.first
    }
    private func decodedText(_ data: Data, snippet: String?) -> String {
      let contentType =
        headers?.first {
          $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? ""
      let pattern = #"(?i)(?:^|;)\s*charset\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))"#
      if let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
          in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
        let range = (1...3).compactMap({ Range(match.range(at: $0), in: contentType) }).first
      {
        let charset = String(contentType[range]).trimmingCharacters(in: .whitespaces)
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if encoding != kCFStringEncodingInvalidId,
          let value = String(
            data: data,
            encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
          )
        {
          let resolvedEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
          if resolvedEncoding == .isoLatin1 || resolvedEncoding == .windowsCP1252,
            let utf8 = String(data: data, encoding: .utf8), utf8 != value,
            snippetCorroborates(utf8: utf8, declared: value, snippet: snippet)
          {
            return utf8
          }
          return value
        }
      }
      // Unknown or malformed charset: preserve the entire body, replacing undecodable
      // bytes rather than silently substituting Gmail's truncated snippet.
      return String(decoding: data, as: UTF8.self)
    }
    private func snippetCorroborates(utf8: String, declared: String, snippet: String?) -> Bool {
      guard let snippet else { return false }
      func normalize(_ text: String) -> String {
        GmailMessage.decodeEntities(text).precomposedStringWithCanonicalMapping
          .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      }
      let reference = normalize(snippet)
      // Some MIME bodies contain UTF-8 bytes despite a legacy charset header.
      // A valid UTF-8 sequence alone is ambiguous: genuine legacy text may spell
      // "Ã©" intentionally. Override only with independent, non-ASCII text evidence.
      guard reference.count >= 12,
        reference.unicodeScalars.contains(where: {
          $0.value > 127 && CharacterSet.letters.contains($0)
        })
      else { return false }
      let utf8Text = normalize(mimeType == "text/html" ? GmailMessage.stripHTML(utf8) : utf8)
      let declaredText = normalize(
        mimeType == "text/html" ? GmailMessage.stripHTML(declared) : declared)
      return utf8Text.contains(reference) && !declaredText.contains(reference)
    }
  }
  public var id: String
  public var threadId: String
  public var labelIds: [String]?
  public var snippet: String?
  public var internalDate: String?
  public var payload: Part?
  public func mail() -> Mail {
    func header(_ name: String) -> String {
      payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value ?? ""
    }
    let from = header("From")
    let address: String
    let name: String
    if let start = from.firstIndex(of: "<"), let end = from.lastIndex(of: ">"), start < end {
      address = String(from[from.index(after: start)..<end])
      name = String(from[..<start]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    } else {
      address = from
      name = from
    }
    let plain = payload?.text(mime: "text/plain", snippet: snippet)
    let html = payload?.text(mime: "text/html", snippet: snippet)
    let fallback = html.map(Self.stripHTML)
    let readable: String?
    if let plain, let html, let fallback, !fallback.isEmpty,
      Self.corroboratedHTMLText(plain, html: html) != nil
    {
      readable = fallback
    } else {
      readable = plain
    }
    var mail = Mail(
      id: id, threadID: threadId, sender: name.isEmpty ? address : name, senderEmail: address,
      to: header("To"), subject: header("Subject").isEmpty ? "(No subject)" : header("Subject"),
      body: readable ?? fallback ?? Self.decodeEntities(snippet ?? ""),
      date: Date(timeIntervalSince1970: (Double(internalDate ?? "") ?? 0) / 1000),
      labels: Set(labelIds ?? []), messageID: header("Message-ID"),
      replyTo: header("Reply-To").isEmpty ? nil : header("Reply-To"),
      attachments: payload?.attachments(), htmlBody: html,
      isBulkOrAutomated: KeepInTouch.hasBulkOrAutomatedHeaders(
        listID: header("List-ID"), listUnsubscribe: header("List-Unsubscribe"),
        autoSubmitted: header("Auto-Submitted"), precedence: header("Precedence")),
      cc: header("Cc"))
    mail.unsubscribe = MailUnsubscribe.parse(header: header("List-Unsubscribe"), post: header("List-Unsubscribe-Post"))
    return mail
  }
  /// A few senders leak presentation markup into text/plain. Only recognize paired,
  /// attributed HTML fragments that also occur literally in the HTML alternative.
  /// Escaped code samples and ordinary angle-bracket comparisons are not evidence.
  static func corroboratedHTMLText(_ plain: String, html: String) -> String? {
    let pattern =
      #"(?is)<(span|div|p|td|th|table|tr|a|font|strong|em|b|i)\b[^>]*(?:\bstyle\s*=|\bdata-[\w-]+\s*=)[^>]*>.*?</\1\s*>"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let matches = expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
    var repaired = plain
    var changed = false
    for match in matches.reversed() {
      guard let range = Range(match.range, in: plain) else { continue }
      let fragment = String(plain[range])
      guard html.range(of: fragment, options: .literal) != nil else { continue }
      let readable = stripHTML(fragment)
      guard readable.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }),
        let replacementRange = Range(match.range, in: repaired)
      else { continue }
      repaired.replaceSubrange(replacementRange, with: readable)
      changed = true
    }
    return changed ? repaired : nil
  }
  static func decodeEntities(_ text: String) -> String {
    var value = text
    for (key, replacement) in [
      "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&",
    ] { value = value.replacingOccurrences(of: key, with: replacement) }
    return value
  }
  static func stripHTML(_ html: String) -> String {
    let cleaned = html.replacingOccurrences(
      of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression
    )
    .replacingOccurrences(
      of: "(?i)<br\\s*/?>|</(?:p|div|tr|h[1-6])>", with: "\n", options: .regularExpression
    )
    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    return decodeEntities(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
public struct GmailClient {
  public var transport: HTTPTransport
  public init(transport: HTTPTransport = LiveHTTP()) { self.transport = transport }
  public func request(
    _ path: String, token: String, method: String = "GET", body: [String: Any]? = nil,
    query: [URLQueryItem] = []
  ) async throws -> Data {
    var components = URLComponents(
      string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // Back off when Gmail says to slow down. Rate-limited requests were not performed, so retrying
    // them is safe for any method; server errors are retried only for reads, so a send or label
    // change can never be applied twice. Bulk fetches are also paced (`pacedBulk`).
    let live = transport is LiveHTTP
    let cost = Self.quotaCost(path: path, method: method)
    var attempt = 0
    while true {
      if live { await GmailPacer.shared.spend(cost) }
      do { return try await checked(request, transport: transport) } catch let failure as HTTPFailure {
        let retryable = failure.isRateLimited || (method == "GET" && [500, 502, 503, 504].contains(failure.statusCode))
        guard retryable, attempt < 5 else { throw failure }
        let seconds = live ? min(32, pow(2, Double(attempt))) + Double.random(in: 0..<1) : 0
        if live, failure.isRateLimited { await GmailPacer.shared.slowDown(for: seconds) }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        attempt += 1
      }
    }
  }
  public func profile(token: String) async throws -> String {
    struct Profile: Decodable { var emailAddress: String }
    return try JSONDecoder().decode(Profile.self, from: await request("profile", token: token))
      .emailAddress
  }
  public struct Page {
    public var messages: [Mail]
    public var next: String?
    /// Current Gmail labels for listed messages already stored locally; their content is not refetched.
    public var labels: [String: Set<String>] = [:]
    /// Stored messages Gmail confirmed no longer exist.
    public var deletedIDs: Set<String> = []
  }
  /// Lists one page. IDs in `cachedIDs` are already stored on this Mac, so only their labels are fetched.
  public func page(
    token: String, pageToken: String? = nil, labelID: String? = nil,
    cachedIDs: Set<String> = []
  ) async throws -> Page {
    struct Entry: Decodable { var id: String }
    struct List: Decodable {
      var messages: [Entry]?
      var nextPageToken: String?
    }
    // Spam is only listed when that folder is open; every other view leaves it out.
    let spam = labelID == "SPAM"
    var query = [
      URLQueryItem(name: "maxResults", value: "50"),
      URLQueryItem(name: "q", value: spam ? "in:spam" : "-in:trash -in:spam"),
    ]
    if spam { query.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
    if let labelID { query.append(URLQueryItem(name: "labelIds", value: labelID)) }
    if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    let list = try JSONDecoder().decode(
      List.self, from: await request("messages", token: token, query: query))
    var result = Page(messages: [], next: list.nextPageToken)
    // Small bounded groups avoid both serial latency and Gmail quota bursts.
    let entries = list.messages ?? []
    for start in stride(from: 0, to: entries.count, by: 5) {
      let batch = Array(entries[start..<min(start + 5, entries.count)])
      let updates = try await withThrowingTaskGroup(of: MessageUpdate?.self) { group in
        for entry in batch {
          group.addTask {
            try await pacedBulk()
            if cachedIDs.contains(entry.id) {
              return try await update(id: entry.id, token: token, cached: true)
            }
            // A message removed between listing and fetching is skipped, not treated as deleted.
            return try await message(id: entry.id, token: token).map(MessageUpdate.full)
          }
        }
        var values: [MessageUpdate] = []
        for try await update in group { if let update { values.append(update) } }
        return values
      }
      for update in updates {
        switch update {
        case .full(let mail): result.messages.append(mail)
        case .labels(let id, let labels): result.labels[id] = labels
        case .deleted(let id): result.deletedIDs.insert(id)
        }
      }
    }
    result.messages.sort { $0.date > $1.date }
    return result
  }
  public func modify(id: String, token: String, add: [String] = [], remove: [String] = [])
    async throws
  {
    _ = try await request(
      "messages/\(id)/modify", token: token, method: "POST",
      body: ["addLabelIds": add, "removeLabelIds": remove])
  }
  /// One label change among many (an approved assistant bulk change), paced like bulk reads.
  public func modifyPaced(id: String, token: String, add: [String] = [], remove: [String] = []) async throws {
    try await pacedBulk(cost: 5)
    try await modify(id: id, token: token, add: add, remove: remove)
  }
  /// One label change for up to 1,000 emails in a single request (Gmail's messages.batchModify).
  /// Gmail applies it to every id or reports an error for the whole call.
  public func batchModify(ids: [String], token: String, add: [String] = [], remove: [String] = []) async throws {
    guard !ids.isEmpty else { return }
    precondition(ids.count <= 1_000, "Gmail batchModify accepts at most 1,000 ids")
    _ = try await request(
      "messages/batchModify", token: token, method: "POST",
      body: ["ids": ids, "addLabelIds": add, "removeLabelIds": remove])
  }
  public func trash(id: String, token: String) async throws {
    _ = try await request("messages/\(id)/trash", token: token, method: "POST")
  }
  public static func rawMessage(
    from: String, to: String, subject: String, body: String, replyMessageID: String? = nil,
    date: Date = Date(), cc: String = ""
  ) throws -> String {
    guard from.rangeOfCharacter(from: .newlines) == nil,
      !from.trimmingCharacters(in: .whitespaces).isEmpty, from.contains("@")
    else {
      throw CoveError.message("The connected account has no valid sender address. Reconnect Gmail.")
    }
    guard to.rangeOfCharacter(from: .newlines) == nil,
      subject.rangeOfCharacter(from: .newlines) == nil,
      !to.trimmingCharacters(in: .whitespaces).isEmpty, to.contains("@")
    else { throw CoveError.message("Enter a valid recipient and a single-line subject.") }
    let cc = cc.trimmingCharacters(in: .whitespaces)
    guard cc.rangeOfCharacter(from: .newlines) == nil, cc.isEmpty || cc.contains("@") else {
      throw CoveError.message("Enter valid Cc recipients.")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    var headers = [
      "From: \(from)", "Date: \(formatter.string(from: date))",
      "To: \(to)",
    ] + (cc.isEmpty ? [] : ["Cc: \(cc)"]) + [
      "Subject: \(encodedSubject(subject))",
      "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: base64",
    ]
    if let id = replyMessageID, !id.isEmpty {
      guard id.rangeOfCharacter(from: .newlines) == nil else {
        throw CoveError.message("Invalid reply header.")
      }
      headers += ["In-Reply-To: \(id)", "References: \(id)"]
    }
    let encodedBody = Data(body.utf8).base64EncodedString(options: [
      .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
    ])
    return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody).utf8).base64URL
  }

  private static func encodedSubject(_ subject: String) -> String {
    // RFC 2047 limits encoded words to 75 characters and their header lines to 76.
    // 39 UTF-8 bytes produce at most 64 encoded characters, leaving room for Subject:.
    // Split at scalar boundaries so even large combining sequences decode losslessly.
    var words: [String] = []
    var chunk = Data()
    for scalar in subject.unicodeScalars {
      let bytes = Data(String(scalar).utf8)
      if chunk.count + bytes.count > 39 {
        words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
        chunk = Data()
      }
      chunk.append(bytes)
    }
    if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
    return words.joined(separator: "\r\n ")
  }
  public func send(
    token: String, from: String, to: String, subject: String, body: String, reply: Mail? = nil,
    cc: String = ""
  )
    async throws -> String
  {
    var payload: [String: Any] = [
      "raw": try Self.rawMessage(
        from: from, to: to, subject: subject, body: body, replyMessageID: reply?.messageID, cc: cc)
    ]
    if let reply, !reply.threadID.isEmpty { payload["threadId"] = reply.threadID }
    struct Sent: Decodable { var id: String }
    return try JSONDecoder().decode(
      Sent.self, from: await request("messages/send", token: token, method: "POST", body: payload)
    ).id
  }
}

extension GmailClient {
  /// Waits until Gmail's per-user budget has room for one background read (20 units) without eating into
  /// the reserve kept for what the user does. Interactive requests never wait here.
  func pacedBulk(cost: Double = 20) async throws {
    if transport is LiveHTTP { try await GmailPacer.shared.waitForBulk(cost: cost) }
  }

  /// Google's published cost of one call, in quota units (Gmail API usage limits).
  static func quotaCost(path: String, method: String) -> Double {
    let parts = path.split(separator: "/").map(String.init)
    switch (parts.first ?? "", parts.count, method) {
    case ("profile", _, _): return 1
    case ("history", _, _): return 2
    case ("labels", 1, "GET"), ("labels", 2, "GET"): return 1
    case ("labels", _, _): return 5
    case ("settings", _, "GET"): return 1
    case ("messages", 1, _): return 5                       // list
    case ("messages", 2, _) where parts[1] == "send": return 100
    case ("messages", 2, _) where parts[1] == "batchModify": return 50
    case ("messages", 2, "DELETE"): return 10
    case ("messages", 2, _): return 20                      // get
    case ("messages", _, _) where parts.last == "modify": return 5
    case ("messages", _, _) where parts.last == "untrash": return 5
    case ("messages", _, _): return 20                      // trash, attachments
    case ("threads", 1, _): return 10
    case ("threads", 2, "GET"): return 40
    case ("threads", _, _): return 10
    case ("drafts", 1, "GET"): return 5
    case ("drafts", _, "POST"): return parts.last == "send" ? 100 : 10
    case ("drafts", _, _): return 15
    default: return 5
    }
  }
}

/// Gmail allows each user 6,000 quota units per minute (a message read costs 20), so a sustained
/// catch-up can read about five emails a second. Cove spends that budget like Superhuman: background
/// work only uses what is left above a reserve for things the user does, goes about ten times more
/// gently on battery, and everything pauses after Gmail says to slow down.
actor GmailPacer {
  static let shared = GmailPacer()
  static let unitsPerMinute = 6_000.0
  /// Kept free for interactive requests (opening, sending, archiving) during a catch-up.
  static let reserve = 1_500.0
  private var available = GmailPacer.unitsPerMinute
  private var updated = Date()
  private var pausedUntil = Date.distantPast
  private var nextBulk = Date.distantPast
  /// Minimum spacing between background reads: plugged in vs on battery (or Low Power Mode).
  private let spacing: @Sendable () -> TimeInterval

  private let reserved: Double

  init(spacing: @escaping @Sendable () -> TimeInterval = { PowerState.onBattery ? 0.6 : 0.06 },
       reserve: Double = GmailPacer.reserve) {
    self.spacing = spacing
    self.reserved = reserve
  }

  private func refill() {
    let now = Date()
    available = min(Self.unitsPerMinute, available + now.timeIntervalSince(updated) * Self.unitsPerMinute / 60)
    updated = now
  }
  /// Every request records what it costs, interactive or not.
  func spend(_ units: Double) {
    refill()
    available -= units
  }
  func waitForBulk(cost: Double) async throws {
    while true {
      try Task.checkCancellation()
      refill()
      let now = Date()
      let ready = max(pausedUntil, nextBulk)
      if ready > now {
        try await Task.sleep(nanoseconds: UInt64(ready.timeIntervalSince(now) * 1_000_000_000))
        continue
      }
      let shortfall = reserved + cost - available
      if shortfall <= 0 {
        nextBulk = now.addingTimeInterval(spacing())
        return
      }
      try await Task.sleep(nanoseconds: UInt64(shortfall / (Self.unitsPerMinute / 60) * 1_000_000_000))
    }
  }
  func slowDown(for seconds: TimeInterval) {
    refill()
    pausedUntil = max(pausedUntil, Date().addingTimeInterval(seconds))
    available = min(available, 0)
  }
  /// For tests: the budget left right now.
  func remaining() -> Double { refill(); return available }
}
