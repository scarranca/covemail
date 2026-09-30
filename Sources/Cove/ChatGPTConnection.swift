import AppKit
import CoveCore
import Foundation
import Observation
import Security

/// Talks only to the official, locally installed Codex app-server. Cove never reads OAuth tokens.
@MainActor @Observable final class ChatGPTConnection {
  static let shared = ChatGPTConnection()
  private let runtimeOverride: URL?
  private let executableOverride: String?
  private let responseTimeout: Duration
  init(runtimeDirectory: URL? = nil, executable: String? = nil, responseTimeout: Duration = .seconds(120)) {
    runtimeOverride = runtimeDirectory
    executableOverride = executable
    self.responseTimeout = responseTimeout
  }
  var status = "Not connected"
  var connected = false
  /// A successful account check is reused for a few minutes while the helper keeps running.
  private var lastAccountCheck: Date?
  /// Receives the answer as it is written (item/agentMessage/delta), for progressive display.
  private var onPartial: ((String) -> Void)?
  private var streamed = ""
  private var starting: Task<Void, Error>?
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var generation = UUID()
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var turn: CheckedContinuation<String, Error>?
  private var output = ""
  private var activeThread: String?
  private var isGenerating = false
  private var directory: URL {
    if let runtimeOverride { return runtimeOverride }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        CoveRuntime.isQA ? "Cove-QA/ChatGPT" : "Cove/ChatGPT",
        isDirectory: true)
  }
  var executablePath: String {
    get {
      executableOverride ?? UserDefaults.standard.string(forKey: "ai.codexPath")
        ?? Self.detectExecutable() ?? ""
    }
    set {
      guard newValue != executablePath else { return }
      // A selection applies to the next check immediately, not only after restarting Cove.
      process?.terminate()
      generation = UUID()
      stopped()
      UserDefaults.standard.set(newValue, forKey: "ai.codexPath")
      connected = false
      status = "Codex changed. Check the connection to continue."
    }
  }
  private static func detectExecutable() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // The official standalone updater owns this location. Prefer it over a stale Homebrew copy.
    return [
      home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  private func start() async throws {
    if let starting { return try await starting.value }
    if process?.isRunning == true { return }
    let task = Task { @MainActor in try await self.launch() }
    starting = task
    defer { starting = nil }
    try await task.value
  }
  private func launch() async throws {
    guard !executablePath.isEmpty, FileManager.default.isExecutableFile(atPath: executablePath)
    else {
      throw CoveError.message(
        "Install the official Codex CLI, then select its executable in Integrations.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let config = """
      cli_auth_credentials_store = "keyring"
      forced_login_method = "chatgpt"
      approval_policy = "never"
      sandbox_mode = "read-only"
      web_search = "disabled"
      project_doc_max_bytes = 0
      [otel]
      log_user_prompt = false
      [history]
      persistence = "none"
      [features]
      shell_tool = false
      unified_exec = false
      apps = false
      hooks = false
      multi_agent = false
      remote_plugin = false
      skill_mcp_dependency_install = false
      [tools]
      view_image = false
      [mcp_servers]
      """
    try config.write(
      to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let temporary = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let binary = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
    let policy = try ChatGPTSandbox.profile(
      runtime: directory.resolvingSymlinksInPath().path, executable: binary,
      keychain: runtimeOverride == nil ? try Self.defaultKeychainPath() : nil)
    let worker = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    worker.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    worker.arguments = ["-p", policy, binary, "app-server", "--listen", "stdio://"]
    worker.currentDirectoryURL = directory
    // Deliberately isolated Codex configuration; no API keys or parent process tokens inherited.
    worker.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "CODEX_HOME": directory.path, "TMPDIR": temporary.path,
    ]
    worker.standardInput = stdin
    worker.standardOutput = stdout
    worker.standardError = FileHandle.nullDevice
    input = stdin.fileHandleForWriting
    let currentGeneration = UUID()
    generation = currentGeneration
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor [weak self] in
        guard self?.generation == currentGeneration else { return }
        self?.receive(data)
      }
    }
    worker.terminationHandler = { [weak self] stoppedWorker in
      Task { @MainActor [weak self] in
        guard self?.process === stoppedWorker else { return }
        self?.stopped()
      }
    }
    try worker.run()
    process = worker
    _ = try await rpc(
      "initialize", ["clientInfo": ["name": "cove", "title": "Cove", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"]])
    try send(["method": "initialized", "params": [:]])
  }
  func refresh() async throws {
    try await start()
    try Task.checkCancellation()
    let result = try await rpc("account/read", ["refreshToken": false])
    connected = (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
    status = connected ? "Connected with ChatGPT" : "Not connected"
    lastAccountCheck = connected ? Date() : nil
  }
  private static func defaultKeychainPath() throws -> String {
    var keychain: SecKeychain?
    guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else {
      throw CoveError.message(
        "macOS could not open your default keychain. Unlock it in Keychain Access, then try ChatGPT again. Do not reset your keychain."
      )
    }
    var length: UInt32 = 4096
    var path = [CChar](repeating: 0, count: Int(length))
    guard SecKeychainGetPath(keychain, &length, &path) == errSecSuccess else {
      throw CoveError.message(
        "macOS could not locate your default keychain. Check Keychain Access before reconnecting ChatGPT."
      )
    }
    return String(cString: path)
  }
  func login() async throws {
    try await start()
    try Task.checkCancellation()
    let result = try await rpc("account/login/start", ["type": "chatgpt"])
    guard let raw = result["authUrl"] as? String, let url = URL(string: raw), url.scheme == "https",
      let host = url.host, ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host)
    else { throw CoveError.message("Codex did not return a recognized sign-in address.") }
    try Task.checkCancellation()
    status = "Finish signing in in your browser"
    NSWorkspace.shared.open(url)
  }
  func logout() async throws {
    try await start()
    _ = try await rpc("account/logout", [:])
    connected = false
    status = "Not connected"
  }
  func models() async throws -> [String] {
    try await refresh()
    guard connected else {
      throw CoveError.message("Connect your ChatGPT account in Integrations first.")
    }
    var models: [String] = []
    var seenModels = Set<String>()
    var seenCursors = Set<String>()
    var cursor: String?
    repeat {
      try Task.checkCancellation()
      var parameters: [String: Any] = ["limit": 100, "includeHidden": false]
      if let cursor { parameters["cursor"] = cursor }
      let result = try await rpc("model/list", parameters)
      guard let page = result["data"] as? [[String: Any]] else {
        throw CoveError.message("Codex returned an invalid model list. Update the official Codex CLI and refresh models.")
      }
      for item in page {
        guard item["hidden"] as? Bool != true,
              let model = item["model"] as? String, !model.isEmpty,
              seenModels.insert(model).inserted else { continue }
        models.append(model)
      }
      cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw CoveError.message("Codex repeated a model-list page. Refresh models to try again.")
      }
    } while cursor != nil
    return models
  }
  func complete(model: String, prompt: AIPrompt, onPartial: ((String) -> Void)? = nil) async throws -> String {
    guard !isGenerating else { throw CoveError.message("A ChatGPT request is already running.") }
    isGenerating = true
    defer { isGenerating = false }
    // Skip the account round-trip when the helper is running and was verified recently.
    if process == nil || !connected || Date().timeIntervalSince(lastAccountCheck ?? .distantPast) > 300 {
      try await refresh()
    }
    try Task.checkCancellation()
    guard connected, !model.isEmpty else {
      throw CoveError.message("Connect ChatGPT and choose a model in Integrations.")
    }
    guard turn == nil else { throw CoveError.message("A ChatGPT request is already running.") }
    let result = try await rpc(
      "thread/start",
      [
        "model": model, "cwd": directory.path, "ephemeral": true, "approvalPolicy": "never",
        "sandbox": "read-only", "baseInstructions": prompt.system,
        "developerInstructions": "Do not invoke Codex tools. Follow the requested response format using supplied evidence. Cove handles only validated read-only context plans.",
      ])
    guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
      throw CoveError.message("Could not start a ChatGPT request.")
    }
    try Task.checkCancellation()
    activeThread = id
    output = ""
    streamed = ""
    self.onPartial = onPartial
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        turn = continuation
        Task { @MainActor in
          do {
            guard activeThread == id else { return }
            _ = try await rpc(
              "turn/start",
              [
                "threadId": id,
                "input": [
                  [
                    "type": "text",
                    "text": prompt.dataMessage + "\n\nUser request:\n" + prompt.user,
                  ]
                ], "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
              ])
          } catch { finish(.failure(error)) }
        }
        Task { @MainActor in
          try? await Task.sleep(for: responseTimeout)
          if activeThread == id {
            cancel(error: CoveError.message("ChatGPT took too long to answer. Try again, or choose another model in Integrations."))
          }
        }
      }
    } onCancel: {
      Task { @MainActor in if self.activeThread == id { self.cancel() } }
    }
  }
  func shutdown() { cancel() }
  private func cancel(error: Error = CancellationError()) {
    let worker = process
    generation = UUID()
    finish(.failure(error))
    worker?.terminate()
    stopped() // A retry must start a fresh helper, not reuse one that is terminating.
  }
  private static func failureMessage(_ value: Any?, fallback: String) -> String {
    guard let object = value as? [String: Any], let message = object["message"] as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
    return String(message.prefix(600))
  }
  private func finish(_ result: Result<String, Error>) {
    let continuation = turn
    turn = nil
    activeThread = nil
    output = ""
    streamed = ""
    onPartial = nil
    continuation?.resume(with: result)
  }
  private func stopped() {
    lastAccountCheck = nil
    process = nil
    input = nil
    buffer = Data()
    let requests = pending
    pending = [:]
    for continuation in requests.values {
      continuation.resume(
        throwing: CoveError.message("The ChatGPT connection stopped. Reconnect in Integrations."))
    }
    finish(.failure(CoveError.message("The ChatGPT connection stopped.")))
  }
  private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    nextID += 1
    let id = nextID
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do { try send(["id": id, "method": method, "params": params]) } catch {
        pending.removeValue(forKey: id)?.resume(throwing: error)
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(30))
        if let expired = pending.removeValue(forKey: id) {
          expired.resume(
            throwing: CoveError.message("ChatGPT connection timed out. Try reconnecting."))
          process?.terminate()
        }
      }
    }
  }
  private func send(_ object: [String: Any]) throws {
    guard let input else { throw CoveError.message("ChatGPT is not connected.") }
    var data = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try input.write(contentsOf: data)
  }
  private func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    buffer.append(data)
    guard buffer.count <= 2_000_000 else {
      cancel(error: CoveError.message("ChatGPT returned too much data. Try a shorter request."))
      return
    }
    while let index = buffer.firstIndex(of: 10) {
      let line = buffer.prefix(upTo: index)
      buffer.removeSubrange(...index)
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
        if object["error"] != nil {
          continuation.resume(
            throwing: CoveError.message(
              Self.failureMessage(object["error"], fallback: "Codex could not complete the request. Check your connection and model access.")))
        } else {
          continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
        }
        continue
      }
      // Never approve tool execution, dynamic tools, OAuth-token requests, or permissions.
      if let id = object["id"], object["method"] != nil {
        try? send([
          "id": id,
          "error": ["code": -32601, "message": "Cove does not allow tools or permissions."],
        ])
        continue
      }
      let params = object["params"] as? [String: Any] ?? [:]
      switch object["method"] as? String {
      case "account/login/completed":
        connected = params["success"] as? Bool == true
        status = connected ? "Connected with ChatGPT" : "Sign-in did not complete"
      case "item/agentMessage/delta":
        if params["threadId"] as? String == activeThread, let delta = params["delta"] as? String, streamed.count < 32_000 {
          streamed += delta
          onPartial?(streamed)
        }
      case "item/completed":
        if params["threadId"] as? String == activeThread,
          let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
          let text = item["text"] as? String
        {
          output += String(text.prefix(max(0, 32_000 - output.count)))
        }
      case "turn/completed":
        if params["threadId"] as? String == activeThread {
          let state = (params["turn"] as? [String: Any])?["status"] as? String
          if state == "completed", !output.isEmpty {
            finish(.success(output))
          } else {
            finish(
              .failure(
                CoveError.message(
                  Self.failureMessage((params["turn"] as? [String: Any])?["error"],
                    fallback: "ChatGPT did not return an answer. Check your subscription limits or retry."))))
          }
        }
      default: break
      }
    }
  }
}
