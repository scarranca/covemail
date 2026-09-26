import AppKit
import Foundation
import SwiftUI

/// Foundation parses Markdown; native views render its block structure without HTML or remote images.
final class ChatMarkdownNode: Identifiable {
  enum Kind: Equatable {
    case document, paragraph, heading(Int), list(Bool), item(Int), quote, code(String?), rule
    case table(Int), row(Bool), cell(Int)
  }
  let id: Int
  let kind: Kind
  var text = AttributedString()
  var children: [ChatMarkdownNode] = []
  init(id: Int, kind: Kind) { self.id = id; self.kind = kind }
  var plainText: String { String(text.characters) + children.map(\.plainText).joined(separator: "\n") }
}

struct ChatMarkdownDocument {
  let root: ChatMarkdownNode
  init(_ source: String) {
    root = ChatMarkdownNode(id: -1, kind: .document)
    guard let parsed = try? AttributedString(markdown: Self.normalizeBullets(source), options: .init(
      interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
      root.text = AttributedString(source)
      return
    }
    for run in parsed.runs {
      var parent = root
      for component in (run.presentationIntent?.components ?? []).reversed() {
        if let existing = parent.children.last, existing.id == component.identity {
          parent = existing
          continue
        }
        let kind: ChatMarkdownNode.Kind
        switch component.kind {
        case .paragraph: kind = .paragraph
        case .header(let level): kind = .heading(level)
        case .orderedList: kind = .list(true)
        case .unorderedList: kind = .list(false)
        case .listItem(let ordinal): kind = .item(ordinal)
        case .blockQuote: kind = .quote
        case .codeBlock(let language): kind = .code(language)
        case .thematicBreak: kind = .rule
        case .table(let columns): kind = .table(columns.count)
        case .tableHeaderRow: kind = .row(true)
        case .tableRow: kind = .row(false)
        case .tableCell(let column): kind = .cell(column)
        @unknown default: kind = .paragraph
        }
        let node = ChatMarkdownNode(id: component.identity, kind: kind)
        parent.children.append(node)
        parent = node
      }
      var content = AttributedString(parsed[run.range])
      content.presentationIntent = nil
      content.imageURL = nil
      if let url = content.link {
        if Self.allowsLink(url) { content.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid) }
        else { content.link = nil }
      }
      if run.inlinePresentationIntent?.contains(.code) == true {
        content.font = .system(size: 13, design: .monospaced)
        content.backgroundColor = Palette.sidebar
      }
      parent.text.append(content)
    }
    // An empty/unsupported parse must not erase a nonempty answer.
    if root.children.isEmpty && root.text.characters.isEmpty && !source.isEmpty {
      root.text = AttributedString(source)
    }
  }

  /// Models sometimes emit typographic bullets instead of Markdown list markers.
  /// Convert only standalone list lines, and preserve fenced/indented code exactly.
  static func normalizeBullets(_ source: String) -> String {
    var fence: (Character, Int)?
    return source.components(separatedBy: "\n").map { line in
      let trimmed = line.drop(while: { $0 == " " })
      let indentation = line.count - trimmed.count
      guard indentation <= 3 else { return line }
      if let first = trimmed.first, first == "`" || first == "~" {
        let count = trimmed.prefix(while: { $0 == first }).count
        if count >= 3 {
          if let opened = fence {
            if first == opened.0 && count >= opened.1 && trimmed.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
          } else { fence = (first, count) }
          return line
        }
      }
      guard fence == nil, trimmed.hasPrefix("• ") || trimmed.hasPrefix("▪ ") || trimmed.hasPrefix("◦ ") else { return line }
      return String(repeating: " ", count: indentation) + "- " + trimmed.dropFirst(2)
    }.joined(separator: "\n")
  }

  static func allowsLink(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "https", "http": return url.host?.isEmpty == false && url.user == nil && url.password == nil
    case "mailto": return !url.path.isEmpty
    default: return false
    }
  }
}

struct ChatMarkdown: View {
  private let document: ChatMarkdownDocument
  private let fontSize: CGFloat
  init(_ source: String, fontSize: CGFloat = CoveTypography.bodySize) { document = ChatMarkdownDocument(source); self.fontSize = fontSize }
  var body: some View {
    ChatMarkdownBlock(node: document.root)
      .font(.cove(size: fontSize)).foregroundStyle(Palette.body).tint(Palette.ink)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(\.openURL, OpenURLAction { url in
        ChatMarkdownDocument.allowsLink(url) ? .systemAction : .discarded
      })
  }
}

private struct ChatMarkdownBlock: View {
  let node: ChatMarkdownNode
  @ViewBuilder var body: some View {
    switch node.kind {
    case .document, .item:
      VStack(alignment: .leading, spacing: 14) {
        if !node.text.characters.isEmpty { prose(node.text) }
        ForEach(node.children) { ChatMarkdownBlock(node: $0) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    case .paragraph, .cell:
      prose(node.text)
    case .heading(let level):
      Text(node.text).font(level == 1 ? .coveDetailTitle : level == 2 ? .coveSection : .coveSubheading)
        .foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader).padding(.top, level <= 2 ? 4 : 0)
    case .list(let ordered):
      VStack(alignment: .leading, spacing: 9) {
        ForEach(node.children) { item in
          HStack(alignment: .top, spacing: 10) {
            Text(marker(item, ordered: ordered)).monospacedDigit()
              .frame(minWidth: 18, alignment: .trailing).padding(.top, 1)
            ChatMarkdownBlock(node: item).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    case .quote:
      VStack(alignment: .leading, spacing: 10) {
        ForEach(node.children) { ChatMarkdownBlock(node: $0) }
      }.padding(.leading, 15).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 3) }
    case .code(let language):
      ChatCodeBlock(code: String(node.text.characters), language: language)
    case .rule:
      Divider().padding(.vertical, 4)
    case .table(let columns):
      ChatMarkdownTable(rows: node.children, columns: columns)
    case .row:
      HStack(alignment: .top, spacing: 12) {
        ForEach(node.children) { ChatMarkdownBlock(node: $0) }
      }
    }
  }

  private func prose(_ text: AttributedString) -> some View {
    Text(text).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func marker(_ item: ChatMarkdownNode, ordered: Bool) -> String {
    if ordered, case .item(let ordinal) = item.kind { return "\(ordinal)." }
    return "•"
  }
}

private struct ChatCodeBlock: View {
  let code: String
  let language: String?
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(language?.isEmpty == false ? language! : "Code").font(.coveCaption)
          .foregroundStyle(Palette.muted)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          copied = true
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.coveMetadata)
        }.buttonStyle(.plain).accessibilityLabel(copied ? "Code copied" : "Copy code")
      }
      Text(code.hasSuffix("\n") ? String(code.dropLast()) : code)
        .font(.system(size: 13, design: .monospaced)).lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }.padding(14).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
  }
}

private struct ChatMarkdownTable: View {
  let rows: [ChatMarkdownNode]
  let columns: Int
  var body: some View {
    ViewThatFits(in: .horizontal) {
      grid.fixedSize(horizontal: true, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        ScrollView(.horizontal) { grid }.fixedSize(horizontal: false, vertical: true)
        Label("Scroll to see more columns", systemImage: "arrow.left.and.right")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Table")
  }
  private var grid: some View {
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(rows) { row in
          let header = row.kind == .row(true)
          GridRow(alignment: .top) {
            ForEach(0..<columns, id: \.self) { column in
              let content = row.children.first { $0.kind == .cell(column) }?.text ?? AttributedString("")
              Text(content).font(header ? .coveLabel : .coveText)
                .lineSpacing(4).frame(width: 160, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(10)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(header ? Palette.selection : Palette.sidebar)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
