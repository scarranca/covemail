import Foundation

/// UTF-8 text that was read as Latin-1 / Windows-1252 somewhere along the way ("botÃ³n" for "botón",
/// "â€™" for "’"). Senders' tools and Cove's own decoder can both do this. Each broken run is turned back
/// into its bytes and re-read as UTF-8; runs that don't form valid UTF-8 are left exactly as they were.
public enum Mojibake {
  /// Characters that a byte 0x80…0xFF becomes in Windows-1252 (and Latin-1, for the undefined slots).
  private static let cp1252: [Character: UInt8] = {
    var map: [Character: UInt8] = [:]
    for byte in UInt8(0xA0)...UInt8(0xFF) { map[Character(Unicode.Scalar(byte))] = byte }
    let high: [UInt8: UInt32] = [
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
      0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
      0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
      0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]
    for (byte, scalar) in high { map[Character(Unicode.Scalar(scalar)!)] = byte }
    // Latin-1 control characters 0x81, 0x8D, 0x8F, 0x90, 0x9D (no Windows-1252 glyph).
    for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] { map[Character(Unicode.Scalar(byte))] = byte }
    return map
  }()

  /// Cheap check before any work: every broken run starts with one of these lead characters.
  public static func mightContain(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0xC2...0xF4).contains($0.value) }
  }

  public static func repaired(_ text: String) -> String {
    guard mightContain(text) else { return text }
    var output = ""
    output.reserveCapacity(text.count)
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      // A UTF-8 lead byte (Â…ô) followed by the right number of continuation bytes (0x80…0xBF).
      if let lead = cp1252[character], (0xC2...0xF4).contains(lead) {
        let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : 1
        var bytes = [lead]
        var next = index + 1
        while bytes.count <= needed, next < characters.count, let byte = cp1252[characters[next]], (0x80...0xBF).contains(byte) {
          bytes.append(byte); next += 1
        }
        if bytes.count == needed + 1, let decoded = String(bytes: bytes, encoding: .utf8), decoded.unicodeScalars.count == 1 {
          output += decoded
          index = next
          continue
        }
      }
      output.append(character)
      index += 1
    }
    return output
  }

  public static func repaired(_ mail: Mail) -> Mail {
    guard mightContain(mail.subject) || mightContain(mail.body) || mail.htmlBody.map(mightContain) == true else { return mail }
    var fixed = mail
    fixed.subject = repaired(mail.subject)
    fixed.body = repaired(mail.body)
    fixed.htmlBody = mail.htmlBody.map(repaired)
    return fixed
  }
}
