import XCTest

@testable import CoveCore

final class InboxSplitTests: XCTestCase {
  private func mail(
    _ id: String = "m", from address: String = "maya@example.com", bulk: Bool? = false,
    category: MailCategory? = nil, needsReply: Double = 0, urgent: Double = 0, labels: Set<String> = ["INBOX", "UNREAD"]
  ) -> Mail {
    Mail(id: id, sender: "Maya", senderEmail: address, subject: "Hello", body: "Body", labels: labels,
      decision: category.map { Decision(category: $0, confidence: 0.9, needsReply: needsReply, urgent: urgent, model: "t") },
      isBulkOrAutomated: bulk)
  }

  func testMembershipRulesAreDeterministicAndExplained() {
    XCTAssertEqual(InboxSplit.classify(mail()).split, .important)
    XCTAssertEqual(InboxSplit.classify(mail()).reason, .standard)
    // Older snapshots without the header signal are not guessed into Other.
    XCTAssertEqual(InboxSplit.classify(mail(bulk: nil)).split, .important)
    XCTAssertEqual(InboxSplit.classify(mail(bulk: true)).reason, .bulkHeaders)
    XCTAssertEqual(InboxSplit.classify(mail(bulk: true)).split, .other)
    for sender in ["no-reply@shop.com", "Notifications <notifications@github.com>", "NOREPLY@bank.com", "newsletter@x.io"] {
      XCTAssertEqual(InboxSplit.classify(mail(from: sender)).split, .other, sender)
      XCTAssertEqual(InboxSplit.classify(mail(from: sender)).reason, .notificationSender, sender)
    }
    for category in [MailCategory.newsletters, .updates, .purchases] {
      XCTAssertEqual(InboxSplit.classify(mail(category: category)).reason, .jevCategory)
      XCTAssertEqual(InboxSplit.split(mail(category: category)), .other)
    }
    for category in [MailCategory.people, .work, .other] {
      XCTAssertEqual(InboxSplit.split(mail(category: category)), .important)
    }
    // Jev priority keeps an automated but actionable email in Important.
    XCTAssertEqual(InboxSplit.classify(mail(bulk: true, category: .updates, urgent: 0.9)).reason, .jevPriority)
    XCTAssertEqual(InboxSplit.split(mail(bulk: true, category: .updates, needsReply: 0.7)), .important)
    // Gmail's own IMPORTANT label alone does not rescue a newsletter.
    XCTAssertEqual(InboxSplit.split(mail(bulk: true, labels: ["INBOX", "IMPORTANT"])), .other)
    XCTAssertFalse(InboxSplit.Reason.bulkHeaders.explanation.isEmpty)
  }

  func testVotesAndSenderRulesWinInThatOrder() {
    var newsletter = mail(bulk: true, category: .newsletters)
    let rules: [String: InboxSplit] = ["maya@example.com": .important]
    XCTAssertEqual(InboxSplit.classify(newsletter, senderRules: rules).reason, .senderRule)
    XCTAssertEqual(InboxSplit.split(newsletter, senderRules: rules), .important)
    XCTAssertEqual(InboxSplit.split(mail(needsReply: 0.9), senderRules: ["maya@example.com": .other]), .other)
    newsletter.inboxVote = .other
    XCTAssertEqual(InboxSplit.classify(newsletter, senderRules: rules).reason, .vote)
    XCTAssertEqual(InboxSplit.split(newsletter, senderRules: rules), .other)
    XCTAssertEqual(InboxSplit.senderKey(" Maya <MAYA@Example.com> "), "maya@example.com")
  }

  func testVoteSurvivesSyncMergesForLiveAndStoredEmails() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    var live = mail("live", bulk: true)
    live.inboxVote = .important
    var stored = mail("stored", labels: ["CATEGORY_UPDATES"])
    stored.date = Date().addingTimeInterval(-400 * 86_400)
    stored.inboxVote = .other
    try database.storeArchived([stored])
    try database.saveMailSnapshot([live])

    var refetchedLive = live
    refetchedLive.inboxVote = nil
    refetchedLive.body = "Re-decoded"
    var refetchedStored = stored
    refetchedStored.inboxVote = nil
    refetchedStored.labels = ["INBOX"]
    let merged = try GmailSyncResult(messages: [refetchedLive, refetchedStored], historyID: "2")
      .merging(into: [live], store: database)
    XCTAssertEqual(merged.first { $0.id == "live" }?.inboxVote, .important)
    XCTAssertEqual(merged.first { $0.id == "live" }?.body, "Re-decoded")
    XCTAssertEqual(merged.first { $0.id == "stored" }?.inboxVote, .other)
    // The vote is part of the encrypted local record, so a reload keeps it.
    try database.saveMailSnapshot(merged)
    XCTAssertEqual(try database.loadMessages(ids: ["live"]).first?.inboxVote, .important)
  }

  func testPreferencesDecodeWithoutSplitFieldsAndDefaultToSplit() throws {
    let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"voice":"Warm","signoff":"Best,","instructions":[],"memories":[],"useMemories":true,"autoClassify":false}"#.utf8))
    XCTAssertTrue(old.splitsInbox)
    XCTAssertNil(old.inboxSenderRules)
    var prefs = Preferences()
    prefs.inboxSenderRules = ["a@b.com": .other]
    prefs.splitInbox = false
    let round = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
    XCTAssertFalse(round.splitsInbox)
    XCTAssertEqual(round.inboxSenderRules, ["a@b.com": .other])
  }
}
