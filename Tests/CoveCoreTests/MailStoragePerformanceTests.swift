import XCTest

@testable import CoveCore

/// Opt-in timing check (COVE_PERF=1), ideally with `-c release -Xswiftc -enable-testing`.
final class MailStoragePerformanceTests: XCTestCase {
  func testThirtyThousandEncryptedEmails() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["COVE_PERF"] == "1")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("perf.sqlite")
    let key = Data(repeating: 7, count: 32)
    let now = Date()
    let body = String(repeating: "Quarterly planning notes and follow-ups. ", count: 50)
    var mails = (0..<30_000).map { index -> Mail in
      var mail = Samples.mail[0]
      mail.id = "m\(index)"
      mail.threadID = "t\(index / 3)"
      mail.body = body + String(index)
      mail.date = now.addingTimeInterval(-Double(index) * 1_050)  // spans about a year
      return mail
    }
    func time(_ label: String, _ work: () throws -> Void) rethrows -> Double {
      let start = Date()
      try work()
      let ms = Date().timeIntervalSince(start) * 1000
      print("[perf] \(label): \(Int(ms)) ms")
      return ms
    }
    let db = try Database(url: url, encryptionKey: key, namespace: "perf")
    _ = try time("initial save of 30,000") { try db.saveMailSnapshot(mails) }
    mails[10].labels.remove("UNREAD")
    let incremental = try time("snapshot with one change") { try db.saveMailSnapshot(mails) }
    let reopened = try Database(url: url, encryptionKey: key, namespace: "perf")
    var recent: [Mail] = []
    let window = try time("load 90-day window") {
      recent = try reopened.loadMail(since: now.addingTimeInterval(-90 * 86_400))
    }
    var all: [Mail] = []
    _ = try time("load all 30,000") { all = try reopened.loadMail() }
    XCTAssertEqual(all.count, 30_000)
    XCTAssertGreaterThan(recent.count, 7_000)
    XCTAssertLessThan(incremental, 50)
    XCTAssertLessThan(window, 200)
  }
}
