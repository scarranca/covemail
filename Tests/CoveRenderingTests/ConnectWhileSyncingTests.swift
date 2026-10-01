import XCTest
@testable import Cove
@testable import CoveCore

/// Connecting Calendar or Tasks during a sync used to be silently ignored; now it waits for the sync.
@MainActor final class ConnectWhileSyncingTests: XCTestCase {
  func testWaitsForTheSyncThenContinuesAndGivesUpWhenItNeverEnds() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "t" }, syncClock: Date.init)
    store.busy = true
    Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); store.busy = false }
    let started = ContinuousClock.now
    let ready = await store.waitUntilIdle(timeout: .seconds(5))
    XCTAssertTrue(ready)
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(350), "it waited for the sync")
    store.busy = true
    let gaveUp = await store.waitUntilIdle(timeout: .milliseconds(300))
    XCTAssertFalse(gaveUp, "a sync that never ends doesn't connect later by surprise")
  }
}
