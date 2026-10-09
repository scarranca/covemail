import AppKit
import CoveCore
import SwiftUI
import WebKit
import XCTest
@testable import Cove

/// Timings the speed audit quotes: what an autosave costs the view layer with a 4,000-email mailbox
/// (hidden hosting views, nothing ordered front), and what opening an HTML email costs.
@MainActor final class UISpeedBenchmarkTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private func store(_ mails: [Mail]) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveUISpeed-" + UUID().uuidString)
    directories.append(dir)
    let store = try AppStore(database: Database(url: dir.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"
    store.mails = mails
    store.chooseFolder("Inbox")
    return store
  }

  static let mailboxSize = Int(ProcessInfo.processInfo.environment["COVE_BENCH_MAILS"] ?? "") ?? 4_000
  private static func synthetic(_ count: Int) -> [Mail] {
    let paragraph = String(repeating: "Thanks for the update. Let's review the figures on Thursday and confirm the plan. ", count: 60)
    return (0..<count).map { index in
      var mail = Mail(id: "m\(index)", sender: "Sender \(index % 300)", senderEmail: "s\(index % 300)@example.com",
        subject: "Subject \(index) about the quarterly plan", body: paragraph,
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 90),
        labels: index % 3 == 0 ? ["INBOX", "UNREAD"] : index % 3 == 1 ? ["INBOX"] : ["SENT"], isBulkOrAutomated: index % 5 == 0)
      mail.threadID = "t\(index / 2)"
      return mail
    }
  }

  private func makeHost(_ view: some View, width: CGFloat = 1216, height: CGFloat = 856) -> (NSView, NSWindow) {
    let host = NSHostingView(rootView: view.font(.coveBody).foregroundStyle(Palette.ink).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    return (host, window)
  }

  /// Main-thread busy time for one edit and everything it sets off (SwiftUI's update, layout, display),
  /// averaged over `rounds`: the run loop is spun and the time between waking and going back to sleep
  /// is summed, so work SwiftUI defers to a later turn counts too.
  private func perEditMS(_ host: NSView, rounds: Int = Int(ProcessInfo.processInfo.environment["COVE_BENCH_ROUNDS"] ?? "") ?? 20, viaWindow: Bool = false, edit: (Int) -> Void) async throws -> Double {
    var total = 0.0
    for round in 0..<rounds {
      var woke = CACurrentMediaTime()
      var busy = 0.0
      let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
        if activity == .afterWaiting { woke = CACurrentMediaTime() } else { busy += CACurrentMediaTime() - woke }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      let started = CACurrentMediaTime()
      edit(round)
      // A keystroke: AppKit's display cycle lays out and draws the window from its top down, which
      // reaches only the views that need it. Forcing layout on the hosting view itself always re-runs it.
      if viaWindow, let window = host.window { window.layoutIfNeeded(); window.displayIfNeeded() } else { host.layoutSubtreeIfNeeded() }
      busy += CACurrentMediaTime() - started
      woke = CACurrentMediaTime()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      total += busy
      if ProcessInfo.processInfo.environment["COVE_BENCH_DETAIL"] != nil { print("ROUND \(round) \(String(format: "%.1f", busy * 1000))") }
    }
    return total * 1000 / Double(rounds)
  }

  func testComposerAutosaveWithLargeMailbox() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try store(Self.synthetic(Self.mailboxSize))
    store.newDraft()
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "maya@example.com", subject: "Launch", body: "Hello", from: "me@example.com")
    let (host, window) = makeHost(ComposerView(store: store, availableSize: CGSize(width: 1280, height: 920)))
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let ms = try await perEditMS(host) { round in
      store.saveComposition(id: id, to: "maya@example.com", subject: "Launch", body: String(repeating: "Typing. ", count: round + 2), from: "me@example.com")
    }
    print("BENCH composer autosave + layout (4,000 emails): \(String(format: "%.1f", ms)) ms")
    XCTAssertLessThan(ms, 400)
  }

  func testReplyAutosaveWithLargeMailbox() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try store(Self.synthetic(Self.mailboxSize))
    let open = try XCTUnwrap(store.visible.first)
    store.select(open)
    store.saveReply(id: open.id, text: "T")
    let current = try XCTUnwrap(store.mails.first { $0.id == open.id })
    let (host, window) = makeHost(ReaderView(store: store, mail: current))
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let ms = try await perEditMS(host) { round in
      store.saveReply(id: open.id, text: String(repeating: "Typing a reply. ", count: round + 2))
    }
    print("BENCH reply autosave + layout (4,000 emails): \(String(format: "%.1f", ms)) ms")
    XCTAssertLessThan(ms, 400)
  }

  private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
  }
  private func textFields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(textFields(in:))
  }

  /// One typed character, as the keyboard delivers it: through the focused editor, so SwiftUI sees the
  /// same binding updates and re-renders it would in the app.
  private func keystrokeMS(_ host: NSView, window: NSWindow, into responder: NSResponder & NSTextInputClient) async throws -> Double {
    XCTAssertTrue(window.makeFirstResponder(responder))
    return try await perEditMS(host, viaWindow: true) { round in
      responder.insertText(round % 6 == 5 ? " " : "a", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
  }

  func testTypingInTheComposerWithLargeMailbox() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try store(Self.synthetic(Self.mailboxSize))
    store.newDraft()
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "", subject: "Launch", body: String(repeating: "A paragraph already written. ", count: 40), from: "me@example.com")
    let (host, window) = makeHost(ComposerView(store: store, availableSize: CGSize(width: 1280, height: 920)))
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let body = try XCTUnwrap(textViews(in: host).first)
    let bodyMS = try await keystrokeMS(host, window: window, into: body)
    print("BENCH keystroke in composer body (4,000 emails): \(String(format: "%.1f", bodyMS)) ms")
    let to = try XCTUnwrap(textFields(in: host).first { $0.accessibilityLabel() == "To" } ?? textFields(in: host).first)
    XCTAssertTrue(window.makeFirstResponder(to))
    let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
    let toMS = try await keystrokeMS(host, window: window, into: editor)
    print("BENCH keystroke in To (4,000 emails): \(String(format: "%.1f", toMS)) ms")
    XCTAssertLessThan(bodyMS, 400); XCTAssertLessThan(toMS, 400)
  }

  func testTypingAReplyWithLargeMailbox() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try store(Self.synthetic(Self.mailboxSize))
    let open = try XCTUnwrap(store.visible.first)
    store.select(open)
    store.saveReply(id: open.id, text: "Thanks, ")
    let current = try XCTUnwrap(store.mails.first { $0.id == open.id })
    let (host, window) = makeHost(ReaderView(store: store, mail: current))
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let editor = try XCTUnwrap(textViews(in: host).first { $0.accessibilityLabel() != nil && $0.isEditable })
    let ms = try await keystrokeMS(host, window: window, into: editor)
    print("BENCH keystroke in reply (4,000 emails): \(String(format: "%.1f", ms)) ms")
    XCTAssertLessThan(ms, 400)
  }

  private func webViews(in view: NSView) -> [EmailWebView] {
    (view as? EmailWebView).map { [$0] } ?? view.subviews.flatMap(webViews(in:))
  }

  /// Opens ten different HTML emails one after another in a hosted reader (the reader is recreated per
  /// selection, like the app) and times each until its document has really rendered.
  func testOpeningTenHTMLEmailsInSequence() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let mails: [Mail] = (0..<10).map { index in
      var mail = Mail(id: "html\(index)", sender: "Sender \(index)", senderEmail: "s\(index)@example.com",
        subject: "Newsletter \(index)", body: "Plain fallback \(index)", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
        labels: ["INBOX"])
      mail.threadID = "thtml\(index)"
      mail.htmlBody = "<html><body><h1>Issue \(index)</h1>" + String(repeating: "<p style=\"color:#333\">Paragraph with <a href=\"https://example.com\">a link</a> and text.</p>", count: index == 5 ? 2 : 40) + "</body></html>"
      return mail
    }
    let store = try store(mails)
    let suite = "Cove.UISpeed." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = mails[0]
    store.select(first)
    let host = NSHostingView(rootView: ReaderView(store: store, mail: first).defaultAppStorage(defaults).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 824, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    var timings: [Double] = []
    for (index, mail) in mails.enumerated() {
      if index > 0 {
        store.select(mail)
        host.rootView = ReaderView(store: store, mail: mail).defaultAppStorage(defaults).background(Palette.canvas)
      }
      let started = CACurrentMediaTime()
      var rendered = false
      while !rendered, CACurrentMediaTime() - started < 10 {
        host.layoutSubtreeIfNeeded()
        if let web = webViews(in: host).first {
          let count = try? await web.callAsyncJavaScript(
            "return (document.getElementById('cove-email')?.textContent || '').includes(marker) ? 1 : 0",
            arguments: ["marker": "Issue \(index)"], in: nil, contentWorld: .defaultClient) as? Int
          rendered = count == 1
        }
        if !rendered { try await Task.sleep(for: .milliseconds(4)) }
      }
      XCTAssertTrue(rendered, "email \(index) rendered")
      timings.append((CACurrentMediaTime() - started) * 1000)
      // A reused view reports the new document's height, never the previous email's.
      let wantsShort = index == 5
      let settle = CACurrentMediaTime()
      while CACurrentMediaTime() - settle < 5 {
        host.layoutSubtreeIfNeeded()
        let height = webViews(in: host).first?.frame.height ?? 0
        if wantsShort ? (height > 40 && height < 250) : height > 400 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let finalHeight = webViews(in: host).first?.frame.height ?? 0
      if wantsShort { XCTAssertLessThan(finalHeight, 250, "short email after long ones") } else { XCTAssertGreaterThan(finalHeight, 400) }
      XCTAssertEqual(webViews(in: host).count, 1)
      try await Task.sleep(for: .milliseconds(120))  // the previous reader is released and its view returned
    }
    print("BENCH html open ms: " + timings.map { String(format: "%.0f", $0) }.joined(separator: ", ")
      + " · views created \(EmailWebViewPool.shared.created)")
    XCTAssertLessThan(timings.dropFirst().reduce(0, +) / 9, 5_000)
  }
}
