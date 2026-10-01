import AppKit
import SwiftUI
import XCTest
@testable import Cove

/// Dead-key accents (´ then e → é) and input methods use "marked text". The editor must not reset
/// itself while a character is being composed, or the cursor jumps to the start (user report).
@MainActor final class ComposeAccentTests: XCTestCase {
  final class Model: ObservableObject {
    @Published var text = ""
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var tick = 0
  }
  struct Host: View {
    @ObservedObject var model: Model
    var body: some View {
      ComposeTextEditor(text: $model.text, selection: $model.selection).id("editor")
        .overlay(Text("\(model.tick)").opacity(0))   // lets the test re-render mid-accent
    }
  }

  func testTypingAnAccentKeepsTheCursorWhereYouAre() async throws {
    _ = NSApplication.shared
    let model = Model()
    let host = NSHostingView(rootView: Host(model: model).frame(width: 500, height: 300))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func pump() async throws { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) } }
    try await pump()
    let editor = try XCTUnwrap(find(NSTextView.self, in: host))

    editor.insertText("Hola ", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await pump()
    // Press ´: macOS shows a temporary accent and waits for the vowel.
    editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    model.tick += 1                                     // anything re-rendering the view meanwhile
    try await pump()
    XCTAssertTrue(editor.hasMarkedText(), "the pending accent survives a refresh")
    // Press e: the accent and vowel become é.
    editor.insertText("é", replacementRange: editor.markedRange())
    try await pump()

    XCTAssertEqual(editor.string, "Hola é")
    XCTAssertEqual(model.text, "Hola é")
    XCTAssertEqual(editor.selectedRange().location, 6, "the cursor stays after é, not at the start")
    editor.insertText("xito", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await pump()
    XCTAssertEqual(model.text, "Hola éxito")
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews { if let found = find(type, in: child) { return found } }
    return nil
  }
}
