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
      ("access_type", "offline"), ("prompt", "consent"), ("state", state),
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
}
