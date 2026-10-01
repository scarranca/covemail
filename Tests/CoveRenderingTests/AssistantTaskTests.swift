import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class AssistantTaskTests: XCTestCase {
  private func route(_ json: String, mails: [Mail] = []) async throws -> AssistantCalendar.Result {
    try await AssistantCalendar(complete: { _ in json }, calendar: { _, _ in [] }, calendarAvailable: false,
                                timeZone: TimeZone(identifier: "America/Mexico_City")!)
      .respond("create a task so I can address this and remove this", mails: mails, progress: { _ in })
  }

  func testTaskRoutesToAReviewCardLinkedToTheSelectedEmail() async throws {
    let selected = Mail(id: "m1", sender: "GitHub", senderEmail: "noreply@github.com", subject: "Sync MCP Metrics failed", body: "Run failed")
    guard case .task(let task) = try await route(
      #"{"action":"task","title":"Fix the Sync MCP Metrics failure","due":"2026-10-02","archive":true}"#, mails: [selected])
    else { return XCTFail("a task request must not become a calendar question") }
    XCTAssertEqual(task.title, "Fix the Sync MCP Metrics failure")
    XCTAssertEqual(task.mailID, "m1")
    XCTAssertTrue(task.archive)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
    XCTAssertEqual(task.due.map { calendar.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2026, month: 10, day: 2))
  }

  func testArchiveNeedsASelectedEmailAndATitle() async throws {
    guard case .task(let task) = try await route(#"{"action":"task","title":"Call the bank","archive":true}"#) else { return XCTFail() }
    XCTAssertNil(task.mailID)
    XCTAssertFalse(task.archive, "with nothing on screen there is no email to archive")
    XCTAssertNil(task.due)
    guard case .clarification = try await route(#"{"action":"task","title":"  "}"#) else { return XCTFail("an empty task asks") }
  }

  func testRouterPromptOffersTasksAndTreatsRemoveAsArchive() {
    let prompt = AIIntent.planAssistant.instructions
    XCTAssertTrue(prompt.contains(#"{"action":"task""#))
    XCTAssertTrue(prompt.contains("means archiving it"))
    XCTAssertTrue(prompt.contains("never ask for a time or duration for a task"))
  }

  func testTaskCardRenders() throws {
    let mail = Mail(id: "m1", sender: "GitHub", senderEmail: "noreply@github.com", subject: "[covemail] Sync MCP Metrics workflow run failed", body: "")
    let proposal = AssistantCalendar.TaskProposal(title: "Fix the Sync MCP Metrics failure", due: Date(timeIntervalSince1970: 1_790_900_000),
                                                  notes: "", mailID: "m1", archive: true)
    var created = AssistantTaskState(proposal: proposal)
    created.phase = .created(GoogleTask(id: "t", title: proposal.title))
    created.archived = true
    let view = VStack(alignment: .leading, spacing: 16) {
      AssistantTaskCard(state: AssistantTaskState(proposal: proposal), mail: mail, connected: true, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
      AssistantTaskCard(state: AssistantTaskState(proposal: proposal), mail: mail, connected: false, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
      AssistantTaskCard(state: created, mail: mail, connected: true, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
    }.padding(24).frame(width: 600).background(Color.white)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 600, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-assistant-task-card.png"))
  }

  func testMeetingsWithAPersonSearchesALongRangeWithoutAskingForDates() async throws {
    let now = Date(timeIntervalSince1970: 1_790_800_000)
    let router = AssistantCalendar(complete: { _ in #"{"action":"meetings","person":"contacto@grupo-amx.com"}"# },
                                   calendar: { _, _ in [] }, calendarAvailable: true, now: now)
    guard case .meetings(let query) = try await router.respond("i had meetings with manuel contacto@grupo-amx.com?", progress: { _ in })
    else { return XCTFail("a person's meetings must not ask for a 31-day range") }
    XCTAssertEqual(query.person, "contacto@grupo-amx.com")
    XCTAssertEqual(query.start, now.addingTimeInterval(-365 * 86_400))
    XCTAssertEqual(query.end, now.addingTimeInterval(90 * 86_400))
    let disconnected = AssistantCalendar(complete: { _ in #"{"action":"meetings","person":"Manuel"}"# },
                                         calendar: { _, _ in [] }, calendarAvailable: false, now: now)
    guard case .clarification = try await disconnected.respond("meetings with Manuel?", progress: { _ in }) else { return XCTFail() }
    XCTAssertTrue(AIIntent.planAssistant.instructions.contains(#"{"action":"meetings""#))
  }

  func testMeetingsAgendaRenders() throws {
    let now = Date(timeIntervalSince1970: 1_790_800_000)
    let events = [-200.0, -90, -12, 20].enumerated().map { index, days in
      LocalEvent(title: ["Kickoff with Grupo AMX", "Pricing review", "Contract follow-up", "Quarterly check-in"][index],
                 start: now.addingTimeInterval(days * 86_400), end: now.addingTimeInterval(days * 86_400 + 3_600))
    }
    var agenda = AssistantAgenda(start: now.addingTimeInterval(-365 * 86_400), end: now.addingTimeInterval(90 * 86_400),
                                 events: events, totalCount: 4, now: now, timeZone: .current)
    agenda.heading = "Meetings with Manuel"
    XCTAssertEqual(agenda.days.count, 4, "a long range lists only the days with meetings")
    let host = NSHostingView(rootView: AssistantAgendaView(agenda: agenda).padding(24).frame(width: 640).background(Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 640, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-meetings-agenda.png"))
  }

  func testANameResolvesToTheOpenThreadsParticipant() async throws {
    var mail = Mail(id: "amx", sender: "Yidem Oviedo", senderEmail: "yidem@gigstack.io", subject: "Grupo AMX: tu cuenta Business", body: "Hola")
    mail.to = "AMX <contacto@grupo-amx.com>"
    mail.cc = "Santiago <santiago.carranca@gigstack.io>"
    let router = AssistantCalendar(complete: { _ in #"{"action":"meetings","person":"manuel"}"# }, calendar: { _, _ in [] },
                                   calendarAvailable: true, accountEmail: "santiago.carranca@gigstack.io")
    guard case .meetings(let query) = try await router.respond("i had meetings with manuel?", mails: [mail], progress: { _ in }) else { return XCTFail() }
    XCTAssertEqual(query.person, "contacto@grupo-amx.com", "the only participant outside the user's company")
    XCTAssertEqual(query.label, "Manuel (contacto@grupo-amx.com)")
    // A name that matches someone in the thread wins; nothing open means the name is searched as typed.
    XCTAssertEqual(ContactDirectory.participant(named: "Yidem", in: [mail], accountEmail: "santiago.carranca@gigstack.io")?.email, "yidem@gigstack.io")
    guard case .meetings(let loose) = try await router.respond("meetings with manuel?", progress: { _ in }) else { return XCTFail() }
    XCTAssertEqual(loose.person, "manuel")
  }
}
