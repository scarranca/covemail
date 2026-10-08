import SwiftUI

/// A small key cap, shared by the empty reader and the shortcut sheet.
struct ShortcutKeycap: View {
  let key: String
  var body: some View {
    Text(key).font(.coveSecondary).foregroundStyle(Palette.ink)
      .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 1))
  }
}

/// Every mail shortcut in one place (opened with ?). Kept in step with `MailNavigationShortcut` and the menu commands.
struct ShortcutHelpView: View {
  var close: () -> Void

  struct Entry: Identifiable {
    let keys: [String]
    let action: String
    var id: String { keys.joined() + action }
  }
  struct Section: Identifiable {
    let title: String
    let entries: [Entry]
    var id: String { title }
  }

  static let groups: [Section] = [
    Section(title: "Move", entries: [
      Entry(keys: ["↑", "↓"], action: "Previous or next email (also K and J)"),
      Entry(keys: ["Esc", "←"], action: "Back to the list"),
      Entry(keys: ["⇧↑", "⇧↓"], action: "Extend the selection while moving"),
    ]),
    Section(title: "Act", entries: [
      Entry(keys: ["E"], action: "Done: archive and open the next email"),
      Entry(keys: ["⇧E"], action: "Move back to the Inbox"),
      Entry(keys: ["U"], action: "Mark read or unread"),
      Entry(keys: ["S"], action: "Flag for follow-up"),
      Entry(keys: ["H"], action: "Snooze"),
      Entry(keys: ["⌘⌫"], action: "Move to Trash (5 seconds to undo)"),
      Entry(keys: ["Z"], action: "Undo the last action"),
    ]),
    Section(title: "Select", entries: [
      Entry(keys: ["X"], action: "Select or deselect an email"),
      Entry(keys: ["⌘A"], action: "Select every email in the list"),
      Entry(keys: ["Esc"], action: "Clear the selection"),
    ]),
    Section(title: "Write", entries: [
      Entry(keys: ["R"], action: "Reply"),
      Entry(keys: ["C"], action: "New email"),
      Entry(keys: ["⌘N"], action: "New email, from anywhere"),
      Entry(keys: ["⌘↩"], action: "Send"),
    ]),
    Section(title: "Go", entries: [
      Entry(keys: ["⌘0–5"], action: "Home, Mail, Calendar, Agents, Contacts, Tasks"),
      Entry(keys: ["⌘K"], action: "Search your mail"),
      Entry(keys: ["⌘J"], action: "Ask Cove"),
      Entry(keys: ["⌘R"], action: "Sync Gmail"),
      Entry(keys: ["?"], action: "This list"),
    ]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Keyboard shortcuts").font(.coveTitle).foregroundStyle(Palette.ink)
        Spacer()
        Text("Shortcuts pause while you type").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
      VStack(alignment: .leading, spacing: 18) {
        ForEach(Self.groups) { group in
          VStack(alignment: .leading, spacing: 8) {
            Text(group.title).font(.coveLabel).foregroundStyle(Palette.ink)
            ForEach(group.entries) { entry in
              HStack(spacing: 12) {
                HStack(spacing: 4) { ForEach(entry.keys, id: \.self) { ShortcutKeycap(key: $0) } }
                  .frame(width: 112, alignment: .leading)
                Text(entry.action).font(.coveLabel).fontWeight(.regular).foregroundStyle(Palette.body)
                Spacer(minLength: 0)
              }.accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.keys.joined(separator: " or ")): \(entry.action)")
            }
          }
        }
      }
      HStack {
        Spacer()
        Button("Close", action: close).buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction)
          .help("Close (Esc)")
      }
    }.padding(28).frame(width: 560).background(Palette.canvas)
  }
}
