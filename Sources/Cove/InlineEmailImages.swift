import CoveCore
import Foundation

extension AppStore {
  /// Inline MIME images come from the already connected mailbox, not sender-hosted URLs.
  /// Keep decoded data in the reader's lifetime rather than inflating persisted snapshots.
  func inlineEmailImages(for mail: Mail) async -> [String: String] {
    let account = accountEmail
    let sample = isSample
    let images = mail.availableAttachments.filter {
      $0.contentID != nil
        && ["image/png", "image/jpeg", "image/gif", "image/webp"]
          .contains($0.mimeType.lowercased())
        && ($0.byteCount ?? 0) <= 5_000_000
    }
    guard !images.isEmpty else { return [:] }
    // Reopening a recent email shows its images at once instead of downloading them again.
    let cacheKey = account + "\n" + mail.id
    if let cached = inlineImageCache.first(where: { $0.key == cacheKey }) { return cached.sources }
    var sources: [String: String] = [:]
    do {
      let needsToken = !sample && images.contains { $0.data == nil }
      let token = needsToken ? try await auth.token() : ""
      // A few at a time rather than one after another; the reader is waiting.
      let fetched = try await withThrowingTaskGroup(of: (Int, MailAttachment, Data)?.self) { group in
        for (position, attachment) in images.prefix(20).enumerated() {
          group.addTask {
            try Task.checkCancellation()
            guard let data = try? await GmailClient().attachmentData(
              messageID: mail.id, attachment: attachment, token: token) else { return nil }
            return (position, attachment, data)
          }
        }
        var values: [(Int, MailAttachment, Data)] = []
        for try await value in group { if let value { values.append(value) } }
        return values.sorted { $0.0 < $1.0 }
      }
      var totalBytes = 0
      for (_, attachment, data) in fetched {
        guard let contentID = attachment.contentID else { continue }
        totalBytes += data.count
        guard totalBytes <= 10_000_000 else { break }
        sources[contentID] = "data:\(attachment.mimeType.lowercased());base64,\(data.base64EncodedString())"
      }
    } catch { return [:] }
    if Task.isCancelled { return [:] }
    if !sources.isEmpty {
      inlineImageCache.removeAll { $0.key == cacheKey }
      inlineImageCache.append((cacheKey, sources))
      if inlineImageCache.count > 12 { inlineImageCache.removeFirst() }
    }
    guard !Task.isCancelled, entered, accountEmail == account, isSample == sample else {
      return [:]
    }
    return sources
  }
}
