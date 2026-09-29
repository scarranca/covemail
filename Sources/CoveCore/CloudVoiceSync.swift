import Foundation

/// Wire form of a learned voice for the cloud pilot (ISO-8601 dates). Style only, never mail.
public struct CloudVoiceProfile: Codable, Equatable, Sendable {
  public var summary: String
  public var greetings: [String]
  public var signoffs: [String]
  public var traits: [String]
  public var phrases: [String]
  public var languages: [String]
  public var learnedAt: String
  public var sampleCount: Int
  public var model: String

  public init(_ profile: VoiceProfile) {
    summary = profile.summary; greetings = profile.greetings; signoffs = profile.signoffs
    traits = profile.traits; phrases = profile.phrases; languages = profile.languages
    learnedAt = CloudVoiceSync.iso(profile.learnedAt); sampleCount = profile.sampleCount; model = profile.model
  }
  public var profile: VoiceProfile? {
    guard let date = CloudVoiceSync.date(learnedAt) else { return nil }
    return VoiceProfile(summary: summary, greetings: greetings, signoffs: signoffs, traits: traits,
      phrases: phrases, languages: languages, learnedAt: date, sampleCount: sampleCount, model: model)
  }
}

public struct CloudVoice: Decodable, Equatable, Sendable {
  public let revision: String
  public let profile: CloudVoiceProfile?
  public let updatedAt: String?
}

/// Newest wins between this Mac's shared voice and the account's cloud copy. A nil profile with a
/// date is an explicit "forgotten" state and also propagates.
public enum CloudVoiceSync {
  public enum Action: Equatable {
    case none
    case upload
    case apply(profile: VoiceProfile?, updatedAt: Date)
  }
  public static func decide(localProfile: VoiceProfile?, localUpdatedAt: Date?, remote: CloudVoice) -> Action {
    let remoteDate = remote.updatedAt.flatMap(date)
    guard let localUpdatedAt else {
      guard remote.revision != "0", let remoteDate else { return .none }
      return .apply(profile: remote.profile?.profile, updatedAt: remoteDate)
    }
    guard remote.revision != "0", let remoteDate else { return .upload }
    // Second precision on the wire: equal timestamps mean the same state.
    let local = localUpdatedAt.timeIntervalSince1970.rounded(.down)
    let cloud = remoteDate.timeIntervalSince1970.rounded(.down)
    if local > cloud { return .upload }
    if cloud > local { return .apply(profile: remote.profile?.profile, updatedAt: remoteDate) }
    return localProfile == nil && remote.profile != nil ? .upload : .none
  }

  static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

extension CloudMailClient {
  public func voice(accountID: UUID, token: String) async throws -> CloudVoice {
    try await request("v1/voice", token: token,
      query: [URLQueryItem(name: "accountID", value: accountID.uuidString)], as: CloudVoice.self)
  }
  public func uploadVoice(_ profile: VoiceProfile?, updatedAt: Date, baseRevision: String, accountID: UUID,
                          requestID: UUID = UUID(), token: String) async throws -> String {
    struct Body: Encodable {
      let accountID: UUID; let requestID: UUID; let baseRevision: String
      let profile: CloudVoiceProfile?; let updatedAt: String
      enum CodingKeys: CodingKey { case accountID, requestID, baseRevision, profile, updatedAt }
      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountID, forKey: .accountID); try c.encode(requestID, forKey: .requestID)
        try c.encode(baseRevision, forKey: .baseRevision); try c.encode(updatedAt, forKey: .updatedAt)
        // Explicit null records "forgotten"; omission is never sent.
        try c.encode(profile, forKey: .profile)
      }
    }
    struct Result: Decodable { let revision: String }
    return try await request("v1/voice", method: "PUT", token: token,
      body: JSONEncoder().encode(Body(accountID: accountID, requestID: requestID, baseRevision: baseRevision,
        profile: profile.map(CloudVoiceProfile.init), updatedAt: CloudVoiceSync.iso(updatedAt))), as: Result.self).revision
  }
}
