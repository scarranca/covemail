import Foundation
import UniformTypeIdentifiers

/// A file attached to an email being written. The bytes are read when the file is added, so the
/// original can move or disappear; drafts keep them in the encrypted local store, never the cloud.
public struct OutgoingAttachment: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var filename: String
  public var mimeType: String
  public var data: Data

  /// Gmail's limit for the files on one email.
  public static let totalLimit = 25 * 1024 * 1024

  public init(filename: String, mimeType: String? = nil, data: Data) {
    let cleaned = Self.cleanFilename(filename)
    self.filename = cleaned
    self.mimeType = mimeType ?? Self.mimeType(for: cleaned)
    self.data = data
  }

  /// Reads a file now (security-scoped when needed). Folders and unreadable files are reported.
  public init(contentsOf url: URL) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
    if values?.isDirectory == true { throw CoveError.message("“\(url.lastPathComponent)” is a folder. Attach files, or compress the folder first.") }
    if let size = values?.fileSize, size > Self.totalLimit {
      throw CoveError.message("“\(url.lastPathComponent)” is larger than Gmail’s 25 MB limit.")
    }
    let data: Data
    do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
      throw CoveError.message("Cove couldn’t read “\(url.lastPathComponent)”.")
    }
    self.init(filename: url.lastPathComponent, mimeType: values?.contentType?.preferredMIMEType, data: data)
  }

  public var size: Int { data.count }
  public var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

  public static func totalSize(_ files: [OutgoingAttachment]) -> Int { files.reduce(0) { $0 + $1.size } }

  /// Rejects a set Gmail won't take, before anything is sent.
  public static func validate(_ files: [OutgoingAttachment]) throws {
    let total = totalSize(files)
    if total > totalLimit {
      throw CoveError.message("Attachments add up to \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)). Gmail allows 25 MB per email.")
    }
    for file in files where file.filename.isEmpty || file.mimeType.rangeOfCharacter(from: .newlines) != nil {
      throw CoveError.message("One attachment has an invalid name or type.")
    }
  }

  /// Adds files to a list, refusing the ones that would pass Gmail's limit. Returns what to tell the user.
  public static func adding(_ new: [OutgoingAttachment], to current: [OutgoingAttachment]) -> (files: [OutgoingAttachment], problem: String?) {
    var files = current
    var refused: [String] = []
    for file in new {
      if totalSize(files) + file.size > totalLimit { refused.append(file.filename) } else { files.append(file) }
    }
    guard !refused.isEmpty else { return (files, nil) }
    return (files, "Not attached (Gmail allows 25 MB per email): " + refused.joined(separator: ", "))
  }

  /// Composed Unicode (macOS file names are often decomposed), without characters that could break a header.
  static func cleanFilename(_ name: String) -> String {
    let flat = name.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\"" && $0 != "\\" && $0 != "/" }
    let value = String(String.UnicodeScalarView(flat)).trimmingCharacters(in: .whitespaces)
    return String((value.isEmpty ? "attachment" : value).prefix(180))
  }

  static func mimeType(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension
    return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
  }

  /// One MIME part: an ASCII fallback name plus the exact UTF-8 name (RFC 2231), base64 body.
  var mimePart: String {
    let ascii = String(filename.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? Character($0) : "_" })
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: Self.attrChars) ?? ascii
    let body = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    return "Content-Type: \(mimeType); name=\"\(ascii)\"\r\n"
      + "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\n"
      + "Content-Transfer-Encoding: base64\r\n\r\n" + body
  }

  private static let attrChars: CharacterSet = {
    var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
    set.insert(charactersIn: "!#$&+-.^_`|~")
    return set
  }()
}

extension GmailClient {
  /// Sends a message with files through Gmail's upload endpoint (up to 35 MB, unlike the 5 MB JSON
  /// form), with the thread ID in a metadata part so replies stay in their conversation. Like every
  /// non-read request, it is retried only when Gmail rate-limited it (never after a server error).
  func uploadSend(token: String, message: Data, threadID: String?) async throws -> String {
    let boundary = "cove-upload-" + UUID().uuidString
    var metadata: [String: Any] = [:]
    if let threadID, !threadID.isEmpty { metadata["threadId"] = threadID }
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
    body.append(try JSONSerialization.data(withJSONObject: metadata))
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
    body.append(message)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.httpBody = body
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let live = transport is LiveHTTP
    var attempt = 0
    while true {
      if live { await GmailPacer.shared.spend(100) }
      do {
        struct Sent: Decodable { var id: String }
        return try JSONDecoder().decode(Sent.self, from: try await checked(request, transport: transport)).id
      } catch let failure as HTTPFailure where failure.isRateLimited && attempt < 3 {
        attempt += 1
        try await Task.sleep(for: .seconds(Double(1 << attempt)))
      }
    }
  }
}
