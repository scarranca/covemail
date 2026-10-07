import XCTest

@testable import CoveCore

final class PromptFilesTests: XCTestCase {
  private let mail = Mail(id: "m1", sender: "Despacho", senderEmail: "contador@example.com",
                          subject: "Líneas de captura septiembre", body: "Enviamos líneas de captura del IMSS e ISN.")

  func testAttachmentTextGoesInItsOwnBoundedSectionWithExactFigures() throws {
    let imss = AgentAttachmentText(name: "Formato para pago cuotas IMSS SEPTIEMBRE.pdf",
                                   text: "Línea de captura: 0123 4567 8901 2345 6789\nImporte total: $48,312.55")
    let prompt = try AIPrompt(intent: .assistantAnswer, instruction: "Dame los montos y líneas de captura del PDF",
                              mails: [mail], evidence: "memories", files: [imss])
    XCTAssertTrue(prompt.dataMessage.contains("attachments of source [1]"))
    XCTAssertTrue(prompt.dataMessage.contains("=== Formato para pago cuotas IMSS SEPTIEMBRE.pdf ===\nLínea de captura: 0123 4567 8901 2345 6789\nImporte total: $48,312.55"))
    XCTAssertTrue(prompt.dataMessage.contains("quote amounts, references and codes exactly"))
    XCTAssertTrue(prompt.dataMessage.hasSuffix("Additional untrusted context:\nmemories"), "the file text doesn't use the shared evidence budget")
  }

  func testEachFileGetsAShareAndSmallerModelsGetLess() throws {
    let long = String(repeating: "importe ", count: 10_000)
    let files = [AgentAttachmentText(name: "a.pdf", text: long), AgentAttachmentText(name: "b.pdf", text: "ISN $3,120.00")]
    let prompt = try AIPrompt(intent: .assistantAnswer, instruction: "montos", mails: [mail], files: files)
    XCTAssertTrue(prompt.files.contains("[file text shortened]"))
    XCTAssertTrue(prompt.files.contains("=== b.pdf ===\nISN $3,120.00"), "a long file can't crowd out the other")
    XCTAssertLessThanOrEqual(prompt.files.utf8.count, AIPromptLimits.standard.fileBytes + 200)
    let small = try prompt.resized(.onDevice)
    XCTAssertLessThan(small.files.utf8.count, 1_700)
    XCTAssertTrue(small.files.contains("=== b.pdf ==="), "files survive resizing for a smaller model")
    XCTAssertTrue(try AIPrompt(intent: .assistantAnswer, instruction: "x", mails: [mail]).files.isEmpty)
  }
}
