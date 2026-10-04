import CryptoKit
import Foundation

public enum OAuthResponse: Equatable {
  case code(String)
  case denied
}
public enum OAuthSupport {
  public static func challenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
  }
  public static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
  public static let calendarScope = "https://www.googleapis.com/auth/calendar.events"
  public static let tasksScope = "https://www.googleapis.com/auth/tasks"

  /// Google authorization request. `loginHint` preselects the connected account; with it, previously
  /// granted scopes are kept so adding Calendar never drops Gmail access.
  public static func authorizationURL(
    clientID: String, redirect: String, state: String, challenge: String,
    includeCalendar: Bool, includeCloud: Bool, includeTasks: Bool = false, loginHint: String? = nil
  ) -> URL {
    var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    var items: [(String, String)] = [
      ("client_id", clientID), ("redirect_uri", redirect), ("response_type", "code"),
      ("scope", gmailScope + (includeCalendar ? " " + calendarScope : "") + (includeTasks ? " " + tasksScope : "")
        + (includeCloud ? " openid email" : "")),
      // Without a hint (first sign-in, Add account) Google shows its account chooser, so a browser
      // already signed in to one account doesn't silently pick it.
      ("access_type", "offline"), ("prompt", loginHint?.isEmpty == false ? "consent" : "select_account consent"), ("state", state),
      ("code_challenge", challenge), ("code_challenge_method", "S256"),
    ]
    if let loginHint, !loginHint.isEmpty {
      items += [("login_hint", loginHint), ("include_granted_scopes", "true")]
    }
    url.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
    return url.url!
  }

  /// Invalid callbacks do not terminate the pending sign-in session.
  public static func response(request: String, expectedState: String) -> OAuthResponse? {
    guard !expectedState.isEmpty, let firstLine = request.components(separatedBy: "\r\n").first
    else { return nil }
    let parts = firstLine.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
      let url = URLComponents(string: "http://localhost\(parts[1])"), url.path == "/oauth/callback"
    else { return nil }
    let items = url.queryItems ?? []
    guard items.filter({ $0.name == "state" }).count == 1,
      items.first(where: { $0.name == "state" })?.value == expectedState
    else { return nil }
    if items.contains(where: { $0.name == "error" }) { return .denied }
    guard items.filter({ $0.name == "code" }).count == 1,
      let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
    else { return nil }
    return .code(code)
  }

  /// The result of an app-scheme redirect (iOS sign-in), e.g. `com.googleusercontent.apps.ID:/oauth2redirect?code=…`.
  /// Like `response(request:expectedState:)`, anything unexpected is ignored rather than trusted.
  public static func response(callbackURL: URL, expectedScheme: String, expectedState: String) -> OAuthResponse? {
    guard !expectedState.isEmpty, callbackURL.scheme?.lowercased() == expectedScheme.lowercased(),
      let url = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    else { return nil }
    let items = url.queryItems ?? []
    guard items.filter({ $0.name == "state" }).count == 1,
      items.first(where: { $0.name == "state" })?.value == expectedState
    else { return nil }
    if items.contains(where: { $0.name == "error" }) { return .denied }
    guard items.filter({ $0.name == "code" }).count == 1,
      let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
    else { return nil }
    return .code(code)
  }

  /// The redirect scheme Google assigns an iOS client: its client ID with the domain parts reversed.
  public static func iOSRedirectScheme(clientID: String) -> String? {
    let suffix = ".apps.googleusercontent.com"
    guard clientID.hasSuffix(suffix), clientID.count > suffix.count,
      clientID.range(of: #"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    else { return nil }
    return "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
  }
}

/// Google's OAuth token endpoint, shared by sign-in (code exchange) and every later access-token refresh.
public struct GoogleTokenClient {
  public struct Tokens: Decodable, Equatable, Sendable {
    public var access_token: String
    public var refresh_token: String?
    public var expires_in: Double
    public var scope: String?
    public var id_token: String?
    public var grantedScopes: Set<String> { Set((scope ?? "").split(separator: " ").map(String.init)) }
  }
  private let transport: HTTPTransport
  public init(transport: HTTPTransport = LiveHTTP()) { self.transport = transport }

  public func exchange(code: String, verifier: String, clientID: String, redirect: String, secret: String = "") async throws -> Tokens {
    try await post(["code": code, "code_verifier": verifier, "client_id": clientID,
                    "redirect_uri": redirect, "grant_type": "authorization_code"], secret: secret)
  }
  public func refresh(refreshToken: String, clientID: String, secret: String = "") async throws -> Tokens {
    try await post(["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"], secret: secret)
  }
  private func post(_ values: [String: String], secret: String) async throws -> Tokens {
    var values = values
    // Installed-app clients (iOS) have no secret; Desktop clients send their public one.
    if !secret.isEmpty { values["client_secret"] = secret }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let form = values.sorted { $0.key < $1.key }.map {
      "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.httpBody = Data(form.utf8)
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    return try JSONDecoder().decode(Tokens.self, from: await checked(request, transport: transport))
  }
}
