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
    var item = legacyQuery(name)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw CoveError.message("Keychain could not save the mailbox key (\(status)).")
    }
  }

  /// True when AI keys use the data-protection keychain on this build.
  static var aiKeysHardened: Bool { HardenedSecrets.dataProtectionAvailable(service: service) }
  static var aiKeysRequireTouchID: Bool { HardenedSecrets.userPresenceActive(service: service) }
  /// Changes the Touch ID requirement and re-saves existing AI keys under the new protection.
  static func setAIKeysRequireTouchID(_ enabled: Bool) throws {
    guard aiKeysHardened else { throw CoveError.message("Touch ID protection needs the hardened, signed Cove build.") }
    var values: [String: String] = [:]
    for name in HardenedSecrets.protectedNames { if let value = try read(name) { values[name] = value } }
    HardenedSecrets.requireUserPresence = enabled
    for (name, value) in values { try save(value, name: name) }
  }
  /// Login (file-based) keychain only. On builds with the data-protection entitlement, a query
  /// that doesn't say which keychain also matches — and a delete also removes — protected items.
  static func legacyQuery(_ name: String, service: String = service) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: name, kSecUseDataProtectionKeychain as String: false,
    ]
  }
  private static var service: String {
    CoveRuntime.isQA ? "ai.cove.qa" : "ai.cove.mac"
  }
  static func read(_ name: String) throws -> String? {
    if HardenedSecrets.protects(name) {
      return try HardenedSecrets.read(name, service: service, legacy: { try legacyRead(name) },
        legacyDelete: { try legacyDelete(name) })
    }
    return try legacyRead(name)
  }
  private static func legacyRead(_ name: String) throws -> String? {
    var query = legacyQuery(name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw CoveError.message("Keychain could not be read (\(status)).")
    }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ value: String, name: String) throws {
    if HardenedSecrets.protects(name) {
      return try HardenedSecrets.save(value, name: name, service: service,
        legacySave: { try legacySave(value, name: name) }, legacyDelete: { try legacyDelete(name) })
    }
    try legacySave(value, name: name)
  }
  private static func legacySave(_ value: String, name: String) throws {
    let query = legacyQuery(name)
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
    if HardenedSecrets.protects(name) { try HardenedSecrets.delete(name, service: service) }
    try legacyDelete(name)
  }
  private static func legacyDelete(_ name: String) throws {
    let status = SecItemDelete(legacyQuery(name) as CFDictionary)
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
  /// The session store for the active account, and the Keychain entry it was loaded from.
  private var sessions: GoogleSessionStore?
  private var sessionsKey: String?
  private var migrated = false
  private var connectionGeneration = UUID()
  private var browserReply: OAuthBrowserReply?
  private let storage: Storage
  private var defaults: UserDefaults { storage.defaults }

  /// Where sign-in state lives. Production uses the Keychain (`Vault`) and standard defaults;
  /// tests inject in-memory closures so they never touch the user's real Keychain.
  struct Storage {
    var read: (String) throws -> String?
    var save: (String, String) throws -> Void  // (value, name)
    var delete: (String) throws -> Void
    var defaults: UserDefaults

    static var vault: Storage {
      Storage(
        read: { try Vault.read($0) }, save: { try Vault.save($0, name: $1) },
        delete: { try Vault.delete($0) }, defaults: .standard)
    }
  }

  /// The single-account Keychain entry used before several accounts could stay signed in.
  static let legacySessionName = "googleAccountSession"

  init(storage: Storage = .vault) {
    self.storage = storage
  }

  struct PendingConnection {
    let session: GoogleAccountSession
    let accessToken: String
    let expiration: Date
    var identityToken: String? = nil
  }

  /// Signed-in account emails, in the order they were added.
  var accounts: [String] {
    try? migrateLegacySessionIfNeeded()
    return AccountRoster.emails(defaults)
  }
  /// The account Cove is showing; every token request is for this account.
  var activeEmail: String? {
    guard let email = defaults.string(forKey: "accountEmail"), !email.isEmpty else { return nil }
    return email
  }

  private func writer(for key: String) -> (String?) throws -> Void {
    let storage = storage
    return { value in
      if let value {
        try storage.save(value, key)
      } else {
        try storage.delete(key)
      }
    }
  }

  private func sessionStore() throws -> GoogleSessionStore {
    do { try migrateLegacySessionIfNeeded() } catch {
      // The move failed (it's retried next time). Keep using the old entry for its own account so the
      // user stays signed in instead of being blocked at every launch.
      if let email = activeEmail, let legacy = try? storage.read(Self.legacySessionName),
        let session = try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(legacy.utf8)),
        session.email.caseInsensitiveCompare(email) == .orderedSame
      {
        return try GoogleSessionStore(read: { legacy }, write: writer(for: Self.legacySessionName))
      }
      throw error
    }
    guard let email = activeEmail else {
      // No active account: nothing to read, and nowhere to write.
      return try GoogleSessionStore(
        read: { nil },
        write: { _ in throw CoveError.message("Connect Gmail to continue.") })
    }
    let key = AccountRoster.sessionKey(for: email)
    if let sessions, sessionsKey == key { return sessions }
    let storage = storage
    let loaded = try GoogleSessionStore(read: { try storage.read(key) }, write: writer(for: key))
    sessions = loaded
    sessionsKey = key
    return loaded
  }

  /// Moves the old single Keychain entry to its account's own entry. Runs once per instance and is
  /// idempotent: the legacy entry is deleted only after the new entry reads back identically, and an
  /// undecodable legacy entry is left untouched.
  /// Whether an account still has a readable sign-in. nil when the Keychain couldn't be read (locked),
  /// which is not the same as missing.
  func hasSession(for email: String) -> Bool? {
    do {
      guard let value = try storage.read(AccountRoster.sessionKey(for: email)) else { return false }
      return (try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(value.utf8))) != nil
    } catch { return nil }
  }

  func migrateLegacySessionIfNeeded() throws {
    guard !migrated else { return }
    if let legacy = try storage.read(Self.legacySessionName) {
      if let session = try? JSONDecoder().decode(
        GoogleAccountSession.self, from: Data(legacy.utf8)), !session.email.isEmpty
      {
        let key = AccountRoster.sessionKey(for: session.email)
        // Only older builds write the legacy entry, so it is the newest copy of this account.
        try storage.save(String(decoding: try JSONEncoder().encode(session), as: UTF8.self), key)
        guard let stored = try storage.read(key),
          let readBack = try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(stored.utf8)),
          readBack == session
        else {
          throw CoveError.message("Cove could not move your Google sign-in. Please try again.")
        }
        AccountRoster.add(session.email, defaults)
        try storage.delete(Self.legacySessionName)
        if sessionsKey == key { sessions = nil; sessionsKey = nil }
      }
    }
    if let email = activeEmail,
      !AccountRoster.emails(defaults).contains(where: {
        $0.caseInsensitiveCompare(email) == .orderedSame
      }),
      try storage.read(AccountRoster.sessionKey(for: email)) != nil
    {
      AccountRoster.add(email, defaults)
    }
    migrated = true
  }

  var clientID: String {
    GoogleOAuthConfiguration.selected(
      customClientID: defaults.string(forKey: "googleClientID"), customSecret: nil,
      bundled: BundledGoogleOAuth.configuration
    ).clientID
  }
  private func clientSecret() throws -> String {
    let customID = defaults.string(forKey: "googleClientID") ?? ""
    let customSecret =
      customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil : try storage.read("googleClientSecret")
    return GoogleOAuthConfiguration.selected(
      customClientID: customID, customSecret: customSecret,
      bundled: BundledGoogleOAuth.configuration
    ).clientSecret
  }
  var isConnected: Bool { defaults.string(forKey: "accountEmail") != nil }
  func restorableAccountEmail() throws -> String? {
    guard let email = activeEmail else { return nil }
    if let session = try sessionStore().current {
      try session.requireMailbox(email)
      guard !session.refreshToken.isEmpty, !session.clientID.isEmpty else { return nil }
      return email
    }
    // A cached mailbox name alone does not mean the user is signed in.
    guard clientID.hasSuffix(".apps.googleusercontent.com"),
      let refresh = try storage.read("googleRefreshToken"), !refresh.isEmpty
    else { return nil }
    return email
  }

  /// Switches the active account to one already signed in, without any network request.
  func activate(email: String) throws {
    try migrateLegacySessionIfNeeded()
    let key = AccountRoster.sessionKey(for: email)
    // A Keychain read error (e.g. locked) propagates; only a missing or undecodable entry asks to sign in.
    let stored = try storage.read(key)
    guard let stored,
      let store = try? GoogleSessionStore(read: { stored }, write: writer(for: key)),
      let session = store.current
    else { throw CoveError.message("Sign in to \(email) again.") }
    try session.requireMailbox(email)
    connectionGeneration = UUID()
    access = nil
    identityToken = nil
    expiration = .distantPast
    sessions = store
    sessionsKey = key
    AccountRoster.add(session.email, defaults)
    defaults.set(session.email, forKey: "accountEmail")
    defaults.set(session.calendarConnected, forKey: "calendarConnected")
    defaults.set(session.tasksConnected == true, forKey: "tasksConnected")
  }
  private func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CoveError.message("Could not create secure sign-in session.")
    }
    return Data(bytes).base64URL
  }
  func connect(includeCalendar: Bool = false, includeCloud: Bool = false, includeTasks: Bool = false,
               loginHint: String? = nil) async throws -> PendingConnection {
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
      includeCloud: includeCloud, includeTasks: includeTasks, loginHint: loginHint)
    onSignInURL?(url)
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
        // Google returns every granted scope (earlier grants included), so adding one service never
        // drops another.
        calendarConnected: result.scope.map { $0.contains(OAuthSupport.calendarScope) } ?? includeCalendar,
        tasksConnected: result.scope.map { $0.contains(OAuthSupport.tasksScope) } ?? includeTasks),
      accessToken: result.access_token,
      expiration: Date().addingTimeInterval(result.expires_in - 60), identityToken: result.id_token)
  }
  /// Saves the account under its own Keychain entry, adds it to the roster and makes it active.
  /// Other accounts' sessions are untouched.
  func commit(_ pending: PendingConnection) throws {
    try? migrateLegacySessionIfNeeded()
    let key = AccountRoster.sessionKey(for: pending.session.email)
    // Never decode what is already stored: a corrupt entry must not block signing in again.
    let store = try GoogleSessionStore(read: { nil }, write: writer(for: key))
    try store.commit(pending.session)
    sessions = store
    sessionsKey = key
    connectionGeneration = UUID()
    access = pending.accessToken
    identityToken = pending.identityToken
    expiration = pending.expiration
    AccountRoster.add(pending.session.email, defaults)
    defaults.set(pending.session.email, forKey: "accountEmail")
    defaults.set(pending.session.calendarConnected, forKey: "calendarConnected")
    defaults.set(pending.session.tasksConnected == true, forKey: "tasksConnected")
    // Old versions stored only a refresh token; it must never be reused after a successful switch.
    try? storage.delete("googleRefreshToken")
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
    onSignInURL?(nil)
    timeout?.cancel()
    timeout = nil
    listener?.cancel()
    listener = nil
  }
  static let cancelledMessage = "Sign-in cancelled."
  /// The Google page the browser was sent to while sign-in waits (nil when not waiting), so the app can
  /// offer it for another browser.
  var onSignInURL: ((URL?) -> Void)?
  func cancel() {
    connectionGeneration = UUID()
    finish(.failure(CoveError.message(Self.cancelledMessage)))
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
    guard let email = defaults.string(forKey: "accountEmail") else {
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
        defaults.string(forKey: "accountEmail") == email
      else {
        throw CoveError.message("The Google connection changed. Please retry.")
      }
      identityToken = result.id_token
      access = result.access_token
      expiration = Date().addingTimeInterval(result.expires_in - 60)
      return result.access_token
    }
    // Upgrade old credentials only after checking their actual Gmail identity.
    guard let refresh = try storage.read("googleRefreshToken") else {
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
      defaults.string(forKey: "accountEmail") == email
    else {
      throw CoveError.message("The Google connection changed. Please retry.")
    }
    let session = GoogleAccountSession(
      email: verifiedEmail, clientID: legacyClientID, clientSecret: secret, refreshToken: refresh,
      calendarConnected: defaults.bool(forKey: "calendarConnected"))
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
  /// Signs out only the active account. Other accounts' sessions stay in the Keychain and roster.
  func disconnect() throws {
    try? migrateLegacySessionIfNeeded()
    let email = activeEmail
    var removedSession = false
    if let email {
      let key = AccountRoster.sessionKey(for: email)
      if try storage.read(key) != nil {
        // Deleting directly also permits disconnecting a corrupt record without decoding it first.
        try storage.delete(key)
        removedSession = true
      }
    }
    // A legacy entry left behind (it could not be migrated) belongs to the account being signed out
    // when it is unreadable or names that account.
    if let legacy = try storage.read(Self.legacySessionName) {
      let owner = (try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(legacy.utf8)))?.email
      if owner == nil || email == nil || owner?.caseInsensitiveCompare(email ?? "") == .orderedSame {
        try storage.delete(Self.legacySessionName)
        removedSession = true
      }
    }
    if removedSession {
      try? storage.delete("googleRefreshToken")
    } else {
      try storage.delete("googleRefreshToken")
    }
    if let email { AccountRoster.remove(email, defaults) }
    sessions = nil
    sessionsKey = nil
    cancel()
    access = nil
    identityToken = nil
    expiration = .distantPast
    defaults.removeObject(forKey: "accountEmail")
    defaults.removeObject(forKey: "calendarConnected")
    defaults.removeObject(forKey: "tasksConnected")
  }
}
