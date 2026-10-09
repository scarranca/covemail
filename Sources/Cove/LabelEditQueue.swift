import CoveCore
import Foundation

/// One label change (archive, star, read, a label) that Gmail hasn't confirmed yet. Saved with the
/// mailbox (`pendingLabelEdits`, encrypted like every record), so quitting or going offline never
/// loses an archive: it shows at once, stays, and reaches Gmail when it can.
struct QueuedLabelChange: Codable, Equatable {
  var mailID: String
  var add: [String]
  var remove: [String]
  /// Of the labels this change touches, those the email had before it: what a refusal restores.
  var had: Set<String>
  var attempts = 0
  /// The last attempt may have reached Gmail (a timeout, a dropped connection): an Undo is then sent as
  /// its own change rather than cancelling this one.
  var maybeSent = false

  // This session only.
  /// Identifies the entry while it is being sent.
  var token = UUID()
  /// Its `labelEdits` revisions, so a sync keeps re-applying it until Gmail has it.
  var revisions: [Int] = []
  var sending = false
  /// The user is waiting for the first attempt: a refusal is an alert. Later attempts report quietly.
  var userWaiting = true

  enum CodingKeys: String, CodingKey { case mailID, add, remove, had, attempts, maybeSent }

  var operation: String { add.isEmpty && remove == ["UNREAD"] ? Self.markReadOperation : Self.updateOperation }
  static let updateOperation = "Updating message…"
  static let markReadOperation = "Marking email as read…"
  static func isQueueOperation(_ operation: String) -> Bool {
    operation == updateOperation || operation == markReadOperation
  }
  /// This change exactly reverses `other` (Undo of an archive, unstar after star).
  func reverses(_ other: QueuedLabelChange) -> Bool {
    Set(add) == Set(other.remove) && Set(remove) == Set(other.add) && !(add.isEmpty && remove.isEmpty)
  }
}

/// How a label change attempt ended.
enum LabelDeliveryOutcome: Equatable {
  case delivered
  /// Offline, timed out, Gmail busy: keep it, retry later.
  /// `maybeSent`: the request may have reached Gmail (timed out, connection dropped), not never left.
  case retryLater(rateLimited: Bool, offline: Bool, maybeSent: Bool)
  /// Google needs the user to sign in again; keep it until they do.
  case signInNeeded
  /// Gmail no longer has the email (404).
  case gone
  /// Gmail refused it (a 4xx), or failed with a server error on this write, which is never retried.
  case refused(serverError: Bool, message: String)
  /// The mailbox closed or the attempt was cancelled: keep it for next time, change nothing.
  case cancelled

  static func classify(_ error: Error) -> LabelDeliveryOutcome {
    if error is CancellationError { return .cancelled }
    if error is GoogleSignInRequired { return .signInNeeded }
    if let http = error as? HTTPFailure {
      // A rate-limited request was not performed.
      if http.isRateLimited { return .retryLater(rateLimited: true, offline: false, maybeSent: false) }
      switch http.statusCode {
      case 401: return .signInNeeded
      case 404: return .gone
      case 408: return .retryLater(rateLimited: false, offline: false, maybeSent: true)
      case 500..<600: return .refused(serverError: true, message: http.localizedDescription)
      default: return .refused(serverError: false, message: http.localizedDescription)
      }
    }
    // Transport failures: a label change is idempotent, so trying again later is harmless. Whether it
    // may already have reached Gmail only matters for cancelling it (an Undo).
    var current = error as NSError
    for _ in 0..<5 {
      if current.domain == NSURLErrorDomain {
        let code = URLError.Code(rawValue: current.code)
        if code == .cancelled { return .cancelled }
        return .retryLater(rateLimited: false, offline: code == .notConnectedToInternet, maybeSent: !neverLeft.contains(code))
      }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      current = underlying
    }
    return .refused(serverError: false, message: error.localizedDescription)
  }
  /// Failures that happen before a request can reach the server.
  static let neverLeft: Set<URLError.Code> = [
    .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .dataNotAllowed,
    .internationalRoamingOff, .callIsActive,
  ]
}

extension AppStore {
  static let labelQueueKey = "pendingLabelEdits"

  // MARK: Gmail tokens

  /// A Gmail access token. A refusal of Cove's sign-in (not a network problem) becomes
  /// `GoogleSignInRequired`, so callers show one reconnect affordance instead of repeating alerts.
  func gmailToken() async throws -> String {
    do {
      let token: String
      if let provider = gmailTokenProvider { token = try await provider() } else { token = try await auth.token() }
      if googleSignInNeeded { googleSignInNeeded = false }
      return token
    } catch {
      throw GoogleSignInRequired.classify(error, email: accountEmail)
    }
  }

  /// Runs a Gmail request; a 401 gets one fresh token and one more try (401 means Gmail did nothing,
  /// so a write is safe to repeat). A second 401 means the sign-in itself no longer works.
  func withGmailToken<T>(_ body: (String) async throws -> T) async throws -> T {
    let token = try await gmailToken()
    do { return try await body(token) } catch let failure as HTTPFailure where failure.statusCode == 401 {
      let fresh: String
      do {
        if let gmailTokenRefresh { fresh = try await gmailTokenRefresh() } else {
          // Re-activating the open account drops only its cached access token (no network, no prompt).
          if gmailTokenProvider == nil, !isSample, !accountEmail.isEmpty { try? auth.activate(email: accountEmail) }
          fresh = try await gmailToken()
        }
      } catch { throw GoogleSignInRequired.classify(error, email: accountEmail) }
      do { return try await body(fresh) } catch let again as HTTPFailure where again.statusCode == 401 {
        throw GoogleSignInRequired(email: accountEmail)
      }
    }
  }

  // MARK: The queue

  /// Records a label change already applied locally (and to `labelEdits` as `revision`). Returns false
  /// when it simply cancels a change still waiting to be sent (Undo while offline): nothing to deliver.
  func queueLabelChange(id: String, add: [String], remove: [String], before: Set<String>, revision: Int) -> Bool {
    var change = QueuedLabelChange(mailID: id, add: add, remove: remove,
      had: before.intersection(add + remove), revisions: [revision])
    var queue = labelQueue[id] ?? []
    if let last = queue.last, !last.sending, !last.maybeSent, change.reverses(last) {
      // Neither reached Gmail: forget both, so no sync re-applies them and nothing is sent. (If the
      // last attempt might have arrived, the reversal is queued and sent after it instead.)
      queue.removeLast()
      for revision in last.revisions + change.revisions { dropLabelEdit(id: id, revision: revision) }
      labelQueue[id] = queue.isEmpty ? nil : queue
      saveLabelQueue()
      return false
    }
    change.userWaiting = true
    queue.append(change)
    labelQueue[id] = queue
    saveLabelQueue()
    return true
  }

  /// Starts (or chains) delivery of an email's queued changes, in order; created synchronously so a
  /// later change to the same email always follows it. Ends after delivering everything, or at the
  /// first change that has to wait (offline); `labelRetryTask` picks that up.
  @discardableResult
  func startLabelDelivery(id: String) -> Task<Void, Never> {
    let previous = labelTasks[id]
    let generation = mailboxGeneration
    let token = UUID()
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      if generation == self.mailboxGeneration { await self.drainLabelQueue(id: id, generation: generation) }
      if self.labelTaskTokens[id] == token { self.labelTasks[id] = nil; self.labelTaskTokens[id] = nil }
    }
    labelTasks[id] = task
    labelTaskTokens[id] = token
    return task
  }

  private func drainLabelQueue(id: String, generation: UUID) async {
    let database = database
    while generation == mailboxGeneration, !Task.isCancelled,
          let head = labelQueue[id]?.first, !head.sending {
      updateHead(id: id, token: head.token) { $0.sending = true }
      let outcome = await attempt(head)
      guard generation == mailboxGeneration else {
        // Delivered after the mailbox closed: make sure it isn't sent again when it reopens.
        if outcome == .delivered, let database { Self.forgetSaved(head, in: database) }
        return
      }
      switch outcome {
      case .delivered:
        for revision in head.revisions { finishLabelEdit(id: id, revision: revision) }
        removeHead(id: id, token: head.token)
        // Gmail is reachable again: clear the tag this queue raised and send what else is waiting now.
        if let issue = connectionIssue, QueuedLabelChange.isQueueOperation(issue.operation) { connectionIssue = nil }
        if labelRetryTask != nil { retryQueuedLabelChanges() }
      case .retryLater, .signInNeeded:
        waitToRetry(id: id, outcome: outcome)
        return
      case .cancelled:
        updateHead(id: id, token: head.token) { $0.sending = false }
        return
      case .gone:
        // Deleted in Gmail: the email and everything queued for it go, quietly.
        labelQueue[id] = nil
        saveLabelQueue()
        purgeDeletedMail(id: id)
        return
      case .refused(let serverError, let message):
        refuse(head, serverError: serverError, message: message)
      }
    }
  }

  /// One attempt. Getting the token is its own step: if that fails for any reason other than Google
  /// refusing the sign-in (a locked Keychain, a switch in progress, no network), nothing reached Gmail,
  /// so the change waits instead of being undone.
  private func attempt(_ change: QueuedLabelChange) async -> LabelDeliveryOutcome {
    func tokenFailure(_ error: Error) -> LabelDeliveryOutcome {
      if error is CancellationError { return .cancelled }
      if error is GoogleSignInRequired { return .signInNeeded }
      return .retryLater(rateLimited: false, offline: ConnectionIssue(error, operation: "")?.offline ?? false, maybeSent: false)
    }
    func send(_ token: String) async -> LabelDeliveryOutcome {
      do {
        try await gmail.modify(id: change.mailID, token: token, add: change.add, remove: change.remove)
        return .delivered
      } catch { return LabelDeliveryOutcome.classify(error) }
    }
    let token: String
    do { token = try await gmailToken() } catch { return tokenFailure(error) }
    let first = await send(token)
    guard first == .signInNeeded else { return first }
    // A 401 means Gmail did nothing: one fresh token, one more try; a second 401 is the sign-in itself.
    let fresh: String
    do {
      if let gmailTokenRefresh { fresh = try await gmailTokenRefresh() } else {
        if gmailTokenProvider == nil, !isSample, !accountEmail.isEmpty { try? auth.activate(email: accountEmail) }
        fresh = try await gmailToken()
      }
    } catch { return tokenFailure(GoogleSignInRequired.classify(error, email: accountEmail)) }
    return await send(fresh)
  }

  /// Keeps the email's changes queued after a failed attempt and schedules the next one.
  private func waitToRetry(id: String, outcome: LabelDeliveryOutcome) {
    guard var queue = labelQueue[id] else { return }
    for index in queue.indices { queue[index].userWaiting = false }
    queue[0].sending = false
    queue[0].attempts += 1
    if case .retryLater(_, _, let maybeSent) = outcome { queue[0].maybeSent = maybeSent }
    labelQueue[id] = queue
    saveLabelQueue()
    let operation = queue[0].operation
    switch outcome {
    case .retryLater(true, _, _):
      setStatusQuietly("Gmail is busy · your change will reach it in a moment")
    case .retryLater(false, let offline, _):
      // Same tag while it lasts; a new one only when there wasn't one for this kind of problem.
      if connectionIssue == nil || connectionIssue?.offline != offline {
        connectionIssue = ConnectionIssue(offline: offline, operation: operation)
      }
    case .signInNeeded:
      if !googleSignInNeeded { googleSignInNeeded = true }
    default: break
    }
    if !googleSignInNeeded { scheduleLabelRetry() }
  }

  /// Gmail refused the change: undo exactly what it did here (later changes stay) and say so.
  private func refuse(_ change: QueuedLabelChange, serverError: Bool, message: String) {
    let id = change.mailID
    removeHead(id: id, token: change.token)
    for revision in change.revisions { dropLabelEdit(id: id, revision: revision) }
    applyLocalLabelChange(id: id, add: change.remove.filter { change.had.contains($0) },
                          remove: change.add.filter { !change.had.contains($0) })
    reconcileSelection()
    let what = change.operation == QueuedLabelChange.markReadOperation
      ? "Couldn’t mark this email as read in Gmail, so it’s unread again. "
      : "Couldn’t update this email in Gmail, so it’s back as it was. "
    if change.userWaiting {
      error = what + message
    } else if serverError {
      // A write that failed on Gmail's side is never repeated automatically; no alert for a change the
      // user made a while ago, just the tag and the status line.
      connectionIssue = ConnectionIssue(gmailError: change.operation)
      setStatusQuietly("Gmail couldn’t take an earlier change · that email is back as it was")
    } else {
      setStatusQuietly("Gmail didn’t accept an earlier change · that email is back as it was")
    }
  }

  private func updateHead(id: String, token: UUID, _ change: (inout QueuedLabelChange) -> Void) {
    guard let index = labelQueue[id]?.firstIndex(where: { $0.token == token }) else { return }
    change(&labelQueue[id]![index])
  }
  private func removeHead(id: String, token: UUID) {
    labelQueue[id]?.removeAll { $0.token == token }
    if labelQueue[id]?.isEmpty == true { labelQueue[id] = nil }
    saveLabelQueue()
  }

  /// Saves the queue with the mailbox. A failed save is not an alert: the changes still go this session.
  func saveLabelQueue() {
    let count = labelQueue.values.reduce(0) { $0 + $1.count }
    if pendingLabelChanges != count { pendingLabelChanges = count }
    guard let database, !isSample else { return }
    let all = labelQueue.keys.sorted().flatMap { labelQueue[$0] ?? [] }
    do {
      if all.isEmpty { try database.removeRecord(key: Self.labelQueueKey) } else { try database.save(all, key: Self.labelQueueKey) }
    } catch {
      setStatusQuietly("Couldn’t save pending changes on this Mac · they still go to Gmail while Cove is open")
    }
  }

  private static func forgetSaved(_ change: QueuedLabelChange, in database: Database) {
    guard var saved = try? database.load([QueuedLabelChange].self, key: labelQueueKey),
          let index = saved.firstIndex(where: { $0.mailID == change.mailID && $0.add == change.add && $0.remove == change.remove })
    else { return }
    saved.remove(at: index)
    try? saved.isEmpty ? database.removeRecord(key: labelQueueKey) : database.save(saved, key: labelQueueKey)
  }

  /// Picks up changes saved by an earlier session (quit while offline). The emails were saved with the
  /// change applied, so nothing changes on screen; they're registered so a sync can't undo them.
  func replaySavedLabelChanges() {
    guard !isSample, let database,
          let saved = try? database.load([QueuedLabelChange].self, key: Self.labelQueueKey), !saved.isEmpty
    else { return }
    for var change in saved {
      change.revisions = [beginLabelEdit(id: change.mailID, add: Set(change.add), remove: Set(change.remove))]
      change.userWaiting = false
      labelQueue[change.mailID, default: []].append(change)
    }
    pendingLabelChanges = saved.count
    retryQueuedLabelChanges()
  }

  /// Tries every waiting change now (connection back, a sync succeeded, signed in again).
  func retryQueuedLabelChanges() {
    labelRetryTask?.cancel(); labelRetryTask = nil
    for (id, queue) in labelQueue where queue.first?.sending == false && labelTasks[id] == nil {
      startLabelDelivery(id: id)
    }
  }

  private func scheduleLabelRetry() {
    guard labelRetryTask == nil, !labelQueue.isEmpty, !labelRetryDelays.isEmpty else { return }
    let attempts = labelQueue.values.compactMap { $0.first?.attempts }.min() ?? 1
    let delay = labelRetryDelays[min(max(attempts - 1, 0), labelRetryDelays.count - 1)]
    let generation = mailboxGeneration
    labelRetryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, generation == self.mailboxGeneration else { return }
      self.labelRetryTask = nil
      self.retryQueuedLabelChanges()
    }
  }

  /// Drops the session's queue state (the saved copy stays with its mailbox).
  func resetLabelQueue() {
    labelRetryTask?.cancel(); labelRetryTask = nil
    labelQueue = [:]
    labelTaskTokens = [:]
    pendingLabelChanges = 0
  }

  /// Test hook: waits for every delivery attempt in progress.
  func awaitLabelDeliveries() async {
    while let task = labelTasks.values.first { await task.value }
  }

  func setStatusQuietly(_ text: String) { if status != text { status = text } }
}
