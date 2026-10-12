import XCTest
@testable import CoveCore

final class MailNotificationCleanupTests: XCTestCase {
  private func alert(_ id: String, request: String? = nil, account: String? = "me@example.com") -> DeliveredMailAlert {
    DeliveredMailAlert(identifier: request ?? id, mailID: id, account: account)
  }

  func testClearsReadArchivedSpamTrashAndDeletedButKeepsUnreadInbox() async throws {
    let client = GmailClient(transport: NotificationFixtureHTTP { request in
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value, "minimal")
      switch request.url!.lastPathComponent {
      case "read": return (200, ["labelIds": ["INBOX"]])
      case "archived": return (200, ["labelIds": ["UNREAD"]])
      case "spam": return (200, ["labelIds": ["INBOX", "UNREAD", "SPAM"]])
      case "trash": return (200, ["labelIds": ["INBOX", "UNREAD", "TRASH"]])
      case "deleted": return (404, [:])
      default: return (200, ["labelIds": ["INBOX", "UNREAD"]])
      }
    })
    let ids = try await MailNotificationCleanup.removals(
      for: [alert("read", request: "apns-uuid"), alert("read", request: "duplicate"), alert("archived"),
            alert("spam"), alert("trash"), alert("deleted"), alert("unread")], account: "me@example.com", token: "fixture", client: client)
    XCTAssertEqual(Set(ids), ["apns-uuid", "duplicate", "archived", "spam", "trash", "deleted"])
  }

  func testAccountIsolationLegacyAlertsAndUndoUsesCurrentLabels() async throws {
    var requests: [String] = []
    let client = GmailClient(transport: NotificationFixtureHTTP { request in
      let id = request.url!.lastPathComponent
      requests.append(id)
      return (200, ["labelIds": id == "undo" ? ["INBOX", "UNREAD"] : ["INBOX"]])
    })
    let ids = try await MailNotificationCleanup.removals(
      for: [alert("foreign", account: "other@example.com"), alert("legacy", account: nil),
            alert("undo"), alert("untouched"), alert("case", account: "ME@EXAMPLE.COM")],
      account: "me@example.com", token: "fixture", changedIDs: ["foreign", "legacy", "undo", "case"], client: client)
    XCTAssertEqual(Set(ids), ["legacy", "case"])
    XCTAssertEqual(Set(requests), ["legacy", "undo", "case"])
  }

  func testNetworkAuthAndQuotaFailuresNeverDismissMail() async throws {
    for status in [401, 403, 429, 500] {
      let client = GmailClient(transport: NotificationFixtureHTTP { _ in (status, [:]) })
      do {
        _ = try await MailNotificationCleanup.removals(for: [alert("keep")], account: "me@example.com", token: "fixture", client: client)
        XCTFail("A failed check must leave notifications and the history cursor unchanged")
      } catch {}
    }
    let client = GmailClient(transport: NotificationFixtureHTTP { _ in throw URLError(.notConnectedToInternet) })
    do {
      _ = try await MailNotificationCleanup.removals(for: [alert("keep")], account: "me@example.com", token: "fixture", client: client)
      XCTFail("Offline checks must fail without dismissing alerts")
    } catch {}
  }

  func testHistoryIncludesLabelChangesAndDeletesAcrossPages() async throws {
    let client = GmailClient(transport: NotificationFixtureHTTP { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertFalse(query.contains { ["historyTypes", "labelId"].contains($0.name) })
      if query.contains(where: { $0.name == "pageToken" }) {
        return (200, ["historyId": "200", "history": [["messagesDeleted": [["message": ["id": "deleted"]]],
          "labelsAdded": [["message": ["id": "undo"], "labelIds": ["UNREAD"]]]]]])
      }
      return (200, ["historyId": "200", "nextPageToken": "next", "history": [[
        "messagesAdded": [["message": ["id": "new", "labelIds": ["INBOX", "UNREAD"]]],
                          ["message": ["id": "sent", "labelIds": ["SENT"]]]],
        "labelsRemoved": [["message": ["id": "read"], "labelIds": ["UNREAD"]],
                          ["message": ["id": "archived"], "labelIds": ["INBOX"]]]]]])
    })
    let result = try await GmailPush.newInboxMessages(token: "fixture", after: "100", client: client)
    XCTAssertEqual(result.ids, ["new"])
    XCTAssertEqual(result.changedIDs, ["read", "archived", "deleted", "undo"])
    XCTAssertEqual(result.cursor, "200")
  }

  func testBoundedHistoryResumesAfterLastProcessedRecordNotMailboxHead() async throws {
    var page = 0
    let client = GmailClient(transport: NotificationFixtureHTTP { _ in
      page += 1
      return (200, ["historyId": "900", "nextPageToken": "more", "history": [
        ["id": String(100 + page), "labelsRemoved": [["message": ["id": "read"], "labelIds": ["UNREAD"]]]]
      ]])
    })
    let result = try await GmailPush.newInboxMessages(token: "fixture", after: "100", client: client)
    XCTAssertEqual(result.cursor, "105")
    XCTAssertEqual(result.changedIDs, ["read"])
  }

  func testIncompleteHistoryDoesNotReturnAnAdvancedCursor() async {
    let client = GmailClient(transport: NotificationFixtureHTTP { _ in
      (200, ["historyId": "900", "nextPageToken": "more"])
    })
    do {
      _ = try await GmailPush.newInboxMessages(token: "fixture", after: "100", client: client)
      XCTFail("An incomplete history must not silently skip changes")
    } catch {}
  }
}

private struct NotificationFixtureHTTP: HTTPTransport {
  var respond: (URLRequest) throws -> (Int, [String: Any])
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (status, body) = try respond(request)
    return (try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
