import Foundation

/// How a mailing list says to leave it (RFC 2369 `List-Unsubscribe`, RFC 8058 one-click).
public struct MailUnsubscribe: Codable, Equatable, Sendable {
  public enum Kind: Sendable { case oneClick, email, web }
  /// HTTPS address that accepts a one-click POST: nothing opens, the sender must stop.
  public var oneClick: URL?
  /// HTTPS page to open in the browser when one-click isn't offered.
  public var web: URL?
  public var mailto: String?
  public var mailSubject: String = "unsubscribe"
  public var mailBody: String = ""
  public var kind: Kind { oneClick != nil ? .oneClick : mailto != nil ? .email : .web }

  public init(oneClick: URL? = nil, web: URL? = nil, mailto: String? = nil, mailSubject: String = "unsubscribe", mailBody: String = "") {
    self.oneClick = oneClick; self.web = web; self.mailto = mailto; self.mailSubject = mailSubject; self.mailBody = mailBody
  }

  /// Reads the `<…>` entries. Only HTTPS links and plain mailto addresses count; anything else is ignored.
  public static func parse(header: String, post: String = "") -> MailUnsubscribe? {
    guard !header.isEmpty else { return nil }
    var result = MailUnsubscribe()
    var https: URL?
    var scanner = header[...]
    while let open = scanner.firstIndex(of: "<"), let close = scanner[open...].firstIndex(of: ">") {
      let entry = scanner[scanner.index(after: open)..<close].filter { !$0.isWhitespace }
      scanner = scanner[scanner.index(after: close)...]
      let lower = entry.lowercased()
      if lower.hasPrefix("https://"), https == nil, let url = URL(string: String(entry)), url.host?.isEmpty == false {
        https = url
      } else if lower.hasPrefix("mailto:"), result.mailto == nil,
                let components = URLComponents(string: String(entry)) {
        let address = components.path.removingPercentEncoding ?? components.path
        guard address.contains("@"), !address.contains(","), address.count <= 254 else { continue }
        result.mailto = address
        for item in components.queryItems ?? [] {
          switch item.name.lowercased() {
          case "subject": result.mailSubject = String((item.value ?? "unsubscribe").prefix(200))
          case "body": result.mailBody = String((item.value ?? "").prefix(1_000))
          default: break
          }
        }
      }
    }
    let oneClick = post.replacingOccurrences(of: " ", with: "").lowercased().contains("list-unsubscribe=one-click")
    if let https { if oneClick { result.oneClick = https } else { result.web = https } }
    return result.oneClick == nil && result.web == nil && result.mailto == nil ? nil : result
  }
}

/// Sends the RFC 8058 one-click request: a bare POST with no cookies, credentials or email content.
public struct UnsubscribeClient {
  public var transport: HTTPTransport
  public init(transport: HTTPTransport = LiveHTTP()) { self.transport = transport }
  public func oneClick(_ url: URL) async throws {
    guard url.scheme?.lowercased() == "https" else { throw CoveError.message("This sender’s unsubscribe link isn’t secure.") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
    let (_, response) = try await transport.data(for: request)
    // Some senders answer with a redirect to a thank-you page; it is not followed.
    guard (200..<400).contains(response.statusCode) else {
      throw CoveError.message("The sender didn’t accept the request (\(response.statusCode)). Try their unsubscribe page instead.")
    }
  }
}
