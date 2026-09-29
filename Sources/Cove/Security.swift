import AppKit
import CoveCore
import CryptoKit
import Foundation
import Network
import Security

enum LegacyNetworkCache {
  static func remove() throws {
    guard let bundleID = Bundle.main.bundleIdentifier,
      bundleID == "ai.cove.mac" || bundleID.hasPrefix("ai.cove.")
    else { return }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    // Old URLSession.shared responses may contain mail. New transport is ephemeral.
    // These are regenerable networking caches, not the mailbox database or downloaded files.
    for parent in ["Caches", "HTTPStorages"] {
      let path = library.appendingPathComponent(parent).appendingPathComponent(bundleID)
      guard FileManager.default.fileExists(atPath: path.path) else { continue }
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw CoveError.message("Could not safely clear old network caches.")
      }
      try FileManager.default.removeItem(at: path)
    }
  }
}

enum Vault {
  static func mailboxKey(accountID: String, existingEncryptedStore: Bool) throws -> Data {
    let name = "mailboxEncryptionKey." + accountID
    return try MailboxEncryptionKey.load(
      existingEncryptedStore: existingEncryptedStore,
      read: { try read(name) }, write: { try insertMailboxKey($0, name: name) })
  }

  private static func insertMailboxKey(_ value: String, name: String) throws {
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: name,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: Data(value.utf8),
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw CoveError.message("Keychain could not save the mailbox key (\(status)).")
    }
  }

  private static var service: String {
    CoveRuntime.isQA ? "ai.cove.qa" : "ai.cove.mac"
  }
  static func read(_ name: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: name, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw CoveError.message("Keychain could not be read (\(status)).")
    }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ value: String, name: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item.merge(attributes) { _, new in new }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw CoveError.message("Keychain could not save credentials (\(status)).")
    }
  }
  static func delete(_ name: String) throws {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: name,
      ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CoveError.message("Keychain could not remove credentials (\(status)).")
    }
  }
}

@MainActor final class GoogleAuth {
  private var listener: NWListener?
  private var callback: CheckedContinuation<String, Error>?
  private var ready: CheckedContinuation<UInt16, Error>?
  private var timeout: Task<Void, Never>?
  private var access: String?
  private var identityToken: String?
  private var expiration = Date.distantPast
  private var expectedState = ""
  private var sessions: GoogleSessionStore?
  private var connectionGeneration = UUID()
  private var browserReply: OAuthBrowserReply?
  struct PendingConnection {
    let session: GoogleAccountSession
    let accessToken: String
    let expiration: Date
    var identityToken: String? = nil
  }
  private func sessionStore() throws -> GoogleSessionStore {
    if let sessions { return sessions }
    let loaded = try GoogleSessionStore(
      read: { try Vault.read("googleAccountSession") },
      write: { value in
        if let value {
          try Vault.save(value, name: "googleAccountSession")
        } else {
          try Vault.delete("googleAccountSession")
        }
      })
    sessions = loaded
    return loaded
  }
  var clientID: String {
    GoogleOAuthConfiguration.selected(
      customClientID: UserDefaults.standard.string(forKey: "googleClientID"), customSecret: nil,
      bundled: BundledGoogleOAuth.configuration
    ).clientID
  }
  private func clientSecret() throws -> String {
    let customID = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
    let customSecret =
      customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil : try Vault.read("googleClientSecret")
    return GoogleOAuthConfiguration.selected(
      customClientID: customID, customSecret: customSecret,
      bundled: BundledGoogleOAuth.configuration
    ).clientSecret
  }
  var isConnected: Bool { UserDefaults.standard.string(forKey: "accountEmail") != nil }
  func restorableAccountEmail() throws -> String? {
    guard let email = UserDefaults.standard.string(forKey: "accountEmail"), !email.isEmpty else {
      return nil
    }
    if let session = try sessionStore().current {
      try session.requireMailbox(email)
      guard !session.refreshToken.isEmpty, !session.clientID.isEmpty else { return nil }
      return email
    }
    // A cached mailbox name alone does not mean the user is signed in.
    guard clientID.hasSuffix(".apps.googleusercontent.com"),
      let refresh = try Vault.read("googleRefreshToken"), !refresh.isEmpty
    else { return nil }
    return email
  }
  private func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CoveError.message("Could not create secure sign-in session.")
    }
    return Data(bytes).base64URL
  }
  func connect(includeCalendar: Bool = false, includeCloud: Bool = false, loginHint: String? = nil) async throws -> PendingConnection {
    finishBrowserSignIn(success: false)
    guard GoogleOAuthConfiguration(clientID: clientID).isConfigured else {
      throw CoveError.message("Add a Google Desktop OAuth client ID in Connections first.")
    }
    let generation = UUID()
    connectionGeneration = generation
    let connectingClientID = clientID
    let connectingSecret = try clientSecret()
    let verifier = try random()
    expectedState = try random()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    listener = server
    server.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.receive(connection) }
    }
    timeout = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(180))
        self?.finish(.failure(CoveError.message("Sign-in timed out. Please try again.")))
      } catch {}
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      ready = continuation
      server.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready:
            if let port = server.port {
              self.ready?.resume(returning: port.rawValue)
              self.ready = nil
            }
          case .failed(let error):
            self.ready?.resume(throwing: error)
            self.ready = nil
            self.finish(.failure(error))
          default: break
          }
        }
      }
      server.start(queue: .main)
    }
    let redirect = "http://127.0.0.1:\(port)/oauth/callback"
    let url = OAuthSupport.authorizationURL(
      clientID: connectingClientID, redirect: redirect, state: expectedState,
      challenge: OAuthSupport.challenge(for: verifier), includeCalendar: includeCalendar,
      includeCloud: includeCloud, loginHint: loginHint)
    let code: String = try await withCheckedThrowingContinuation { continuation in
      callback = continuation
      if !NSWorkspace.shared.open(url) {
        finish(.failure(CoveError.message("Could not open your browser.")))
      }
    }
    let result = try await exchange(
      [
        "client_id": connectingClientID, "code": code, "code_verifier": verifier,
        "redirect_uri": redirect,
        "grant_type": "authorization_code",
      ], secret: connectingSecret)
    guard let refresh = result.refresh_token else {
      throw CoveError.message(
        "Google did not grant offline access. Please reconnect and allow access.")
    }
    let email = try await GmailClient().profile(token: result.access_token)
    guard generation == connectionGeneration else {
      throw CoveError.message("Sign-in cancelled.")
    }
    return PendingConnection(
      session: GoogleAccountSession(
        email: email, clientID: connectingClientID, clientSecret: connectingSecret,
        refreshToken: refresh,
        calendarConnected: includeCalendar
          && (result.scope?.contains(OAuthSupport.calendarScope) ?? true)),
      accessToken: result.access_token,
      expiration: Date().addingTimeInterval(result.expires_in - 60), identityToken: result.id_token)
  }
  func commit(_ pending: PendingConnection) throws {
    try sessionStore().commit(pending.session)
    connectionGeneration = UUID()
    access = pending.accessToken
    identityToken = pending.identityToken
    expiration = pending.expiration
    UserDefaults.standard.set(pending.session.email, forKey: "accountEmail")
    UserDefaults.standard.set(pending.session.calendarConnected, forKey: "calendarConnected")
    // Old versions stored only a refresh token; it must never be reused after a successful switch.
    try? Vault.delete("googleRefreshToken")
  }
  /// Called after the full account/mailbox transaction, including local persistence.
  func finishBrowserSignIn(success: Bool) {
    browserReply?.finish(success ? .connected : .failed)
    browserReply = nil
  }
  private func receive(_ connection: NWConnection) {
    connection.start(queue: .main)
    let deadline = Task {
      do {
        try await Task.sleep(for: .seconds(10))
        connection.cancel()
      } catch {}
    }
    readRequest(connection, buffer: Data(), deadline: deadline)
  }
  private func readRequest(_ connection: NWConnection, buffer: Data, deadline: Task<Void, Never>) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384 - buffer.count) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, error == nil, let data, !data.isEmpty else {
          connection.cancel()
          return
        }
        let bytes = buffer + data
        guard bytes.count <= 16384 else {
          connection.cancel()
          return
        }
        guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
          if !complete, bytes.count < 16384 {
            self.readRequest(connection, buffer: bytes, deadline: deadline)
          } else {
            connection.cancel()
          }
          return
        }
        deadline.cancel()
        let parsed = self.callback == nil ? nil : OAuthSupport.response(
          request: String(decoding: bytes, as: UTF8.self), expectedState: self.expectedState)
        let reply = OAuthBrowserReply { response in
          connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
        switch parsed {
        case .code(let code):
          self.browserReply = reply
          self.finish(.success(code))
        case .denied:
          reply.finish(.denied)
          self.finish(.failure(CoveError.message("Google sign-in was not authorized.")))
        case nil: reply.finish(.invalid)
        }
      }
    }
  }
  private func finish(_ result: Result<String, Error>) {
    if case .failure(let error) = result {
      finishBrowserSignIn(success: false)
      ready?.resume(throwing: error)
      ready = nil
    }
    callback?.resume(with: result)
    callback = nil
    timeout?.cancel()
    timeout = nil
    listener?.cancel()
    listener = nil
  }
  func cancel() {
    connectionGeneration = UUID()
    finish(.failure(CoveError.message("Sign-in cancelled.")))
  }
  struct Tokens: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double
    var scope: String?
    var id_token: String?
  }
  private func exchange(_ values: [String: String], secret: String) async throws -> Tokens {
    var values = values
    if !secret.isEmpty {
      values["client_secret"] = secret
    }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let form = values.map {
      "\($0.key.addingPercentEncoding(withAllowedCharacters:allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters:allowed)!)"
    }.joined(separator: "&")
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.httpBody = Data(form.utf8)
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    return try JSONDecoder().decode(
      Tokens.self, from: await checked(request, transport: LiveHTTP()))
  }
  func token() async throws -> String {
    guard let email = UserDefaults.standard.string(forKey: "accountEmail") else {
      throw CoveError.message("Connect Gmail to continue.")
    }
    let store = try sessionStore()
    let generation = connectionGeneration
    if let session = store.current {
      try session.requireMailbox(email)
      if let access, expiration > Date() { return access }
      let result = try await exchange(
        [
          "client_id": session.clientID, "refresh_token": session.refreshToken,
          "grant_type": "refresh_token",
        ], secret: session.clientSecret)
      guard generation == connectionGeneration, store.current == session,
        UserDefaults.standard.string(forKey: "accountEmail") == email
      else {
        throw CoveError.message("The Google connection changed. Please retry.")
      }
      identityToken = result.id_token
      access = result.access_token
      expiration = Date().addingTimeInterval(result.expires_in - 60)
      return result.access_token
    }
    // Upgrade old credentials only after checking their actual Gmail identity.
    guard let refresh = try Vault.read("googleRefreshToken") else {
      throw CoveError.message("Connect Gmail to continue.")
    }
    let secret = try clientSecret()
    let legacyClientID = clientID
    let result = try await exchange(
      [
        "client_id": legacyClientID, "refresh_token": refresh, "grant_type": "refresh_token",
      ], secret: secret)
    let verifiedEmail = try await GmailClient().profile(token: result.access_token)
    guard generation == connectionGeneration, store.current == nil,
      UserDefaults.standard.string(forKey: "accountEmail") == email
    else {
      throw CoveError.message("The Google connection changed. Please retry.")
    }
    let session = GoogleAccountSession(
      email: verifiedEmail, clientID: legacyClientID, clientSecret: secret, refreshToken: refresh,
      calendarConnected: UserDefaults.standard.bool(forKey: "calendarConnected"))
    try session.requireMailbox(email)
    try commit(
      PendingConnection(
        session: session, accessToken: result.access_token,
        expiration: Date().addingTimeInterval(result.expires_in - 60)))
    return result.access_token
  }
  func cloudToken(for email: String) async throws -> String {
    guard let session = try sessionStore().current else {
      throw CoveError.message("Reconnect Google to enable cloud sync.")
    }
    try session.requireMailbox(email)
    if identityToken == nil { expiration = .distantPast }
    _ = try await token()
    guard let token = identityToken else {
      throw CoveError.message("Reconnect Google for cloud sync, then enable sync again.")
    }
    return token
  }
  func disconnect() throws {
    if try Vault.read("googleAccountSession") != nil {
      // Also permits disconnecting a corrupt record without decoding it first.
      if let store = try? sessionStore() {
        try store.disconnect()
      } else {
        try Vault.delete("googleAccountSession")
      }
      try? Vault.delete("googleRefreshToken")
    } else {
      try Vault.delete("googleRefreshToken")
    }
    sessions = nil
    cancel()
    access = nil
    identityToken = nil
    expiration = .distantPast
    UserDefaults.standard.removeObject(forKey: "accountEmail")
    UserDefaults.standard.removeObject(forKey: "calendarConnected")
  }
}
