import CoveCore
import SwiftUI

struct JevFlagsNavigation: View {
  @Bindable var store: AppStore
  @State private var expanded = true
  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(spacing: 2) {
        ForEach(JevMailFlag.allCases) { flag in
          Button { store.chooseFolder("jev:" + flag.rawValue) } label: {
            HStack(spacing: 10) {
              Image(systemName: flag.icon).frame(width: 18)
              Text(flag.title)
              Spacer(minLength: 0)
              Text("\(store.mails.filter { flag.matches($0.decision) && $0.labels.isDisjoint(with: ["TRASH", "SPAM"]) && !store.queuedTrashIDs.contains($0.id) }.count)")
                .font(.coveMetadata).foregroundStyle(Palette.body)
            }.font(.coveSecondary).padding(.horizontal, 10).padding(.vertical, 9)
              .background(store.screen == "mail" && store.selectedJevFlag == flag ? Palette.selection : .clear,
                          in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
          }.buttonStyle(.plain).help("Jev’s assessment of downloaded mail; separate from your follow-up flags")
        }
      }.padding(.top, 6)
    } label: {
      Label("Jev flags", systemImage: "sparkles").font(.coveCaption).foregroundStyle(Palette.body)
    }.disclosureGroupStyle(CoveDisclosureStyle()).padding(.top, 18)
  }
}

struct MailLabelChips: View {
  @Bindable var store: AppStore
  let mail: Mail
  var body: some View {
    MailChipLayout(spacing: 8) {
      Text(mail.labels.contains("TRASH") ? "Trash" : mail.labels.contains("SPAM") ? "Spam"
        : mail.labels.contains("DRAFT") ? "Draft" : mail.labels.contains("INBOX") ? "Inbox"
        : mail.labels.contains("SENT") ? "Sent" : "Archived")
        .font(.coveControl).padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
      ForEach(store.labels(on: mail)) { label in
        HStack(spacing: 8) {
          Button { store.chooseLabel(label); store.select(mail) } label: {
            Label(label.name, systemImage: "tag").lineLimit(1)
          }.buttonStyle(.plain).help("View \(label.name)")
          Button { Task { await store.setLabel(label, on: mail, applied: false) } } label: {
            Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 24).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(store.busy)
            .help("Remove \(label.name) from this email").accessibilityLabel("Remove \(label.name) from this email")
        }.font(.coveSecondary).padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
          .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
      }
      Menu {
        ForEach(store.customMailLabels) { label in
          Button {
            Task { await store.setLabel(label, on: mail, applied: !mail.labels.contains(label.id)) }
          } label: {
            Label(label.name, systemImage: mail.labels.contains(label.id) ? "checkmark" : "tag")
          }
        }
        if store.customMailLabels.isEmpty { Text("No custom Gmail labels yet") }
        Divider()
        Button("Refresh labels") { Task { await store.refreshLabels() } }
      } label: {
        Label(store.labels(on: mail).isEmpty ? "Add label" : "Edit labels", systemImage: "tag").font(.coveSecondary)
      }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).frame(height: 30)
        .disabled(store.busy).help("Apply or remove Gmail labels on this email")
    }.foregroundStyle(Palette.body)
  }
}
struct JevMailFlagBadges: View {
  let mail: Mail
  var isSample = false
  var body: some View {
    if let decision = mail.decision, !mail.jevFlags.isEmpty {
      MailChipLayout(spacing: 6) {
        Text(isSample ? "Sample" : "Jev").font(.coveCaption).foregroundStyle(Palette.muted)
        ForEach(mail.jevFlags) { flag in
          Label(flag.title, systemImage: flag.icon).font(.coveCaption)
            .foregroundStyle(Palette.body).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
            .help(flag.detail(decision)).accessibilityLabel(flag.title + ". " + flag.detail(decision))
        }
      }
    }
  }
}
/// Native wrapping keeps long label names and assessment badges inside narrow readers/rows.
struct MailChipLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 400, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (index, point) in result.points.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                           proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
    }
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    var points: [CGPoint] = []
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
      if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: width, height: y + rowHeight), points)
  }
}
