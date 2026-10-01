import AppKit
import CoveCore
import SwiftUI

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
    func handle(_ event: NSEvent) -> NSEvent? {
      guard let window, event.window === window,
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
        store.entered, store.screen == "mail", !store.showComposer, !store.showAssistant,
        !store.showConnections, window.attachedSheet == nil, NSApp.modalWindow == nil,
        (window.firstResponder as? NSTextView)?.isEditable != true,
        (window.firstResponder as? NSTextField)?.isEditable != true,
        !(window.firstResponder is NSPopUpButton) else { return event }
      switch event.keyCode {
      case 125, 126:
        guard !store.visible.isEmpty else { return event }
        store.moveSelection(by: event.keyCode == 125 ? 1 : -1)
      case 53, 123:
        guard store.selectedID != nil else { return event }
        store.selectedID = nil
        onReturnToList()
      default: return event
      }
      return nil
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
