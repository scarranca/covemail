import CoveCore
import Foundation
import XCTest

@testable import Cove

@MainActor final class ChatGPTConnectionTests: XCTestCase {
  func testOfficialProtocolLifecycleWithIsolatedHelperFixture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = #"""
      #!/bin/sh
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        case "$line" in
          *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"test"}}\n' "$id" ;;
          *'"method":"account/read"'*) printf '{"id":%s,"result":{"account":{"type":"chatgpt"}}}\n' "$id" ;;
          *'"method":"model/list"'*)
            case "$line" in
              *'"cursor":"page-two"'*) printf '{"id":%s,"result":{"data":[{"model":"gpt-6-sol"},{"model":"fixture-model"},{"model":"hidden-model","hidden":true}],"nextCursor":null}}\n' "$id" ;;
              *) printf '{"id":%s,"result":{"data":[{"model":"fixture-model"}],"nextCursor":"page-two"}}\n' "$id" ;;
            esac ;;
          *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"fixture-thread"}}}\n' "$id" ;;
          *'"method":"turn/start"'*)
            printf '{"id":%s,"result":{"turn":{"id":"fixture-turn"}}}\n' "$id"
            printf '{"method":"item/completed","params":{"threadId":"fixture-thread","item":{"type":"agentMessage","text":"Fixture draft"}}}\n'
            printf '{"method":"turn/completed","params":{"threadId":"fixture-thread","turn":{"status":"completed"}}}\n' ;;
          *'"method":"account/logout"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
        esac
      done
      """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = ChatGPTConnection(runtimeDirectory: directory, executable: executable.path)
    defer { connection.shutdown() }
    try await connection.refresh()
    XCTAssertTrue(connection.connected)
    let models = try await connection.models()
    XCTAssertEqual(models, ["fixture-model", "gpt-6-sol"])
    let text = try await connection.complete(
      model: "fixture-model", prompt: AIPrompt(intent: .write, instruction: "Say hello", mails: []))
    XCTAssertEqual(text, "Fixture draft")
    try await connection.logout()
    XCTAssertFalse(connection.connected)
  }
  func testDraftStreamsAndAccountCheckIsReusedBetweenRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let log = directory.appendingPathComponent("account-checks")
    let script = #"""
      #!/bin/sh
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        case "$line" in
          *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"test"}}\n' "$id" ;;
          *'"method":"account/read"'*) printf 'x' >> "$COVE_TEST_LOG"; printf '{"id":%s,"result":{"account":{"type":"chatgpt"}}}\n' "$id" ;;
          *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"fixture-thread"}}}\n' "$id" ;;
          *'"method":"turn/start"'*)
            printf '{"id":%s,"result":{"turn":{"id":"fixture-turn"}}}\n' "$id"
            printf '{"method":"item/agentMessage/delta","params":{"threadId":"fixture-thread","turnId":"fixture-turn","itemId":"i","delta":"Hola "}}\n'
            printf '{"method":"item/agentMessage/delta","params":{"threadId":"fixture-thread","turnId":"fixture-turn","itemId":"i","delta":"Jerjes"}}\n'
            printf '{"method":"item/completed","params":{"threadId":"fixture-thread","item":{"type":"agentMessage","text":"Hola Jerjes"}}}\n'
            printf '{"method":"turn/completed","params":{"threadId":"fixture-thread","turn":{"status":"completed"}}}\n' ;;
        esac
      done
      """#.replacingOccurrences(of: "$COVE_TEST_LOG", with: log.path)
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = ChatGPTConnection(runtimeDirectory: directory, executable: executable.path)
    defer { connection.shutdown() }
    var partials: [String] = []
    let text = try await connection.complete(model: "fixture-model",
      prompt: AIPrompt(intent: .write, instruction: "Say hello", mails: []), onPartial: { partials.append($0) })
    XCTAssertEqual(text, "Hola Jerjes")
    XCTAssertEqual(partials, ["Hola ", "Hola Jerjes"])
    _ = try await connection.complete(model: "fixture-model", prompt: AIPrompt(intent: .write, instruction: "Again", mails: []))
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "x", "one account check serves back-to-back requests")
  }

  func testRepeatedModelCursorFailsInsteadOfLoopingOrReturningPartialCatalog() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = #"""
      #!/bin/sh
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        case "$line" in
          *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
          *'"method":"account/read"'*) printf '{"id":%s,"result":{"account":{"type":"chatgpt"}}}\n' "$id" ;;
          *'"method":"model/list"'*) printf '{"id":%s,"result":{"data":[{"model":"fixture-model"}],"nextCursor":"same-page"}}\n' "$id" ;;
        esac
      done
      """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = ChatGPTConnection(runtimeDirectory: directory, executable: executable.path)
    defer { connection.shutdown() }
    do {
      _ = try await connection.models()
      XCTFail("Expected repeated cursor failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("repeated a model-list page"))
    }
  }

  func testMissingHelperFailsBeforeLaunching() async {
    let connection = ChatGPTConnection(executable: "/missing-cove-codex-fixture")
    do {
      try await connection.refresh()
      XCTFail("Expected missing executable error")
    } catch { XCTAssertTrue(error.localizedDescription.contains("official Codex")) }
    XCTAssertFalse(connection.connected)
  }
  func testModelRejectionAndTimeoutReturnActionableErrors() async throws {
    for mode in ["rpc", "turn", "timeout"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let executable = directory.appendingPathComponent("fake-codex")
      let threadReply = mode == "rpc"
        ? #"printf '{"id":%s,"error":{"message":"The selected model is not available for this account."}}\n' "$id""#
        : #"printf '{"id":%s,"result":{"thread":{"id":"fixture"}}}\n' "$id""#
      let turnReply = mode == "turn"
        ? #"printf '{"method":"turn/completed","params":{"threadId":"fixture","turn":{"status":"failed","error":{"message":"Usage limit reached. Try again later."}}}}\n'"# : ":"
      let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'"method":"account/read"'*) printf '{"id":%s,"result":{"account":{"type":"chatgpt"}}}\n' "$id" ;;
            *'"method":"thread/start"'*) \#(threadReply) ;;
            *'"method":"turn/start"'*) printf '{"id":%s,"result":{}}\n' "$id"; \#(turnReply) ;;
          esac
        done
        """#
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let connection = ChatGPTConnection(runtimeDirectory: directory, executable: executable.path,
        responseTimeout: .milliseconds(150))
      defer { connection.shutdown() }
      do {
        _ = try await connection.complete(model: "gpt-6-sol", prompt: AIPrompt(intent: .write, instruction: "Hello", mails: []))
        XCTFail("Expected failure for \(mode)")
      } catch {
        let expected = mode == "rpc" ? "not available" : mode == "turn" ? "Usage limit" : "too long"
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
        XCTAssertFalse(error is CancellationError, "A provider failure must not masquerade as user cancellation")
      }
      if mode == "timeout" {
        try await connection.refresh()
        XCTAssertTrue(connection.connected, "An immediate retry can reconnect after timeout")
      }
    }
  }

}
