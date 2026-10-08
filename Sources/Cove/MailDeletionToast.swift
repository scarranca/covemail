import AppKit
import CoveCore
import SwiftUI

struct MailDeletionToast: View {
  @Bindable var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Group {
      if !store.queuedTrashIDs.isEmpty {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
          let deadline = store.trashDeadline ?? context.date
          let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
          let pendingCount = store.pendingTrashIDs.count
          HStack(spacing: 13) {
            Image(systemName: "trash").accessibilityHidden(true)
            Text(pendingCount == 0 ? "Moving to Trash…" : remaining == 0 ? "Waiting to move to Trash…" : pendingCount == 1 ? "Email will move to Trash" : "\(pendingCount) emails will move to Trash")
              .font(.coveControl)
            if store.canUndoTrash {
              if remaining > 0 { ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: min(1, max(0, deadline.timeIntervalSince(context.date) / 5)))
                  .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(remaining)").font(.coveCaption).monospacedDigit()
              }.frame(width: 25, height: 25).accessibilityLabel("\(remaining) seconds to undo") }
              else { ProgressView().controlSize(.small).colorScheme(.dark) }
              Button("Undo") { store.undoQueuedTrash() }
                .buttonStyle(.plain).font(.coveControl).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            } else { ProgressView().controlSize(.small).colorScheme(.dark) }
          }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: !store.queuedTrashIDs.isEmpty)
  }
}

/// Leave native text editing shortcuts untouched, including search and reply fields.
struct MailDeleteShortcut: NSViewRepresentable {
  let store: AppStore
  func makeNSView(context: Context) -> ShortcutView { ShortcutView(store: store) }
  func updateNSView(_ view: ShortcutView, context: Context) { view.store = store }
  @MainActor final class ShortcutView: NSView {
    var store: AppStore
    private var monitor: Any?
    init(store: AppStore) {
      self.store = store
      super.init(frame: .zero)
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handle(event)
      }
    }
    func handle(_ event: NSEvent, pointerLocation: NSPoint? = nil) -> NSEvent? {
      guard let window, event.window === window, event.keyCode == 51,
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
        store.entered, store.screen == "mail", !store.showComposer,
        !store.showAssistant, !store.showConnections,
        window.attachedSheet == nil, NSApp.modalWindow == nil,
        !(window.firstResponder is NSTextView),
        !(window.firstResponder is NSTextField),
        !(window.firstResponder is NSPopUpButton) else { return event }
      guard !event.isARepeat else { return nil }
      let mail: Mail?
      if let id = MailRowPointerTarget.mailID(at: pointerLocation ?? window.mouseLocationOutsideOfEventStream, in: window) {
        // A disappearing/filtered row must never redirect deletion to a different selected message.
        mail = store.visible.first { $0.id == id }
      } else { mail = store.selected }
      guard let mail else { return event }
      // A chosen set that includes this email goes together, with one Undo (Z or the toast).
      store.beginTriage(store.triageTargets(for: mail), .trash)
      return nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

/// Resolve the row under the pointer at keypress time, including after scrolling or list reflow.
/// No cached hover ID can outlive its row, and the marker never intercepts row buttons.
struct MailRowPointerTarget: NSViewRepresentable {
  let mailID: String
  func makeNSView(context: Context) -> TargetView { TargetView(mailID: mailID) }
  func updateNSView(_ view: TargetView, context: Context) { view.mailID = mailID }
  @MainActor final class TargetView: NSView {
    var mailID: String
    init(mailID: String) { self.mailID = mailID; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  @MainActor static func mailID(at point: NSPoint, in window: NSWindow) -> String? {
    func find(in view: NSView) -> String? {
      guard !view.isHiddenOrHasHiddenAncestor else { return nil }
      if let row = view as? TargetView {
        let local = row.convert(point, from: nil)
        if row.bounds.contains(local), row.visibleRect.contains(local) { return row.mailID }
      }
      return view.subviews.reversed().lazy.compactMap { find(in: $0) }.first
    }
    return window.contentView.flatMap { find(in: $0) }
  }
}

/// "Sending to … · Undo": the same bar as Delete, counting down before the email goes to Gmail.
struct SendUndoToast: View {
  @Bindable var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Group {
      if let item = store.pendingSend {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
          let left = item.deadline.timeIntervalSince(context.date)
          let remaining = max(0, Int(ceil(left)))
          HStack(spacing: 13) {
            Image(systemName: "paperplane").accessibilityHidden(true)
            Text(item.delivering || remaining == 0 ? "Sending…" : "Sending to \(Self.firstRecipient(item.to))")
              .font(.coveControl).lineLimit(1)
            if !item.delivering && remaining > 0 {
              ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: min(1, max(0, left / AppStore.undoSendSeconds)))
                  .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(remaining)").font(.coveCaption).monospacedDigit()
              }.frame(width: 25, height: 25).accessibilityLabel("\(remaining) seconds to undo")
              Button("Undo") { store.undoSend() }
                .buttonStyle(.plain).font(.coveControl).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                .keyboardShortcut("z", modifiers: .command)
            } else {
              ProgressView().controlSize(.small).colorScheme(.dark)
            }
          }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.pendingSend?.id)
  }
  /// "Mariana Barreto" from "Mariana Barreto <mariana@…>, …", or the address.
  static func firstRecipient(_ to: String) -> String {
    let first = to.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? to
    if let open = first.firstIndex(of: "<") {
      let name = first[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
      if !name.isEmpty { return name }
      return String(first[first.index(after: open)...].prefix { $0 != ">" })
    }
    return first
  }
}
