import XCTest

@testable import CoveCore

final class AssistantMemoryTests: XCTestCase {
  func testMemoriesAreBoundedSanitizedAndRespectTheToggle() {
    var preferences = Preferences()
    XCTAssertNil(preferences.memoryPrompt)
    preferences.memories = ["Prefers morning meetings", "Line one\nline two", "  ", String(repeating: "x", count: 500)]
      + (1...40).map { "Note \($0)" }
    let prompt = try! XCTUnwrap(preferences.memoryPrompt)
    XCTAssertTrue(prompt.contains("- Prefers morning meetings"))
    XCTAssertTrue(prompt.contains("- Line one line two"))
    XCTAssertFalse(prompt.contains(String(repeating: "x", count: 201)))
    XCTAssertEqual(prompt.components(separatedBy: "\n- ").count - 1, 30)
    preferences.useMemories = false
    XCTAssertNil(preferences.memoryPrompt)
    XCTAssertNil(Preferences.sanitizedMemory(" \n "))
  }
}
