import XCTest

@testable import CoveCore

final class MojibakeTests: XCTestCase {
  func testRepairsUTF8ReadAsLatin1OrWindows1252() {
    XCTAssertEqual(Mojibake.repaired("Si no funciona el botÃ³n, copia"), "Si no funciona el botón, copia")
    XCTAssertEqual(Mojibake.repaired("CompaÃ±Ã­a â€” itâ€™s"), "Compañía — it’s")
    XCTAssertEqual(Mojibake.repaired("ðŸ‘‹ hola"), "👋 hola")
    XCTAssertEqual(Mojibake.repaired("5 Â· 6"), "5 · 6")
  }
  func testLeavesCorrectTextAlone() {
    for text in ["botón, compañía, Ünïcödé", "Ã alone", "Málaga — São Paulo", "plain ascii"] {
      XCTAssertEqual(Mojibake.repaired(text), text)
    }
  }
  func testStoredMailIsRepaired() {
    let mail = Mail(id: "m", sender: "Siegrist", senderEmail: "pagos@example.com", subject: "Solicitud", body: "el botÃ³n")
    XCTAssertEqual(Mojibake.repaired(mail).body, "el botón")
  }
}
