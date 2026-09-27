import Foundation
import XCTest
@testable import CoveCore

final class CloudSnoozeStateTests: XCTestCase {
  private func mail(_ id: String = "abc") -> Mail {
    Mail(id: id, threadID: "thread", sender: "Fixture", senderEmail: "fixture@example.com", subject: "Fixture", body: "Body")
  }
  func testReplayAcknowledgementCannotReplaceNewerServerCancellation() throws {
    var state = CloudSnoozeState()
    state.set(mail(), until: Date().addingTimeInterval(3600))
    let upload = try XCTUnwrap(state.beginUpload())
    state.records["abc"] = CloudSnooze(id: "abc", threadID: "thread", wakeAt: nil, revision: "2")
    state.acknowledge(upload, revision: "1")
    XCTAssertEqual(state.records["abc"]?.revision, "2")
    XCTAssertNil(state.applying(to: mail()).snoozedUntil)
    XCTAssertTrue(state.pending.isEmpty)
  }
  func testConnectionGenerationResetsCursorsAndFrozenRequestsButPreservesLocalIntent() throws {
    var state = CloudSnoozeState(); state.connect(UUID())
    state.set(mail(), until: Date().addingTimeInterval(3600))
    let upload = try XCTUnwrap(state.beginUpload())
    state.cursor = "12"
    state.records["def"] = CloudSnooze(id: "def", threadID: "other", wakeAt: nil, revision: "12")
    let replacement = UUID(); state.connect(replacement)
    XCTAssertEqual(state.accountID, replacement)
    XCTAssertEqual(state.cursor, "0"); XCTAssertTrue(state.records.isEmpty); XCTAssertNil(state.uploading)
    XCTAssertNotEqual(state.pending["abc"]?.requestID, upload.intent.requestID)
    XCTAssertEqual(state.pending["abc"]?.wakeAt, upload.intent.wakeAt)
  }
  func testLegacyBootstrapOnlySeedsFutureEligibleSnoozesAndRespectsServerCancellation() {
    var state = CloudSnoozeState()
    var active = mail(); active.snoozedUntil = Date().addingTimeInterval(3600); active.date = Date().addingTimeInterval(-90 * 86400)
    var expired = mail("def"); expired.snoozedUntil = Date().addingTimeInterval(-3600)
    var spam = active; spam.id = "fed"; spam.labels = ["SPAM"]
    state.seed([active, expired, spam])
    XCTAssertEqual(Set(state.pending.keys), ["abc"])
    state.pending = [:]
    state.records["abc"] = CloudSnooze(id: "abc", threadID: "thread", wakeAt: nil, revision: "1")
    state.seed([active]); XCTAssertTrue(state.pending.isEmpty)
  }
  func testConfirmedGmailDeletionQueuesCancellationWithoutCancellingOtherMail() {
    var state = CloudSnoozeState()
    state.records["abc"] = CloudSnooze(id: "abc", threadID: "thread", wakeAt: "2030-01-01T09:00:00.000Z", revision: "1")
    state.records["def"] = CloudSnooze(id: "def", threadID: "other", wakeAt: "2030-01-01T09:00:00Z", revision: "2")
    state.cancelDeleted(["abc", "unknown"])
    XCTAssertEqual(Set(state.pending.keys), ["abc"])
    XCTAssertNil(state.pending["abc"]?.wakeAt)
    XCTAssertNotNil(state.records["def"]?.until)
  }
}
