#if os(iOS)
import AuthenticationServices
import CoveCore
import Foundation
import Observation
import UIKit

/// Google sign-in on iPhone: the system web sheet (ASWebAuthenticationSession) with PKCE and Google's
/// iOS client type, which has no client secret and redirects to the reversed client ID. The refresh
/// token and identity are one Keychain value (`GoogleAccountSession`), as on the Mac.
@MainActor @Observable final class MobileAuth {
  static let sessionKey = "googleAccountSession"
  /// The iOS OAuth client ID, from the app's Info.plist (`CoveGoogleClientID`, set by the build).
  let clientID: String?
  private(set) var email: String?
  private(set) var signingIn = false
  private var session: GoogleAccountSession?
  private var access: String?
  private var expiration = Date.distantPast
  private let tokens: GoogleTokenClient
  private let anchor = SignInAnchor()

  init(clientID: String? = Bundle.main.object(forInfoDictionaryKey: "CoveGoogleClientID") as? String,
       tokens: GoogleTokenClient = GoogleTokenClient()) {
    let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.clientID = OAuthSupport.iOSRedirectScheme(clientID: trimmed) == nil ? nil : trimmed
    self.tokens = tokens
    if let saved = try? MobileKeychain.read(Self.sessionKey),
      let decoded = try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(saved.utf8))
    {
      session = decoded
      email = decoded.email
    }
  }

  var isConfigured: Bool { clientID != nil }

  func signIn() async throws {
    guard let clientID, let scheme = OAuthSupport.iOSRedirectScheme(clientID: clientID) else {
      throw CoveError.message("This build has no Google sign-in configured. See docs/IOS.md to add an iOS OAuth client.")
    }
    guard !signingIn else { return }
    signingIn = true
    defer { signingIn = false }
    let redirect = scheme + ":/oauth2redirect"
    let verifier = Self.randomURLSafe(bytes: 48)
    let state = Self.randomURLSafe(bytes: 24)
    let url = OAuthSupport.authorizationURL(
      clientID: clientID, redirect: redirect, state: state, challenge: OAuthSupport.challenge(for: verifier),
      includeCalendar: false, includeCloud: false, includeTasks: false)
    let callback = try await present(url: url, scheme: scheme)
    switch OAuthSupport.response(callbackURL: callback, expectedScheme: scheme, expectedState: state) {
    case .code(let code)?:
      let result = try await tokens.exchange(code: code, verifier: verifier, clientID: clientID, redirect: redirect)
      guard let refresh = result.refresh_token, !refresh.isEmpty else {
        throw CoveError.message("Google didn’t return offline access. Try signing in again.")
      }
      guard result.grantedScopes.contains(OAuthSupport.gmailScope) else {
        throw CoveError.message("Cove needs permission to read and organize Gmail. Sign in again and allow Gmail access.")
      }
      let verifiedEmail = try await GmailClient().profile(token: result.access_token)
      let newSession = GoogleAccountSession(email: verifiedEmail, clientID: clientID, clientSecret: "",
                                            refreshToken: refresh, calendarConnected: false)
      try MobileKeychain.save(String(decoding: try JSONEncoder().encode(newSession), as: UTF8.self),
                              name: Self.sessionKey)
      session = newSession
      access = result.access_token
      expiration = Date().addingTimeInterval(result.expires_in - 60)
      email = verifiedEmail
    case .denied?: throw CoveError.message("Google sign-in was not authorized.")
    case nil: throw CoveError.message("Google sign-in returned an unexpected response. Try again.")
    }
  }

  /// A current access token, refreshed when it has expired.
  func token() async throws -> String {
    guard let session else { throw CoveError.message("Sign in with Google to continue.") }
    if let access, expiration > Date() { return access }
    do {
      let result = try await tokens.refresh(refreshToken: session.refreshToken, clientID: session.clientID,
                                            secret: session.clientSecret)
      guard self.session == session else { throw CoveError.message("The Google connection changed. Please retry.") }
      access = result.access_token
      expiration = Date().addingTimeInterval(result.expires_in - 60)
      return result.access_token
    } catch let failure as HTTPFailure where failure.statusCode == 400 || failure.statusCode == 401 {
      // Revoked or expired sign-in: Google answers invalid_grant. Ask for a new sign-in.
      throw CoveError.message("Your Google sign-in has expired. Sign out and sign in again.")
    }
  }

  /// Removes the sign-in from this iPhone. The encrypted mail cache stays, as on the Mac.
  func signOut() throws {
    try MobileKeychain.delete(Self.sessionKey)
    session = nil
    access = nil
    expiration = .distantPast
    email = nil
  }

  private func present(url: URL, scheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let web = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
        if let callback { continuation.resume(returning: callback); return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: CoveError.message("Sign-in cancelled."))
        } else {
          continuation.resume(throwing: CoveError.message("Google sign-in couldn’t open. Try again."))
        }
      }
      web.presentationContextProvider = anchor
      // Shares the Safari sign-in, so an account already signed in to Google is offered.
      web.prefersEphemeralWebBrowserSession = false
      if !web.start() {
        continuation.resume(throwing: CoveError.message("Google sign-in couldn’t open. Try again."))
      }
    }
  }

  private static func randomURLSafe(bytes count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes).base64URL
  }
}

/// Presents the sign-in sheet over Cove's key window.
private final class SignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
      if let scene = scenes.first { return UIWindow(windowScene: scene) }
      return ASPresentationAnchor()
    }
  }
}
#endif
