import CoveCore
import SwiftUI

/// The paperclip beside Send: a plain icon, like the draft's other icon actions.
struct AttachButton: View {
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: "paperclip").font(.system(size: 15, weight: .regular)).padding(8).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(Palette.body)
    .accessibilityLabel("Attach files").help("Attach files (or drop them on the draft)")
  }
}

/// Attached files as removable chips: name · size, with a quiet total against Gmail's 25 MB.
struct AttachmentChips: View {
  @Bindable var store: AppStore
  let target: String

  var body: some View {
    let files = store.attachments(for: target)
    VStack(alignment: .leading, spacing: 6) {
      if !files.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(files) { file in
            HStack(spacing: 6) {
              Image(systemName: icon(for: file)).font(.system(size: 12)).foregroundStyle(Palette.body)
              Text(file.filename).font(.coveControl).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
              Text(file.sizeText).font(.coveMetadata).foregroundStyle(Palette.body)
              Button { store.removeAttachment(file.id, from: target) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).padding(3).contentShape(Rectangle())
              }.buttonStyle(.plain).foregroundStyle(Palette.body)
                .accessibilityLabel("Remove \(file.filename)").help("Remove")
            }
            .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 5)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
          }
        }
        if files.count > 1 {
          Text("\(files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(OutgoingAttachment.totalSize(files)), countStyle: .file)) of 25 MB")
            .font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }
      if let notice = store.attachmentNotice {
        Text(notice).font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func icon(for file: OutgoingAttachment) -> String {
    if file.mimeType.hasPrefix("image/") { return "photo" }
    if file.mimeType == "application/pdf" { return "doc.richtext" }
    return "doc"
  }
}

/// Shown while files are dragged over a draft (or the window during a reply).
struct AttachmentDropOverlay: View {
  let title: String
  var body: some View {
    ZStack {
      Palette.canvas.opacity(0.88)
      VStack(spacing: 10) {
        Image(systemName: "paperclip").font(.system(size: 26, weight: .light))
        Text(title).font(.coveSubheading)
      }.foregroundStyle(Palette.ink)
    }
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).padding(10))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Lays chips out in rows, wrapping to the next line when the width runs out.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
      if needed > width && !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row(indices: [index], width: size.width, height: size.height))
      } else {
        rows[rows.count - 1].indices.append(index)
        rows[rows.count - 1].width = needed
        rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
      }
    }
    return rows
  }
}
