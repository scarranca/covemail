import CoveCore
import Foundation

/// About you between this Mac and the user's iPhone and iPad (`/v1/personal`). Opt-in per account in
/// Agent → About you, separate from the cloud mail mirror. It needs the Google identity scope
/// (`openid email`), which the mail mirror also uses; turning sync on asks Google for it if missing.
extension AppStore {
  /// The Google sign-in must keep the identity scope while either cloud feature is on.
  var needsGoogleIdentity: Bool { cloudMirror.enabled || personalSync.enabled }

  var personalSyncOn: Bool { personalSync.enabled && personalSync.account == accountEmail && !isSample }

  func setPersonalSync(_ enabled: Bool) async {
    guard entered, !isSample, cloudConfigured, let database else { return }
    guard enabled else {
      personalSyncTask?.cancel(); personalSyncTask = nil
      personalSync = PersonalSyncState()
      try? database.save(personalSync, key: "personalSync")
      personalSyncStatus = "Sync is off. Your other devices keep their copy."
      return
    }
    let generation = mailboxGeneration; let email = accountEmail
    personalSyncing = true
    defer { if generation == mailboxGeneration { personalSyncing = false } }
    do {
      if (try? await auth.cloudToken(for: email)) == nil {
        personalSyncStatus = "Connecting Google…"
        let pending = try await auth.connect(includeCalendar: calendarConnected, includeCloud: true, includeTasks: tasksConnected,
                                             loginHint: email)
        guard generation == mailboxGeneration, email == accountEmail else { throw CancellationError() }
        try pending.session.requireMailbox(email)
        try auth.commit(pending)
        auth.finishBrowserSignIn(success: true)
      }
      var state = PersonalSyncState()
      state.enabled = true; state.account = email
      personalSync = state
      try database.save(state, key: "personalSync")
    } catch {
      auth.finishBrowserSignIn(success: false)
      if generation == mailboxGeneration { personalSyncStatus = error.localizedDescription }
      return
    }
    personalSyncing = false
    await syncPersonal()
  }

  /// After an edit: waits for a pause in typing, then syncs (the server allows 60 requests a minute).
  func schedulePersonalSync() {
    guard personalSyncOn else { return }
    personalSyncTask?.cancel()
    personalSyncTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      await self?.syncPersonal()
    }
  }

  /// From the 30-second app loop: about every two minutes while Cove is open.
  func pollPersonal() {
    guard personalSyncOn, !personalSyncing, cloudConfigured, entered else { return }
    let elapsed = syncClock().timeIntervalSince(lastPersonalSync)
    guard elapsed >= 120 || elapsed < 0 else { return }
    Task { await syncPersonal() }
  }

  /// Tests pass `client` and `token`; the app uses its Cove server and the account's Google ID token.
  func syncPersonal(client injected: CloudMailClient? = nil, token: (() async throws -> String)? = nil) async {
    guard personalSyncOn, !personalSyncing, let database else { return }
    guard let client = try? injected ?? cloudURL.map({ try CloudMailClient(baseURL: $0) }) else { return }
    personalSyncing = true
    lastPersonalSync = syncClock()
    let generation = mailboxGeneration; let email = accountEmail
    defer { if generation == mailboxGeneration { personalSyncing = false } }
    do {
      let outcome = try await CloudPersonalSync.sync(local: preferences.personal, state: personalSync, client: client,
        token: {
          if let token { return try await token() }
          return try await self.auth.cloudToken(for: email)
        })
      guard generation == mailboxGeneration, email == accountEmail, personalSyncOn else { return }
      if let remote = outcome.apply {
        // The server's copy keeps its own date, so it isn't sent straight back.
        var updated = preferences
        updated.personal = remote
        try database.save(updated, key: "preferences")
        preferences = updated
      }
      personalSync = outcome.state
      try database.save(outcome.state, key: "personalSync")
      personalSyncStatus = "Up to date with your other devices"
    } catch is CancellationError {
    } catch let failure as CloudSyncFailure where failure.code == "authentication_required" {
      if generation == mailboxGeneration { personalSyncStatus = "Cove’s server didn’t accept this sign-in. This account must be in the private beta." }
    } catch {
      if generation == mailboxGeneration { personalSyncStatus = "Couldn’t sync just now. Cove will try again." }
    }
  }

  /// Deletes the copy on Cove's server and turns sync off on this Mac. Devices keep their own copy.
  func removePersonalCloudCopy(client injected: CloudMailClient? = nil, token: (() async throws -> String)? = nil) async {
    guard entered, !isSample, let database else { return }
    guard let client = try? injected ?? cloudURL.map({ try CloudMailClient(baseURL: $0) }) else { return }
    let email = accountEmail
    do {
      let identity: String
      if let token { identity = try await token() } else { identity = try await auth.cloudToken(for: email) }
      try await client.removePersonal(token: identity)
      personalSyncTask?.cancel(); personalSyncTask = nil
      personalSync = PersonalSyncState()
      try database.save(personalSync, key: "personalSync")
      personalSyncStatus = "Removed from Cove’s server. This Mac keeps its copy; turn sync off on your other devices too."
    } catch {
      personalSyncStatus = "Couldn’t remove the server copy. Try again."
    }
  }
}
