import AppKit
import CoveCore
import Foundation
import Darwin
import Observation
import Security

/// Runs the unmodified, locally installed Claude Code CLI. Authentication belongs to the CLI;
/// Cove never reads, stores, or forwards its OAuth credentials.
@MainActor @Observable final class ClaudeConnection {
  static let shared = ClaudeConnection()
  typealias Runner = @MainActor ([String], String?, Duration) async throws -> ClaudeProcess.Result
  private let runtimeOverride: URL?
  private let executableOverride: String?
  private let runner: Runner?
  private let defaults: UserDefaults
  private(set) var connected = false
  /// True once a sign-in check has finished (either way) this launch.
  private(set) var checked = false
  private(set) var status = "Not connected"
  private var working = false
  private(set) var modelOptions: [ClaudeModelOption] = []

  init(runtimeDirectory: URL? = nil, executable: String? = nil,
       defaults: UserDefaults = .standard, runner: Runner? = nil) {
    runtimeOverride = runtimeDirectory
    executableOverride = executable
    self.defaults = defaults
    self.runner = runner
  }
  var executablePath: String {
    get {
      executableOverride ?? defaults.string(forKey: "ai.claudePath") ?? [
        FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude",
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
      ].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    set {
      defaults.set(newValue, forKey: "ai.claudePath")
      connected = false
      status = "Installation changed. Check the connection to continue."
    }
  }
  private var directory: URL {
    runtimeOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(CoveRuntime.isQA ? "Cove-QA/Claude" : "Cove/Claude", isDirectory: true)
  }
  func refresh() async throws {
    // A catalog refresh during generation must not invalidate the signed-in provider.
    guard !working else { throw CoveError.message("Claude is handling another request. Check again when it finishes.") }
    defer { if !Task.isCancelled { checked = true } }
    let result: ClaudeProcess.Result
    do { result = try await execute(["auth", "status", "--json"], timeout: .seconds(30)) }
    catch {
      connected = false
      status = error is CancellationError ? "Connection check cancelled" : error.localizedDescription
      throw error
    }
    guard let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
          let loggedIn = object["loggedIn"] as? Bool else {
      connected = false
      status = "Couldn’t check the connection. Update the official Claude Code CLI and try again."
      throw CoveError.message(status)
    }
    connected = result.code == 0 && loggedIn && object["authMethod"] as? String == "claude.ai"
    status = connected ? "Connected with your Claude account" : "No Claude subscription sign-in found"
  }
  func login() async throws {
    status = "Finish signing in through Claude Code in your browser"
    do {
      // Keep Anthropic's own authentication flow intact. No OAuth URL/token interception.
      let result = try await execute(["auth", "login"], timeout: .seconds(300))
      guard result.code == 0 else {
        throw CoveError.message("Claude sign-in did not finish. Try again, then complete the browser sign-in.")
      }
      try await refresh()
      guard connected else { throw CoveError.message("Choose your Claude subscription in the official sign-in flow. For an API key, select Anthropic in Cove.") }
    } catch {
      status = error is CancellationError ? "Sign-in cancelled" : error.localizedDescription
      throw error
    }
  }
  func logout() async throws {
    let result = try await execute(["auth", "logout"], timeout: .seconds(30))
    guard result.code == 0 else { throw CoveError.message("Couldn’t disconnect Claude. Try again.") }
    connected = false
    status = "Disconnected"
  }
  func models() async throws -> [String] {
    try await refresh()
    guard connected else { throw CoveError.message("Connect your Claude subscription in Integrations first.") }
    let result = try await execute(Self.modelArguments, input: Self.modelRequest, timeout: .seconds(45))
    guard result.code == 0 else { throw CoveError.message("Couldn’t load Claude models. Refresh or update Claude Code in connection options.") }
    let options = try ClaudeModelOption.parse(result.output)
    modelOptions = options
    return options.map(\.id)
  }
  static let modelRequest = #"{"type":"control_request","request_id":"cove-models","request":{"subtype":"initialize"}}"# + "\n"
  static var modelArguments: [String] {
    ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] + restrictedArguments
  }
  private static let restrictedArguments = ["--safe-mode", "--tools", "", "--strict-mcp-config",
    "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--permission-mode", "dontAsk",
    "--no-session-persistence", "--debug-file", "/dev/null", "--disable-slash-commands"]

  func modelLabel(_ id: String) -> String {
    if let option = modelOptions.first(where: { $0.id == id }) { return option.label }
    if ["sonnet", "opus", "haiku", "fable"].contains(id),
       let option = modelOptions.first(where: { $0.resolvedID?.hasPrefix("claude-" + id + "-") == true }) {
      return "Automatic · " + option.name
    }
    return id == "default" ? "Automatic · account default" : ClaudeModelOption.displayName(id)
  }
  static func arguments(model: String, prompt: AIPrompt) throws -> [String] {
    guard !model.isEmpty, model.count <= 200, !model.hasPrefix("-"),
          !model.contains(where: \.isWhitespace) else {
      throw CoveError.message("Choose a valid Claude model in Integrations.")
    }
    var arguments = ["--print", "--output-format", "json"] + restrictedArguments
      + ["--append-system-prompt", prompt.system]
    if model != "default" { arguments += ["--model", model] }
    return arguments
  }
  func complete(model: String, prompt: AIPrompt) async throws -> String {
    let arguments = try Self.arguments(model: model, prompt: prompt)
    try await refresh()
    guard connected else { throw CoveError.message("Reconnect your Claude subscription in Integrations.") }
    let result = try await execute(arguments, input: prompt.dataMessage + "\n\n" + prompt.user, timeout: .seconds(120))
    guard let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] else {
      throw CoveError.message("Claude returned an unreadable response. Update the official Claude Code CLI and try again.")
    }
    guard result.code == 0, object["is_error"] as? Bool == false else {
      // Do not echo helper output: errors can contain request text or authentication URLs.
      throw CoveError.message("Claude couldn’t complete this request. Check your plan’s usage limit and model access, or reconnect in Integrations. Your draft is unchanged.")
    }
    guard let text = object["result"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoveError.message("Claude returned no text. Try a shorter request or another model.")
    }
    return String(text.prefix(32_000))
  }
  private func execute(_ arguments: [String], input: String? = nil, timeout: Duration) async throws -> ClaudeProcess.Result {
    guard !working else { throw CoveError.message("Claude is handling another request. Try again when it finishes.") }
    working = true
    defer { working = false }
    try Task.checkCancellation()
    if let runner { return try await runner(arguments, input, timeout) }
    guard !executablePath.isEmpty, FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw CoveError.message("Install the official Claude Code CLI, then select it in Integrations.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let binary = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
    let profile = try ClaudeSandbox.profile(runtime: directory.path, executable: binary,
      keychain: runtimeOverride == nil ? Self.keychainPath() : nil)
    let environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "CLAUDE_CONFIG_DIR": directory.path, "TMPDIR": temporary.path, "CLAUDE_CODE_TMPDIR": temporary.path,
      "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
    ]
    return try await ClaudeProcess().run(executable: "/usr/bin/sandbox-exec",
      arguments: ["-p", profile, binary] + arguments, directory: directory,
      environment: environment, input: input, timeout: timeout)
  }
  private static func keychainPath() throws -> String {
    var keychain: SecKeychain?
    guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else {
      throw CoveError.message("Unlock your login keychain in Keychain Access, then try Claude again.")
    }
    var length: UInt32 = 4096
    var path = [CChar](repeating: 0, count: Int(length))
    guard SecKeychainGetPath(keychain, &length, &path) == errSecSuccess else {
      throw CoveError.message("macOS couldn’t locate your login keychain.")
    }
    return String(cString: path)
  }
}

/// Bounded in-memory I/O; no prompt/output files or shell command interpolation.
@MainActor final class ClaudeProcess {
  struct Result { let code: Int32; let output: Data }
  private var process: Process?
  func run(executable: String, arguments: [String], directory: URL,
           environment: [String: String], input: String?, timeout: Duration, captureDiagnostics: Bool = false) async throws -> Result {
    let worker = Process(), stdout = Pipe(), stdin = Pipe()
    worker.executableURL = URL(fileURLWithPath: executable)
    worker.arguments = arguments
    worker.currentDirectoryURL = directory
    worker.environment = environment
    worker.standardOutput = stdout
    worker.standardError = captureDiagnostics ? stdout : FileHandle.nullDevice
    worker.standardInput = stdin
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let output = ClaudeOutputBuffer()
    stdout.fileHandleForReading.readabilityHandler = { handle in
      output.append(handle.availableData)
    }
    try worker.run()
    process = worker
    defer {
      stdout.fileHandleForReading.readabilityHandler = nil
      try? stdout.fileHandleForReading.close()
      if worker.isRunning { worker.terminate() }
      process = nil
    }
    // Writing on a worker thread avoids blocking SwiftUI when the prompt exceeds pipe capacity.
    let writer = Task.detached {
      if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
      try? stdin.fileHandleForWriting.close()
    }
    defer { writer.cancel() }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    do {
      while worker.isRunning || !output.finished {
        guard !output.tooLarge else { throw CoveError.message("Claude returned too much data. Try a shorter request.") }
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline {
          throw CoveError.message("Claude took too long to respond. Try again or check the connection in Integrations.")
        }
        try await Task.sleep(for: .milliseconds(30))
      }
      try Task.checkCancellation()
      guard !output.tooLarge else { throw CoveError.message("Claude returned too much data. Try a shorter request.") }
      return Result(code: worker.terminationStatus, output: output.data)
    } catch {
      if worker.isRunning {
        worker.terminate()
        // Ensure a stuck helper does not retain a live authenticated process after cancellation.
        let pid = worker.processIdentifier
        Task { try? await Task.sleep(for: .seconds(1)); if worker.isRunning { kill(pid, SIGKILL) } }
      }
      throw error
    }
  }
}

/// Bound data at the pipe reader, before scheduling onto the UI actor.
private final class ClaudeOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var eof = false
  private var overflow = false
  func append(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    if data.isEmpty { eof = true; return }
    guard !overflow else { return }
    if bytes.count + data.count > 2_000_000 { overflow = true; return }
    bytes.append(data)
  }
  var finished: Bool { lock.lock(); defer { lock.unlock() }; return eof }
  var tooLarge: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
  var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
