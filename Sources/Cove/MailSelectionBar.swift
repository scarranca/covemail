import CoveCore
import SwiftUI

/// The snooze choices, shared by the reader, the row quick action and the selection bar: Superhuman-style
/// named moments with their real times, then a date of the user's own, then "Return to inbox".
struct SnoozeChooser: View {
  /// Shown under the choices (where the reminder is saved); nil when several emails are chosen.
  var detail: String?
  var snoozed: Bool
  var title = "Snooze until"
  /// Opens on the date picker (previews and tests).
  var startsPicking = false
  let pick: (Date?) -> Void
  @State private var picking = false
  @State private var minimum = Date().addingTimeInterval(30 * 60)
  @State private var custom = SnoozePreset.tomorrowMorning.date() ?? Date().addingTimeInterval(3600)

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if picking { picker } else { choices }
    }.onAppear { if startsPicking { picking = true } }.padding(12).frame(width: picking ? 292 : 310)
  }

  private var choices: some View {
    Group {
      Text(title).font(.coveControl).foregroundStyle(Palette.muted).padding(.horizontal, 8).padding(.bottom, 4)
      ForEach(SnoozePreset.available(), id: \.preset) { item in
        SnoozeChoiceRow(title: item.preset.title, detail: SnoozePreset.describe(item.date), key: item.preset.key) {
          pick(item.date)
        }
      }
      SnoozeChoiceRow(title: "Pick a date…", detail: "", key: nil) {
        minimum = Date().addingTimeInterval(30 * 60)
        custom = max(custom, minimum)
        picking = true
      }
      if snoozed {
        Divider().padding(.vertical, 4)
        SnoozeChoiceRow(title: "Return to inbox", detail: "", key: nil) { pick(nil) }
      }
      if let detail {
        Text(detail).font(.coveMetadata).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 8)
      }
    }
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button { picking = false } label: { Label("Back", systemImage: "chevron.left").font(.coveControl) }
        .buttonStyle(.plain).foregroundStyle(Palette.body).help("Back to the snooze choices")
      DatePicker("Snooze until", selection: $custom, in: minimum..., displayedComponents: [.date, .hourAndMinute])
        .datePickerStyle(.graphical).labelsHidden().help("Choose when this email returns to your inbox")
      HStack {
        Text(SnoozePreset.describe(custom)).font(.coveSecondary).foregroundStyle(Palette.body)
        Spacer()
        Button("Snooze") { pick(custom) }.buttonStyle(PrimaryButton(compact: true))
          .help("Snooze until \(SnoozePreset.describe(custom))")
      }
    }
  }
}

private struct SnoozeChoiceRow: View {
  let title: String
  let detail: String
  let key: String?
  let action: () -> Void
  @State private var hovered = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title).font(.coveText).foregroundStyle(Palette.ink)
        Spacer(minLength: 8)
        if !detail.isEmpty { Text(detail).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(1).fixedSize() }
      }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        .background(hovered ? Palette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).onHover { hovered = $0 }
      .modifier(SnoozeKey(key: key))
      .help(detail.isEmpty ? title : "\(title) · \(detail)\(key.map { " (\($0))" } ?? "")")
  }
}

/// Digits 1–5 pick a preset while the chooser is open, as in Superhuman.
private struct SnoozeKey: ViewModifier {
  let key: String?
  func body(content: Content) -> some View {
    if let key, let character = key.first { content.keyboardShortcut(KeyEquivalent(character), modifiers: []) } else { content }
  }
}

/// A button that opens `SnoozeChooser` in a popover. A SwiftUI Menu can't be opened from a key, so H
/// flips `isOpen` instead. Choosing goes through `store.triage` so it advances and can be undone.
struct SnoozeTrigger<Label: View>: View {
  @Bindable var store: AppStore
  let targets: () -> [Mail]
  @Binding var isOpen: Bool
  var help = "Snooze (H)"
  @ViewBuilder var label: () -> Label

  var body: some View {
    let current = targets()
    Button { isOpen.toggle() } label: { label() }
      .help(help)
      .popover(isPresented: $isOpen, arrowEdge: .bottom) {
        SnoozeChooser(
          detail: current.count == 1 ? store.snoozeSyncDetail(for: current[0]) : nil,
          snoozed: current.count == 1 && (current[0].snoozedUntil != nil || store.cloudSnoozes.pending[current[0].id] != nil)
        ) { date in
          isOpen = false
          let chosen = targets()
          Task { await store.triage(chosen, .snooze(date)) }
        }
      }
  }
}

/// Appears above the list while emails are chosen; every action applies to all of them with one Undo.
struct MailSelectionBar: View {
  @Bindable var store: AppStore
  @State private var snoozeOpen = false

  private var chosen: [Mail] { store.triageTargets(for: nil) }

  var body: some View {
    let targets = chosen
    let anyUnread = targets.contains(where: \.isUnread)
    let allFlagged = !targets.isEmpty && targets.allSatisfy(\.isStarred)
    ViewThatFits(in: .horizontal) {
      bar(anyUnread: anyUnread, allFlagged: allFlagged, labels: true)
      bar(anyUnread: anyUnread, allFlagged: allFlagged, labels: false)
    }.padding(.horizontal, 22).padding(.vertical, 8).background(Palette.sidebar)
  }

  private func bar(anyUnread: Bool, allFlagged: Bool, labels: Bool) -> some View {
    HStack(spacing: 4) {
      Text("\(store.selectedIDs.count) selected").font(.coveControl).foregroundStyle(Palette.ink).fixedSize()
      Spacer(minLength: 8)
      action("Archive", icon: "archivebox", labels: labels, help: "Archive the chosen emails (E)") {
        Task { await store.triage(chosen, .archive) }
      }
      action(anyUnread ? "Read" : "Unread", icon: anyUnread ? "envelope.open" : "envelope.badge", labels: labels,
        help: anyUnread ? "Mark the chosen emails as read (U)" : "Mark the chosen emails as unread (U)") {
        Task { await store.triage(chosen, anyUnread ? .markRead : .markUnread) }
      }
      action(allFlagged ? "Unflag" : "Flag", icon: allFlagged ? "flag.fill" : "flag", labels: labels,
        help: allFlagged ? "Remove the follow-up flag (S)" : "Flag the chosen emails for follow-up (S)") {
        Task { await store.triage(chosen, allFlagged ? .unflag : .flag) }
      }
      SnoozeTrigger(store: store, targets: { chosen }, isOpen: $snoozeOpen, help: "Snooze the chosen emails (H)") {
        barLabel("Snooze", icon: "clock", labels: labels)
      }.buttonStyle(.plain)
      action("Delete", icon: "trash", labels: labels, help: "Move the chosen emails to Trash · 5 seconds to undo (⌘⌫)") {
        store.beginTriage(chosen, .trash)
        store.selectedIDs = []
      }
      Button { store.selectedIDs = [] } label: {
        Image(systemName: "xmark").font(.cove(size: 11, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(Palette.body).help("Clear the selection (Esc)").accessibilityLabel("Clear selection")
    }.disabled(store.busy)
  }

  private func action(_ title: String, icon: String, labels: Bool, help: String, run: @escaping () -> Void) -> some View {
    Button(action: run) { barLabel(title, icon: icon, labels: labels) }.buttonStyle(.plain).help(help)
  }

  private func barLabel(_ title: String, icon: String, labels: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: 12))
      if labels { Text(title).font(.coveControl).fixedSize() }
    }.foregroundStyle(Palette.ink).padding(.horizontal, labels ? 8 : 6).frame(minWidth: 26, minHeight: 26)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
      .contentShape(Rectangle()).accessibilityLabel(title)
  }
}
