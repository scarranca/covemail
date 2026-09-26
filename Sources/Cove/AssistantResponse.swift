import CoveCore
import Foundation
import SwiftUI

/// Generated recommendations may point only to the exact evidence sent with this request.
struct AssistantResponse: Decodable {
  struct Comparison: Decodable {
    let label: String
    let quote: String
    let source: Int
  }
  struct Recommendation: Decodable {
    let title: String
    let detail: String
    let source: Int
    let reply: Bool
    var comparison: [Comparison]
  }
  struct Check: Decodable {
    let title: String
    let detail: String
    let source: Int
  }
  let summary: String
  var primary: Recommendation?
  let checks: [Check]

  static func parse(_ raw: String, mails: [Mail]) throws -> Self? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
      text = String(text[text.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Older/local providers can still return useful Markdown. Never show raw broken JSON.
    guard text.hasPrefix("{") || text.hasPrefix("[") else { return nil }
    let message = "Cove couldn’t read this model’s response. Try again or choose another model."
    guard text.utf8.count <= 32_000, var response = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
      !response.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      response.summary.count <= 1800, response.checks.count <= 4 else { throw CoveError.message(message) }
    func valid(_ source: Int) -> Bool { (1...max(1, mails.count)).contains(source) && source <= mails.count }
    func bounded(_ title: String, _ detail: String) -> Bool { !title.isEmpty && title.count <= 200 && !detail.isEmpty && detail.count <= 2400 }
    guard response.checks.allSatisfy({ valid($0.source) && bounded($0.title, $0.detail) }) else { throw CoveError.message(message) }
    if var primary = response.primary {
      guard valid(primary.source), bounded(primary.title, primary.detail), primary.comparison.count <= 4 else { throw CoveError.message(message) }
      primary.comparison = primary.comparison.filter { row in
        guard valid(row.source), !row.label.isEmpty, row.label.count <= 60, !row.quote.isEmpty, row.quote.count <= 280 else { return false }
        let mail = mails[row.source - 1]
        return mail.body.contains(row.quote) || mail.subject.contains(row.quote)
      }
      if primary.comparison.count < 2 { primary.comparison = [] }
      response.primary = primary
    }
    return response
  }

  var plainText: String {
    var sections = [summary]
    if let primary {
      sections += ["## " + primary.title, primary.detail]
      sections += primary.comparison.map { "- \($0.label): \($0.quote) [\($0.source)]" }
      sections.append("Source [\(primary.source)]")
    }
    if !checks.isEmpty {
      sections.append("### Also worth checking")
      sections += checks.map { "**\($0.title)** — \($0.detail) [\($0.source)]" }
    }
    return sections.joined(separator: "\n\n")
  }
}

struct AssistantResponseView: View {
  let response: AssistantResponse
  let mails: [Mail]
  let canReply: Bool
  let open: (Mail) -> Void
  let draft: (Mail, String) -> Void
  private func mail(_ source: Int) -> Mail? { mails.indices.contains(source - 1) ? mails[source - 1] : nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      ChatMarkdown(response.summary)
      if let primary = response.primary {
        VStack(alignment: .leading, spacing: 12) {
          Text(primary.title).font(.coveSection).accessibilityAddTraits(.isHeader)
          ChatMarkdown(primary.detail)
          if !primary.comparison.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Divider()
              ForEach(Array(primary.comparison.enumerated()), id: \.offset) { _, row in
                ViewThatFits(in: .horizontal) {
                  HStack(alignment: .top, spacing: 16) {
                    Text(row.label).font(.coveText).frame(width: 80, alignment: .leading)
                    quote(row).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                  }
                  VStack(alignment: .leading, spacing: 4) { Text(row.label).font(.coveSecondary); quote(row) }
                }.padding(.vertical, 4)
              }
              Divider()
            }.foregroundStyle(Palette.body)
          }
          if let source = mail(primary.source) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 12) { sourceLink(source); Spacer(minLength: 8); replyButton(primary, source: source) }
              VStack(alignment: .leading, spacing: 10) { sourceLink(source); replyButton(primary, source: source) }
            }
          }
        }
      }
      if !response.checks.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          Divider()
          Text("Also worth checking").font(.coveSubheading).padding(.top, 4).accessibilityAddTraits(.isHeader)
          ForEach(Array(response.checks.enumerated()), id: \.offset) { _, check in
            VStack(alignment: .leading, spacing: 5) {
              ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                  Text(check.title).font(.coveSubheading).fixedSize()
                  Spacer(minLength: 8)
                  if let source = mail(check.source) { sourceLink(source, compact: true) }
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(check.title).font(.coveSubheading)
                  if let source = mail(check.source) { sourceLink(source, compact: true) }
                }
              }
              ChatMarkdown(check.detail, fontSize: 14)
            }
          }
        }
      }
    }.foregroundStyle(Palette.ink).textSelection(.enabled)
  }
  private func quote(_ row: AssistantResponse.Comparison) -> some View {
    Text(row.quote).font(.coveBody).fixedSize(horizontal: false, vertical: true)
      .help("Quoted from source [\(row.source)]")
  }
  private func sourceLink(_ mail: Mail, compact: Bool = false) -> some View {
    Button { open(mail) } label: {
      HStack(spacing: 6) {
        if !compact { Image(systemName: "envelope") }
        Text(compact ? mail.subject : "\(mail.sender) · \(mail.subject)").lineLimit(1)
        Image(systemName: "arrow.up.right")
      }.font(.coveSecondary).foregroundStyle(Palette.body)
    }.buttonStyle(.plain).help("Open \(mail.subject) from \(mail.sender)").accessibilityLabel("Open source: \(mail.subject)")
  }
  @ViewBuilder private func replyButton(_ primary: AssistantResponse.Recommendation, source: Mail) -> some View {
    if primary.reply {
      Button { draft(source, primary.title + "\n" + primary.detail) } label: {
        Label(source.draft.isEmpty ? "Draft reply" : "Review draft", systemImage: "arrowshape.turn.up.left")
          .font(.coveControl).padding(.horizontal, 12).frame(height: 34)
          .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
      }.buttonStyle(.plain).disabled(!canReply).help("Open an editable reply. Nothing is sent.")
    }
  }
}
