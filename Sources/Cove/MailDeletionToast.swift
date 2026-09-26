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
    func handle(_ event: NSEvent) -> NSEvent? {
      guard event.window === window, event.keyCode == 51,
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
        store.entered, store.screen == "mail", !store.showComposer,
        !store.showAssistant, !store.showConnections,
        !(window?.firstResponder is NSTextView), let mail = store.selected else { return event }
      guard !event.isARepeat else { return nil }
      store.queueTrash(mail)
      return nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
