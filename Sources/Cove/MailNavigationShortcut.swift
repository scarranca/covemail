import AppKit
import CoveCore
import SwiftUI
import WebKit

/// A reader click (including inside WebKit) must not disable mailbox navigation.
/// Native editors, sheets and other windows retain their own keyboard handling.
struct MailNavigationShortcut: NSViewRepresentable {
  let store: AppStore
  var onReturnToList: () -> Void
  func makeNSView(context: Context) -> ShortcutView { ShortcutView(store: store, onReturnToList: onReturnToList) }
  func updateNSView(_ view: ShortcutView, context: Context) {
    view.store = store; view.onReturnToList = onReturnToList
  }
  @MainActor final class ShortcutView: NSView {
    var store: AppStore
    var onReturnToList: () -> Void
    private var monitor: Any?
    init(store: AppStore, onReturnToList: @escaping () -> Void = {}) {
      self.store = store; self.onReturnToList = onReturnToList
      super.init(frame: .zero)
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handle(event)
      }
    }
    func handle(_ event: NSEvent, pointerLocation: NSPoint? = nil) -> NSEvent? {
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      let characters = event.charactersIgnoringModifiers ?? ""
      let key = characters.lowercased()
      // Shift only extends the selection (⇧↓/⇧↑), moves back to Inbox (⇧E) or types `?`; ⌘ only selects
      // all (⌘A). Every other modified key keeps its native meaning.
      let allowed: Bool
      switch modifiers {
      case []: allowed = true
      case .shift: allowed = event.keyCode == 125 || event.keyCode == 126 || key == "e" || characters == "?"
      case .command: allowed = key == "a"
      default: allowed = false
      }
      guard allowed, let window, event.window === window,
        store.entered, store.screen == "mail", !store.showComposer, !store.showAssistant,
        !store.showConnections, window.attachedSheet == nil, NSApp.modalWindow == nil,
        (window.firstResponder as? NSTextView)?.isEditable != true,
        (window.firstResponder as? NSTextField)?.isEditable != true,
        !(window.firstResponder is NSPopUpButton) else { return event }
      if modifiers == .command {
        // ⌘A chooses every listed email only from the list: selectable email text and HTML keep Select All.
        guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
          !Self.isInsideWebView(window.firstResponder), !store.visible.isEmpty else { return event }
        store.selectedIDs = Set(store.visible.map(\.id))
        return nil
      }
      if characters == "?" {
        store.showShortcutHelp = true
        return nil
      }
      // Letters by character, not key code, so they follow the user's keyboard layout.
      switch key {
      case "j", "k":
        // J/K: the same as ↓/↑.
        guard modifiers.isEmpty, !store.visible.isEmpty else { return event }
        store.moveSelection(by: key == "j" ? 1 : -1)
        return nil
      case "u":
        // U: read or unread, for the open email or every chosen one (following the open email's state).
        let targets = store.triageTargets(for: selectedMail)
        guard !targets.isEmpty else { return event }
        guard !event.isARepeat else { return nil }
        let unread = anchor(in: targets)?.isUnread ?? targets.contains(where: \.isUnread)
        return store.beginTriage(targets, unread ? .markRead : .markUnread) == nil ? event : nil
      case "s":
        // S: flag (the Gmail star) or remove the flag.
        let targets = store.triageTargets(for: selectedMail)
        guard !targets.isEmpty else { return event }
        guard !event.isARepeat else { return nil }
        let flagged = anchor(in: targets)?.isStarred ?? targets.allSatisfy(\.isStarred)
        return store.beginTriage(targets, flagged ? .unflag : .flag) == nil ? event : nil
      case "r":
        // R: reply, like the Reply button.
        guard let mail = selectedMail, !mail.labels.contains("DRAFT") else { return event }
        store.replyRequestID = mail.id
        return nil
      case "e":
        // E (as in Superhuman and Gmail): done. Archive and open the next email. ⇧E: back to the Inbox.
        let targets = store.triageTargets(for: selectedMail)
        guard !targets.isEmpty else { return event }
        guard !event.isARepeat else { return nil }
        return store.beginTriage(targets, modifiers == .shift ? .moveToInbox : .archive) == nil ? event : nil
      case "h":
        // H: open the open email's snooze menu (the reader shows it and clears the request).
        guard let mail = selectedMail else { return event }
        store.snoozeRequestID = mail.id
        return nil
      case "x":
        // X: choose or let go of the row under the pointer, otherwise the open email.
        let hovered = MailRowPointerTarget.mailID(at: pointerLocation ?? window.mouseLocationOutsideOfEventStream, in: window)
          .flatMap { id in store.visible.contains(where: { $0.id == id }) ? id : nil }
        guard let id = hovered ?? selectedMail?.id else { return event }
        guard !event.isARepeat else { return nil }
        if store.selectedIDs.contains(id) { store.selectedIDs.remove(id) } else { store.selectedIDs.insert(id) }
        return nil
      case "z":
        // Z: undo the last archive, read, flag, snooze or move; otherwise a pending move to Trash.
        guard !event.isARepeat else { return nil }
        if store.triageUndo != nil {
          Task { await store.undoLastTriage() }
        } else if store.canUndoTrash {
          store.undoQueuedTrash()
        } else {
          return event
        }
        return nil
      case "c":
        // C: write a new email.
        store.newDraft()
        return nil
      default: break
      }
      switch event.keyCode {
      case 125, 126:
        guard !store.visible.isEmpty else { return event }
        if modifiers == .shift {
          // ⇧↓/⇧↑: choose the open email and the next one, so one key then acts on all of them.
          if let id = store.selectedID { store.selectedIDs.insert(id) }
          store.moveSelection(by: event.keyCode == 125 ? 1 : -1)
          if let id = store.selectedID { store.selectedIDs.insert(id) }
        } else {
          store.moveSelection(by: event.keyCode == 125 ? 1 : -1)
        }
      case 53 where !store.selectedIDs.isEmpty:
        // Esc lets go of the chosen emails first, then closes the reader.
        store.selectedIDs = []
      case 53, 123:
        guard store.selectedID != nil else { return event }
        store.selectedID = nil
        onReturnToList()
      default: return event
      }
      return nil
    }
    /// The open email when it is one of `targets`: toggles follow its state, as for a single email.
    private func anchor(in targets: [Mail]) -> Mail? {
      selectedMail.flatMap { mail in targets.contains(where: { $0.id == mail.id }) ? mail : nil }
    }
    private static func isInsideWebView(_ responder: NSResponder?) -> Bool {
      var view = responder as? NSView
      while let current = view {
        if current is WKWebView { return true }
        view = current.superview
      }
      return false
    }
    private var selectedMail: Mail? {
      store.selectedID.flatMap { id in store.mails.first { $0.id == id } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

/// ⌘Delete on the Calendar screen asks to delete the selected event (the same confirmation as the trash
/// button). Text fields, sheets, menus and other windows keep the key.
struct CalendarDeleteShortcut: NSViewRepresentable {
  let store: AppStore
  var onDelete: (LocalEvent) -> Void
  func makeNSView(context: Context) -> ShortcutView { ShortcutView(store: store, onDelete: onDelete) }
  func updateNSView(_ view: ShortcutView, context: Context) { view.store = store; view.onDelete = onDelete }
  @MainActor final class ShortcutView: NSView {
    var store: AppStore
    var onDelete: (LocalEvent) -> Void
    private var monitor: Any?
    init(store: AppStore, onDelete: @escaping (LocalEvent) -> Void) {
      self.store = store; self.onDelete = onDelete
      super.init(frame: .zero)
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handle(event)
      }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
      guard let window, event.window === window, event.keyCode == 51 || event.keyCode == 117,
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
        store.entered, store.screen == "calendar", !store.showComposer, !store.showAssistant, !store.showConnections,
        window.attachedSheet == nil, NSApp.modalWindow == nil,
        (window.firstResponder as? NSTextView)?.isEditable != true,
        (window.firstResponder as? NSTextField)?.isEditable != true,
        !store.busy, !store.calendarSyncing,
        let id = store.calendarEventID, let selected = store.events.first(where: { $0.id == id })
      else { return event }
      onDelete(selected)
      return nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
