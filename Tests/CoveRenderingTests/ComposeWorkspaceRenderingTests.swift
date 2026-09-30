import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class ComposeWorkspaceRenderingTests: XCTestCase {
  func testAliasComposeAndWritingCanvasPreserveOriginalDraft() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database(url: directory.appendingPathComponent("test.sqlite"))
    let http = AliasRenderHTTP()
    let store = try AppStore(database: database, accountEmail: "alex@example.com",
      gmail: GmailClient(transport: http), gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    store.mails = Samples.mail + [Mail(id: "maya-context", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Launch — final review", body: "Can we confirm a time to review the launch?")]
    store.newDraft()
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "maya@example.com", subject: "Launch review", body: "Original draft", from: "studio@example.com")
    let activity = WritingActivity()
    let host = NSHostingView(rootView: ComposerView(store: store, availableSize: CGSize(width: 1280, height: 920), activity: activity))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1216, height: 856), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    try capture(host, name: "compose-context")
    XCTAssertEqual(store.mails.first { $0.id == id }?.senderEmail, "studio@example.com")
    activity.working = true; activity.stage = "Looking up conversations"
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    // The thinking wave lives in the ask line (see `testThinkingWaveMovesAndHoldsStillWithReduceMotion`).
    try capture(host, name: "compose-waiting")
    activity.working = false
    activity.preview = "Hi Maya,\n\nI’ve looked over the launch notes. Could we confirm a time to review the remaining changes?\n\nThanks,\nAlex"
    for _ in 0..<36 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    try capture(host, name: "compose-canvas-preview")
    let finishedInk = try XCTUnwrap(descendants(host).compactMap { $0 as? WritingInkTextView }.first)
    XCTAssertEqual(finishedInk.motionProgress, 1)
    XCTAssertFalse(finishedInk.motionRunning, "Real-time animation stops when its last letter lands")
    XCTAssertEqual(store.mails.first { $0.id == id }?.body, "Original draft", "Preview never applies or sends")
    XCTAssertEqual(try database.loadMail().first { $0.id == id }?.body, "Original draft")
  }

  func testThinkingWaveMovesAndHoldsStillWithReduceMotion() async throws {
    _ = NSApplication.shared
    let moving = NSHostingView(rootView: WritingThinkingBar(stage: "Writing your draft").frame(width: 480))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = moving
    defer { window.close() }
    for _ in 0..<4 { moving.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let first = try capture(moving, name: "thinking-wave")
    for _ in 0..<6 { moving.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertNotEqual(first, try capture(moving, name: "thinking-wave-later"), "The wave moves while AI works")
  }

  func testThinkingWaveIsStillWithReduceMotion() async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: WritingThinkingBar(stage: "Looking up conversations", stillOverride: true).frame(width: 480))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 34), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let first = try capture(host, name: "thinking-reduced")
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertEqual(first, try capture(host, name: "thinking-reduced-later"), "Reduce Motion: waiting is visually still")
  }

  func testDisabledMotionPreviewRendersWithoutTypingDelay() async throws {
    _ = NSApplication.shared
    let text = "A complete suggestion without typing animation."
    let host = NSHostingView(rootView: WritingCanvasPreview(text: text, animated: false))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    try capture(host, name: "compose-reduced-motion")
    XCTAssertGreaterThan(host.fittingSize.height, 80)
  }

  func testDotsLandOnActualTextAndFinishAsSelectableSuggestion() async throws {
    _ = NSApplication.shared
    let text = "Hi Martha,\n\nMy first available time tomorrow is 10:30–11:00 AM Pacific. Would that work for you?\n\nBest,\nSantiago"
    let host = NSHostingView(rootView: WritingCanvasPreview(text: text))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let ink = try XCTUnwrap(descendants(host).compactMap { $0 as? WritingInkTextView }.first)
    XCTAssertGreaterThan(ink.inkDots.count, 200, "Real letters must have a populated ink field")
    XCTAssertLessThanOrEqual(ink.inkDots.count, WritingInkTextView.maximumDots)
    for dot in ink.inkDots {
      let landed = ink.position(for: dot, progress: 1)
      XCTAssertEqual(landed.x, dot.destination.x, accuracy: 0.001)
      XCTAssertEqual(landed.y, dot.destination.y, accuracy: 0.001)
    }
    var frames: [Data] = []
    for (index, phase) in [0.20, 0.47, 0.72, 1.0].enumerated() {
      ink.sampleMotion(at: phase)
      host.layoutSubtreeIfNeeded()
      let image = try capture(host, name: "compose-ink-phase-\(index)")
      frames.append(image)
    }
    XCTAssertEqual(Set(frames).count, 4, "Time samples must visibly move and resolve")
    XCTAssertEqual(ink.string, text, "Full suggestion remains available from the first frame")
    XCTAssertTrue(ink.isSelectable)
    XCTAssertFalse(ink.isEditable)
    XCTAssertFalse(ink.motionRunning, "Completed animation must stop scheduling work")
    let selected = (text as NSString).range(of: "10:30–11:00 AM Pacific")
    ink.setSelectedRange(selected)
    XCTAssertEqual(ink.selectedRange(), selected)
    ink.setSuggestion("An edited suggestion should appear immediately.", animated: true)
    XCTAssertEqual(ink.motionProgress, 1, "Editing the review never replays the reveal")
  }

  func testDisabledMotionAndLongDraftStayBounded() async throws {
    _ = NSApplication.shared
    let text = (0..<120).map { "Paragraph \($0): Hello 👋 Martha, tomorrow at 10:30 AM works for me." }.joined(separator: "\n\n")
    let host = NSHostingView(rootView: WritingCanvasPreview(text: text, animated: false))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let ink = try XCTUnwrap(descendants(host).compactMap { $0 as? WritingInkTextView }.first)
    XCTAssertEqual(ink.motionProgress, 1)
    XCTAssertFalse(ink.motionRunning)
    XCTAssertEqual(ink.string, text)
    XCTAssertLessThanOrEqual(ink.inkDots.count, WritingInkTextView.maximumDots)
    XCTAssertGreaterThan(ink.frame.height, try XCTUnwrap(ink.enclosingScrollView).contentView.bounds.height)
    try capture(host, name: "compose-ink-reduced-motion")
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  @discardableResult private func capture(_ host: NSView, name: String) throws -> Data {
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    return data
  }
}
private struct AliasRenderHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.lastPathComponent, "sendAs")
    return (Data(#"{"sendAs":[{"sendAsEmail":"alex@example.com","isPrimary":true},{"sendAsEmail":"studio@example.com","verificationStatus":"accepted"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
