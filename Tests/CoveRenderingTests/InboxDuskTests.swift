import AppKit
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class InboxDuskTests: XCTestCase {
  func testBirdsMoveAndTheSceneStaysInBounds() {
    let size = CGSize(width: 300, height: 190)
    let a = DuskGeometry.dots(size: size, time: 10), b = DuskGeometry.dots(size: size, time: 10.5)
    let birdsA = a.filter { $0.hue == nil }, birdsB = b.filter { $0.hue == nil }
    XCTAssertEqual(birdsA.count, birdsB.count)
    XCTAssertNotEqual(birdsA, birdsB, "the birds fly")
    XCTAssertGreaterThan(a.filter { $0.hue != nil && $0.y < DuskGeometry.horizon(size) && $0.hue! > 0.6 }.count, 100, "a dotted sun")
    XCTAssertTrue(a.filter { $0.hue != nil }.allSatisfy { $0.y >= 0 && $0.y <= size.height })
    XCTAssertLessThan(a.count, 2_500, "cheap enough to draw at 24 fps")
  }

  func testSceneRenders() throws {
    let view = HStack(spacing: 0) {
      ForEach([3.0, 7.4, 12.9], id: \.self) { time in
        InboxDuskView(title: "All caught up", detail: "Nothing unread in Important.", previewTime: time)
          .frame(width: 420, height: 380)
      }
    }.background(Palette.sidebar.opacity(0.35))
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 1260, height: 380)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    rep.size = host.bounds.size
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-inbox-dusk.png"))
  }
}
