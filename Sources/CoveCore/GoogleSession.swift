import Foundation

/// Identity and refresh credentials are one Keychain value, so they cannot be replaced separately.
public struct GoogleAccountSession: Codable, Equatable {
  public var email: String
  public var clientID: String
  public var clientSecret: String
  public var refreshToken: String
  public var calendarConnected: Bool
  /// Optional so sessions saved before Google Tasks still decode; nil means not connected.
  public var tasksConnected: Bool?

  public init(
    email: String, clientID: String, clientSecret: String, refreshToken: String,
    calendarConnected: Bool, tasksConnected: Bool? = nil
  ) {
    self.tasksConnected = tasksConnected
    self.email = email
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.refreshToken = refreshToken
    self.calendarConnected = calendarConnected
  }

  public func requireMailbox(_ email: String) throws {
    guard self.email.caseInsensitiveCompare(email) == .orderedSame else {
      throw CoveError.message(
        "The Google connection does not match this mailbox. Reconnect Gmail to continue.")
    }
  }
}

public final class GoogleSessionStore {
  public private(set) var current: GoogleAccountSession?
  private let write: (String?) throws -> Void

  public init(read: () throws -> String?, write: @escaping (String?) throws -> Void) throws {
    self.write = write
    if let value = try read() {
      current = try JSONDecoder().decode(GoogleAccountSession.self, from: Data(value.utf8))
    }
  }

  public func commit(_ session: GoogleAccountSession) throws {
    let encoded = try JSONEncoder().encode(session)
    try write(String(decoding: encoded, as: UTF8.self))
    current = session
  }

  public func disconnect() throws {
    try write(nil)
    current = nil
  }
}
