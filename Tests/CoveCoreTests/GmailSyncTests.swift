import XCTest

@testable import CoveCore

final class GmailSyncTests: XCTestCase {
  private func cached(_ id: String) -> Mail {
    Mail(
      id: id, sender: "Sender", senderEmail: "sender@example.com", subject: "Review",
      body: "Original")
  }

  func testPaginatedHistoryRefreshesTrashSpamAndDeletesOnlyConfirmedIDs() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "history":
        XCTAssertEqual(request.query("startHistoryId"), "100")
        if request.query("pageToken") == "second" {
          return (
            200,
            [
              "historyId": "110",
              "history": [
                [
                  "labelsAdded": [["message": ["id": "spam"]]],
                  "messagesDeleted": [["message": ["id": "deleted"]]],
                ]
              ],
            ]
          )
        }
        return (
          200,
          [
            "historyId": "110", "nextPageToken": "second",
            "history": [
              [
                "labelsAdded": [["message": ["id": "trashed"]]],
                "messagesAdded": [["message": ["id": "new"]]],
              ]
            ],
          ]
        )
      case "trashed":
        XCTAssertEqual(request.query("format"), "minimal")
        return (200, ["labelIds": ["TRASH"]])
      case "spam":
        XCTAssertEqual(request.query("format"), "minimal")
        return (200, ["labelIds": ["SPAM"]])
      case "new":
        XCTAssertEqual(request.query("format"), "full")
        return (200, ["id": "new", "threadId": "new-thread", "labelIds": ["INBOX"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    var trashed = cached("trashed")
    trashed.draft = "Unsent reply"
    trashed.decision = Samples.mail[0].decision
    trashed.snoozedUntil = Date(timeIntervalSince1970: 2_000_000_000)
    let existing = [trashed, cached("spam"), cached("deleted"), cached("unchanged")]
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: existing, historyID: "100")
    let applied = result.applying(to: existing)
    XCTAssertEqual(result.historyID, "110")
    XCTAssertFalse(result.resetsPagination)
    XCTAssertEqual(Set(applied.map(\.id)), ["trashed", "spam", "unchanged", "new"])
    let updated = try XCTUnwrap(applied.first { $0.id == "trashed" })
    XCTAssertEqual(updated.labels, ["TRASH"])
    XCTAssertEqual(updated.draft, trashed.draft)
    XCTAssertEqual(updated.decision, trashed.decision)
    XCTAssertEqual(updated.snoozedUntil, trashed.snoozedUntil)
    XCTAssertEqual(applied.first { $0.id == "spam" }?.labels, ["SPAM"])
    XCTAssertEqual(applied.first { $0.id == "unchanged" }, existing.first { $0.id == "unchanged" })
  }

  func testDeletedSourceRecoversLatestLocalReplyAsDraft() async throws {
    let transport = SyncFixtureHTTP { _ in
      (
        200,
        ["historyId": "101", "history": [["messagesDeleted": [["message": ["id": "deleted"]]]]]]
      )
    }
    let original = cached("deleted")
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: [original], historyID: "100")
    var changedWhileSyncing = original
    changedWhileSyncing.draft = "Draft typed while the request was in flight"
    changedWhileSyncing.replyTo = "Support <support@example.com>"
    let recovered = try XCTUnwrap(result.applying(to: [changedWhileSyncing]).first)
    XCTAssertEqual(recovered.id, "local-recovered-deleted")
    XCTAssertEqual(recovered.labels, ["DRAFT"])
    XCTAssertEqual(recovered.to, "Support <support@example.com>")
    XCTAssertEqual(recovered.subject, "Re: Review")
    XCTAssertEqual(recovered.body, changedWhileSyncing.draft)
    XCTAssertEqual(result.applying(to: [recovered]), [recovered])
  }

  func testMissingHistoryRetainsOlderMailAndRefreshesItsMetadata() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "profile": return (200, ["historyId": "baseline"])
      case "messages":
        return (200, ["messages": [["id": "latest"]], "nextPageToken": "older-page"])
      case "latest":
        return (200, ["id": "latest", "threadId": "latest-thread", "labelIds": ["INBOX"]])
      case "older":
        XCTAssertEqual(request.query("format"), "minimal")
        return (200, ["labelIds": ["STARRED"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    var local = cached("local-draft")
    local.labels = ["DRAFT"]
    let existing = [cached("older"), local]
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: existing, historyID: nil)
    let applied = result.applying(to: existing)
    XCTAssertEqual(Set(applied.map(\.id)), ["older", "local-draft", "latest"])
    XCTAssertEqual(applied.first { $0.id == "older" }?.labels, ["STARRED"])
    XCTAssertEqual(applied.first { $0.id == "older" }?.body, "Original")
    XCTAssertEqual(applied.first { $0.id == "local-draft" }, local)
    XCTAssertEqual(result.nextPage, "older-page")
    XCTAssertTrue(result.resetsPagination)
    XCTAssertEqual(result.historyID, "baseline")
    let paths = await transport.paths()
    XCTAssertEqual(Array(paths.prefix(2)), ["profile", "messages"])
  }

  func testExpiredHistoryFallsBackToBaselineBeforeListingAndReconciles404() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "history": return (404, [:])
      case "profile": return (200, ["historyId": "new-baseline"])
      case "messages": return (200, ["messages": []])
      case "gone": return (404, [:])
      case "older": return (200, ["labelIds": ["STARRED"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    let existing = [cached("gone"), cached("older")]
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: existing, historyID: "expired")
    XCTAssertEqual(result.historyID, "new-baseline")
    XCTAssertEqual(result.deletedIDs, ["gone"])
    XCTAssertEqual(result.applying(to: existing).map(\.id), ["older"])
    XCTAssertEqual(result.applying(to: existing).first?.labels, ["STARRED"])
    let paths = await transport.paths()
    XCTAssertEqual(Array(paths.prefix(3)), ["history", "profile", "messages"])
    XCTAssertEqual(Set(paths.suffix(2)), ["gone", "older"])
  }

  func testContentRefreshBypassesValidHistoryAndReloadsOlderCachedContentWithoutLosingDrafts()
    async throws
  {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "profile": return (200, ["historyId": "fresh-baseline"])
      case "messages":
        return (200, ["messages": [["id": "latest"]], "nextPageToken": "older-page"])
      case "latest", "older":
        let id = request.url!.lastPathComponent
        XCTAssertEqual(request.query("format"), "full")
        return (
          200,
          [
            "id": id, "threadId": "\(id)-thread", "labelIds": ["INBOX", "STARRED"],
            "payload": [
              "mimeType": "text/plain",
              "headers": [["name": "Subject", "value": "Refreshed \(id)"]],
              "body": ["data": Data("Refreshed \(id) body — café".utf8).base64URL],
            ],
          ]
        )
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    var local = cached("local-draft")
    local.labels = ["DRAFT"]
    local.body = "Unsent composition"
    var older = cached("older")
    older.draft = "Unsent reply before refresh"
    let existing = [cached("latest"), older, local]

    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: existing, historyID: "valid-history", refreshContent: true)
    older.draft = "Reply edited while refreshing"
    let applied = result.applying(to: [existing[0], older, local])

    XCTAssertEqual(result.historyID, "fresh-baseline")
    XCTAssertEqual(result.nextPage, "older-page")
    XCTAssertTrue(result.resetsPagination)
    XCTAssertEqual(Set(result.messages.map(\.id)), ["latest", "older"])
    XCTAssertTrue(result.labels.isEmpty)
    XCTAssertEqual(applied.first { $0.id == "latest" }?.body, "Refreshed latest body — café")
    XCTAssertEqual(applied.first { $0.id == "older" }?.body, "Refreshed older body — café")
    XCTAssertEqual(applied.first { $0.id == "older" }?.draft, older.draft)
    XCTAssertEqual(applied.first { $0.id == "local-draft" }, local)
    let paths = await transport.paths()
    XCTAssertEqual(Array(paths.prefix(2)), ["profile", "messages"])
    XCTAssertEqual(paths, ["profile", "messages", "latest", "older"])
  }

  func testUnauthorizedHistoryFailsWithoutResettingToFullSync() async throws {
    let transport = SyncFixtureHTTP { _ in (401, [:]) }
    do {
      _ = try await GmailClient(transport: transport).synchronize(
        token: "fixture", cached: [cached("existing")], historyID: "100")
      XCTFail("Unauthorized history must fail, not produce a deletion result")
    } catch let error as HTTPFailure {
      XCTAssertEqual(error.statusCode, 401)
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["history"])
  }

  func testContentRepairKeepsAssessmentAndOnlyCorroboratedReadableExcerpt() throws {
    var original = cached("repair")
    original.body = "<span style=\"color:red\">Review the proposal</span>"
    original.decision = Decision(
      category: .work, confidence: 0.9, needsReply: 0.8, urgent: 0.2,
      excerpt: original.body, model: "fixture")
    original.draft = "My unsent reply"
    var refreshed = original
    refreshed.body = "Review the proposal"
    let repaired = try XCTUnwrap(
      GmailSyncResult(messages: [refreshed], historyID: "new").applying(to: [original]).first)
    XCTAssertEqual(repaired.decision?.excerpt, refreshed.body)
    XCTAssertEqual(repaired.decision?.category, .work)
    XCTAssertEqual(repaired.decision?.needsReply, 0.8)
    XCTAssertEqual(repaired.draft, original.draft)

    refreshed.body = "A different body"
    let unmatched = try XCTUnwrap(
      GmailSyncResult(messages: [refreshed], historyID: "new").applying(to: [original]).first)
    XCTAssertNil(unmatched.decision?.excerpt)
    XCTAssertEqual(unmatched.decision?.category, .work)
  }

  func testMetadataAuthenticationAndNetworkFailuresNeverImplyDeletion() async throws {
    for networkFailure in [false, true] {
      let transport = SyncFixtureHTTP { request in
        if request.url!.lastPathComponent == "history" {
          return (
            200,
            ["historyId": "101", "history": [["labelsRemoved": [["message": ["id": "existing"]]]]]]
          )
        }
        if networkFailure { throw URLError(.notConnectedToInternet) }
        return (401, [:])
      }
      do {
        _ = try await GmailClient(transport: transport).synchronize(
          token: "fixture", cached: [cached("existing")], historyID: "100")
        XCTFail("Failed metadata fetch must throw, not produce a deletion result")
      } catch let error as HTTPFailure {
        XCTAssertFalse(networkFailure)
        XCTAssertEqual(error.statusCode, 401)
      } catch let error as URLError {
        XCTAssertTrue(networkFailure)
        XCTAssertEqual(error.code, .notConnectedToInternet)
      }
    }
  }

  func testExpiredHistoryRefreshesOnlyLabelsForStoredMessagesOnFirstPage() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "history": return (404, [:])
      case "profile": return (200, ["historyId": "new-baseline"])
      case "messages":
        return (200, ["messages": [["id": "stored"], ["id": "new"], ["id": "vanished"]]])
      case "stored":
        XCTAssertEqual(request.query("format"), "minimal")
        return (200, ["labelIds": ["INBOX", "STARRED"]])
      case "vanished":
        XCTAssertEqual(request.query("format"), "minimal")
        return (404, [:])
      case "new":
        XCTAssertEqual(request.query("format"), "full")
        return (200, ["id": "new", "threadId": "new-thread", "labelIds": ["INBOX"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    var stored = cached("stored")
    stored.draft = "Unsent reply"
    stored.decision = Samples.mail[0].decision
    let existing = [stored, cached("vanished")]
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: existing, historyID: "expired")
    let applied = result.applying(to: existing)
    XCTAssertEqual(Set(applied.map(\.id)), ["stored", "new"])
    let updated = try XCTUnwrap(applied.first { $0.id == "stored" })
    XCTAssertEqual(updated.labels, ["INBOX", "STARRED"])
    XCTAssertEqual(updated.body, "Original")
    XCTAssertEqual(updated.draft, stored.draft)
    XCTAssertEqual(updated.decision, stored.decision)
    let paths = await transport.paths()
    // Each stored message is requested once, not again by deletion reconciliation.
    XCTAssertEqual(paths.filter { $0 == "stored" }.count, 1)
    XCTAssertEqual(paths.filter { $0 == "vanished" }.count, 1)
  }

  func testOlderPageDownloadsOnlyMessagesNotAlreadyStored() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "messages":
        XCTAssertEqual(request.query("pageToken"), "older")
        return (200, ["messages": [["id": "stored"], ["id": "new"]], "nextPageToken": "oldest"])
      case "stored":
        XCTAssertEqual(request.query("format"), "minimal")
        return (200, ["labelIds": ["UNREAD"]])
      case "new":
        XCTAssertEqual(request.query("format"), "full")
        return (200, ["id": "new", "threadId": "thread", "labelIds": ["INBOX"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    let page = try await GmailClient(transport: transport).page(
      token: "fixture", pageToken: "older", cachedIDs: ["stored"])
    XCTAssertEqual(page.messages.map(\.id), ["new"])
    XCTAssertEqual(page.labels, ["stored": ["UNREAD"]])
    XCTAssertTrue(page.deletedIDs.isEmpty)
    XCTAssertEqual(page.next, "oldest")
  }

  func testContentRefreshStillDownloadsStoredMessagesOnFirstPage() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "profile": return (200, ["historyId": "baseline"])
      case "messages": return (200, ["messages": [["id": "stored"]]])
      case "stored":
        XCTAssertEqual(request.query("format"), "full")
        return (200, ["id": "stored", "threadId": "thread", "labelIds": ["INBOX"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    let result = try await GmailClient(transport: transport).synchronize(
      token: "fixture", cached: [cached("stored")], historyID: "valid", refreshContent: true)
    XCTAssertEqual(result.messages.map(\.id), ["stored"])
    let paths = await transport.paths()
    XCTAssertEqual(paths.filter { $0 == "stored" }.count, 1)
  }

  func testSpamIsListedOnlyWhenItsFolderAsksForIt() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "messages":
        if request.query("labelIds") == "SPAM" {
          XCTAssertEqual(request.query("q"), "in:spam")
          XCTAssertEqual(request.query("includeSpamTrash"), "true")
        } else {
          XCTAssertEqual(request.query("q"), "-in:trash -in:spam")
          XCTAssertNil(request.query("includeSpamTrash"))
        }
        return (200, ["messages": []])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    let client = GmailClient(transport: transport)
    _ = try await client.page(token: "fixture", labelID: "SPAM")
    _ = try await client.page(token: "fixture", labelID: "STARRED")
    _ = try await client.page(token: "fixture")
  }

  func testMessageDisappearingBetweenListAndFetchDoesNotAbortPage() async throws {
    let transport = SyncFixtureHTTP { request in
      switch request.url!.lastPathComponent {
      case "messages":
        return (200, ["messages": [["id": "gone"], ["id": "kept"]], "nextPageToken": "next"])
      case "gone": return (404, [:])
      case "kept": return (200, ["id": "kept", "threadId": "thread", "labelIds": ["INBOX"]])
      default: throw SyncFixtureError.unexpectedRequest(request.url!.absoluteString)
      }
    }
    let page = try await GmailClient(transport: transport).page(token: "fixture")
    XCTAssertEqual(page.messages.map(\.id), ["kept"])
    XCTAssertEqual(page.next, "next")
  }
}

private enum SyncFixtureError: Error {
  case unexpectedRequest(String)
}

private actor SyncFixtureHTTP: HTTPTransport {
  let respond: (URLRequest) throws -> (Int, [String: Any])
  var requests: [URLRequest] = []

  init(_ respond: @escaping (URLRequest) throws -> (Int, [String: Any])) {
    self.respond = respond
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let (status, object) = try respond(request)
    return (
      try JSONSerialization.data(withJSONObject: object),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }

  func paths() -> [String] { requests.map { $0.url!.lastPathComponent } }
}

extension URLRequest {
  fileprivate func query(_ name: String) -> String? {
    URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?
      .value
  }
}
