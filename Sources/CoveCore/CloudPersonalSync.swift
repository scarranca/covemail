import Foundation

/// About you between a user's iPhone, iPad and Mac through Cove's server (`/v1/personal`).
/// Opt-in per device and independent of the cloud mail mirror. The newest edit wins; the server
/// orders writes by revision. Server keys can decrypt it: this is not end-to-end encryption.
public struct PersonalSyncState: Codable, Equatable, Sendable {
  public var enabled = false
  /// The Google account sync was turned on for; another account starts over, turned off.
  public var account: String?
  /// The server revision this device last sent or received.
  public var revision = "0"
  public var lastSync: Date?
  public init() {}
}

/// Wire form of `PersonalContext` (ISO-8601 dates, lowercase project IDs).
public struct CloudPersonalContext: Codable, Equatable, Sendable {
  public struct Project: Codable, Equatable, Sendable { public var id: String; public var name: String; public var detail: String }
  public var name: String
  public var role: String
  public var company: String
  public var about: String
  public var projects: [Project]
  public var notes: [String]
  public var signature: String
  public var enabled: Bool

  /// Clipped to the server's bounds so an edit is never rejected for its length.
  public init(_ context: PersonalContext) {
    func clip(_ text: String, _ limit: Int) -> String { String(text.prefix(limit)) }
    name = clip(context.name, 80); role = clip(context.role, 80); company = clip(context.company, 80)
    about = clip(context.about, 400)
    projects = context.projects.prefix(8).map {
      Project(id: $0.id.uuidString.lowercased(), name: clip($0.name, 80), detail: clip($0.detail, 200))
    }
    notes = context.notes.prefix(20).map { clip($0, 200) }
    signature = clip(context.signature, 200)
    enabled = context.enabled
  }

  public func context(updatedAt: Date) -> PersonalContext {
    var value = PersonalContext()
    value.name = name; value.role = role; value.company = company; value.about = about
    value.projects = projects.map { project in
      var item = PersonalContext.Project(name: project.name, detail: project.detail)
      if let id = UUID(uuidString: project.id) { item.id = id }
      return item
    }
    value.notes = notes; value.signature = signature; value.enabled = enabled
    value.updatedAt = updatedAt
    return value
  }
}

public struct CloudPersonal: Decodable, Equatable, Sendable {
  public let revision: String
  public let personal: CloudPersonalContext?
  public let updatedAt: String?
}

public enum CloudPersonalSync {
  public enum Action: Equatable {
    case none
    case upload
    case apply(PersonalContext)
  }

  /// Newest wins, to the second (the wire precision). A device that never edited About you takes
  /// the server copy; a server without one takes this device's.
  public static func decide(local: PersonalContext?, remote: CloudPersonal) -> Action {
    let remoteDate = remote.updatedAt.flatMap(CloudVoiceSync.date)
    let remoteContext = remoteDate.flatMap { date in remote.personal.map { $0.context(updatedAt: date) } }
    guard let localDate = local?.updatedAt else { return remoteContext.map(Action.apply) ?? .none }
    guard remote.revision != "0", let remoteDate, let remoteContext else { return .upload }
    let mine = localDate.timeIntervalSince1970.rounded(.down)
    let theirs = remoteDate.timeIntervalSince1970.rounded(.down)
    if mine > theirs { return .upload }
    if theirs > mine { return .apply(remoteContext) }
    return .none
  }

  public struct Outcome: Equatable {
    /// The server copy to save on this device (with the server's date), if it was newer.
    public var apply: PersonalContext?
    public var state: PersonalSyncState
  }

  /// One round: read the server copy, then upload or apply. A write that races another device's
  /// is re-decided once against the newer copy.
  public static func sync(local: PersonalContext?, state: PersonalSyncState, client: CloudMailClient,
                          token: () async throws -> String, now: Date = Date()) async throws -> Outcome {
    var state = state
    for attempt in 0..<2 {
      let remote = try await client.personal(token: try await token())
      try Task.checkCancellation()
      switch decide(local: local, remote: remote) {
      case .none:
        state.revision = remote.revision; state.lastSync = now
        return Outcome(apply: nil, state: state)
      case .apply(let context):
        state.revision = remote.revision; state.lastSync = now
        return Outcome(apply: context, state: state)
      case .upload:
        guard let local, let updatedAt = local.updatedAt else { return Outcome(apply: nil, state: state) }
        do {
          state.revision = try await client.uploadPersonal(local, updatedAt: updatedAt,
            baseRevision: remote.revision, token: try await token())
          state.lastSync = now
          return Outcome(apply: nil, state: state)
        } catch let failure as CloudSyncFailure where failure.code == "personal_conflict" && attempt == 0 {
          continue
        }
      }
    }
    throw CloudSyncFailure(code: "personal_conflict")
  }
}

extension CloudMailClient {
  public func personal(token: String) async throws -> CloudPersonal {
    try await request("v1/personal", token: token, as: CloudPersonal.self)
  }
  public func uploadPersonal(_ context: PersonalContext, updatedAt: Date, baseRevision: String,
                             token: String) async throws -> String {
    struct Body: Encodable { let baseRevision: String; let personal: CloudPersonalContext; let updatedAt: String }
    struct Result: Decodable { let revision: String }
    return try await request("v1/personal", method: "PUT", token: token,
      body: JSONEncoder().encode(Body(baseRevision: baseRevision, personal: CloudPersonalContext(context),
        updatedAt: CloudVoiceSync.iso(updatedAt))), as: Result.self).revision
  }
  /// Removes the server copy only; every device keeps its own.
  public func removePersonal(token: String) async throws {
    struct Result: Decodable { let deleted: Bool }
    let _: Result = try await request("v1/personal", method: "DELETE", token: token, body: Data("{}".utf8), as: Result.self)
  }
}
