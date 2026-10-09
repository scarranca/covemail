import Foundation
import XCTest
@testable import CoveCore

/// What typing in To costs locally: building the directory from a realistic mailbox, then ranking it
/// once per keystroke. Printed timings are what the audit quotes; the bounds only catch order-of-magnitude
/// regressions.
final class RecipientSuggestionBenchmarkTests: XCTestCase {
  static func mailbox(_ count: Int, people: Int) -> [Mail] {
    let first = ["Ana", "José", "Mariana", "Santiago", "Lucía", "Peter", "Sarah", "Chen", "Olivia", "Mateo", "Zoë", "Ravi"]
    let last = ["García", "Smith", "Núñez", "Okafor", "Müller", "Rossi", "Tanaka", "Silva", "Brown", "López"]
    return (0..<count).map { index in
      let person = index % people
      let name = "\(first[person % first.count]) \(last[(person / first.count) % last.count]) \(person)"
      let email = "person\(person)@company\(person % 40).com"
      return Mail(id: "m\(index)", sender: name, senderEmail: email, subject: "Subject \(index)", body: "Body",
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 90),
        labels: ["INBOX"], isBulkOrAutomated: false)
    }
  }

  /// The ranking as it was before the index (folding each contact per call), to check the index agrees.
  static func unindexed(_ text: String, _ local: [MailContact], limit: Int = 6) -> [MailContact] {
    let query = MailSearchIndex.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    func rank(_ contact: MailContact) -> Int? {
      let name = MailSearchIndex.fold(contact.name), email = MailSearchIndex.fold(contact.email)
      guard terms.allSatisfy({ name.contains($0) || email.contains($0) }) else { return nil }
      if name.hasPrefix(query) || email.hasPrefix(query) { return 0 }
      if name.split(separator: " ").contains(where: { $0.hasPrefix(terms.first ?? "") }) { return 1 }
      return 2
    }
    // A stable sort, as the index's buckets are, so equal ranks keep the directory's tie order.
    let ordered = local.sorted { lhs, rhs in
      if lhs.messages.count != rhs.messages.count { return lhs.messages.count > rhs.messages.count }
      return (lhs.lastMessage ?? .distantPast) > (rhs.lastMessage ?? .distantPast)
    }
    var buckets: [[MailContact]] = [[], [], []]
    for contact in ordered { if let value = rank(contact) { buckets[value].append(contact) } }
    let ranked: [MailContact] = buckets[0] + buckets[1] + buckets[2]
    return Array(ranked.prefix(limit))
  }

  func testDirectoryBuildAndPerKeystrokeRanking() {
    let mails = Self.mailbox(4_000, people: 1_500)
    var started = Date()
    let directory = ContactDirectory.build(mails: mails, records: [], accountEmail: "me@example.com")
    print("BENCH build directory (4,000 emails, \(directory.count) people): \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    XCTAssertEqual(directory.count, 1_500)

    let typed = ["s", "sa", "san", "sant", "santi", "santia", "santiag", "santiago"]
    started = Date()
    var last: [MailContact] = []
    for query in typed { last = Self.unindexed(query, directory) }
    let perKey = Date().timeIntervalSince(started) * 1000 / Double(typed.count)
    print("BENCH unindexed suggestions per keystroke (\(directory.count) people): \(String(format: "%.1f", perKey)) ms")
    XCTAssertEqual(last.count, 6)
    XCTAssertTrue(last.allSatisfy { $0.name.hasPrefix("Santiago") })
    XCTAssertLessThan(perKey, 2_000)

    // The index folds the directory once; each keystroke then compares bytes.
    started = Date()
    let index = ContactSearchIndex(directory)
    print("BENCH build search index (\(index.count) people): \(String(format: "%.1f", Date().timeIntervalSince(started) * 1000)) ms")
    started = Date()
    var indexed: [MailContact] = []
    for query in typed { indexed = index.suggestions(query, limit: 6) }
    let indexedPerKey = Date().timeIntervalSince(started) * 1000 / Double(typed.count)
    print("BENCH indexed suggestions per keystroke (\(index.count) people): \(String(format: "%.2f", indexedPerKey)) ms")
    XCTAssertEqual(indexed.map(\.email), last.map(\.email))
    for query in ["a", "ana", "garcia", "nunez", "zoe", "company3", "ravi lopez", "x y z", "MÜLLER"] {
      XCTAssertEqual(index.suggestions(query, limit: 6).map(\.email),
        Self.unindexed(query, directory).map(\.email), query)
    }

    // The composer also shows the four most recent people while To is empty.
    started = Date()
    for _ in 0..<10 { _ = Array(directory.sorted { ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }.prefix(4)) }
    print("BENCH empty-To recent people: \(String(format: "%.1f", Date().timeIntervalSince(started) * 100)) ms")
  }
}
