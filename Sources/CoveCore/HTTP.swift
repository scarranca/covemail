import Foundation

public struct HTTPFailure: LocalizedError {
  public let statusCode: Int
  public let message: String
  /// The provider's machine-readable reason (for example Gmail's `rateLimitExceeded`), never its text.
  public var reason: String? = nil
  public var errorDescription: String? { message }

  /// Google reports per-user quota and concurrency limits as 403 with these reasons, or as 429.
  public var isRateLimited: Bool {
    statusCode == 429
      || (statusCode == 403 && ["rateLimitExceeded", "userRateLimitExceeded", "RESOURCE_EXHAUSTED"].contains(reason ?? ""))
  }
  public var isMissingPermission: Bool {
    statusCode == 403 && ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"].contains(reason ?? "")
  }
}

/// Reads Google's error reason: `error.errors[0].reason`, `error.details[].reason` or `error.status`.
/// Only short identifier tokens are kept, so no server-echoed text can reach messages or logs.
func providerReason(_ data: Data) -> String? {
  guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let error = root["error"] as? [String: Any]
  else { return nil }
  let candidates = [
    (error["errors"] as? [[String: Any]])?.first?["reason"] as? String,
    (error["details"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first,
    error["status"] as? String,
  ]
  return candidates.compactMap { $0 }.first {
    $0.count <= 48 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
  }
}

public protocol HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public struct LiveHTTP: HTTPTransport {
  // No mail bodies, OAuth responses, cookies or API keys in shared disk caches.
  static func privateConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return configuration
  }
  private static let sharedSession = URLSession(
    configuration: privateConfiguration(), delegate: NoRedirects(), delegateQueue: nil)
  private let session: URLSession
  public init() { session = Self.sharedSession }
  // Allows deterministic transport tests without contacting providers.
  init(configuration: URLSessionConfiguration) {
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard request.url?.scheme?.lowercased() == "https" else {
      throw CoveError.message("API connections require HTTPS.")
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw CoveError.message("Invalid server response.")
    }
    return (data, response)
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Provider endpoints are fixed. Never forward credentials or email to a redirect target.
    completionHandler(nil)
  }
}
public func checked(_ request: URLRequest, transport: HTTPTransport) async throws -> Data {
  let (data, response) = try await transport.data(for: request)
  guard (200..<300).contains(response.statusCode) else {
    // Avoid leaking server-echoed email bodies or credentials into diagnostics.
    let reason = providerReason(data)
    var failure = HTTPFailure(statusCode: response.statusCode, message: "", reason: reason)
    let host = request.url?.host ?? "Service"
    let message: String
    if failure.isRateLimited {
      message = host == "gmail.googleapis.com"
        ? "Gmail is limiting how fast Cove can read mail right now. Wait a minute and try again."
        : "\(host) is busy. Please retry in a moment."
    } else if failure.isMissingPermission {
      message = "\(host) needs access you haven’t granted. Reconnect your Google account in Settings."
    } else {
      let advice: String
      switch response.statusCode {
      case 401: advice = "Reconnect your account or check the API key."
      case 403: advice = "Check API access and granted permissions."
      default: advice = "Please try again."
      }
      message = "\(host) returned \(response.statusCode)\(reason.map { " (\($0))" } ?? ""). \(advice)"
    }
    failure = HTTPFailure(statusCode: response.statusCode, message: message, reason: reason)
    throw failure
  }
  return data
}
extension Data {
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  public init?(base64URL: String) {
    var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    self.init(base64Encoded: text)
  }
}
