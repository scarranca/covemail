import CoveCore
import Foundation

/// The learned voice belongs to the person, so it is shared by every Gmail account on this Mac.
/// It is kept in Cove's Keychain service (encrypted, this Mac only), never in UserDefaults.
struct SharedVoiceRecord: Codable, Equatable {
  /// nil after "Forget my voice"; `updatedAt` then clears older copies in other accounts.
  var profile: VoiceProfile?
  var updatedAt: Date
}

struct SharedVoiceStore {
  var load: () throws -> SharedVoiceRecord?
  var save: (SharedVoiceRecord) throws -> Void

  static let keychain = SharedVoiceStore(
    load: {
      guard let text = try Vault.read("voiceProfile.shared") else { return nil }
      return try JSONDecoder().decode(SharedVoiceRecord.self, from: Data(text.utf8))
    },
    save: { record in
      try Vault.save(String(decoding: try JSONEncoder().encode(record), as: UTF8.self), name: "voiceProfile.shared")
    })

  static func memory() -> SharedVoiceStore {
    final class Box { var record: SharedVoiceRecord? }
    let box = Box()
    return SharedVoiceStore(load: { box.record }, save: { box.record = $0 })
  }

  /// The profile an account should use: the newest of its own copy and the shared record.
  static func reconcile(account: VoiceProfile?, shared: SharedVoiceRecord?) -> (profile: VoiceProfile?, seedShared: Bool) {
    guard let shared else { return (account, account != nil) }
    if let account, account.learnedAt > shared.updatedAt { return (account, true) }
    return (shared.profile, false)
  }
}
