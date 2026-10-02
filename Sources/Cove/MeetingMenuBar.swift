import AppKit
import CoveCore
import SwiftUI

/// Optional menu bar item for the next meeting (Settings → Gmail → Meetings in the menu bar). It shows a
/// countdown when a meeting is close, pulses when a call with other people is about to start, and its
/// panel joins the call in one click.
@MainActor @Observable final class MeetingMenuBarModel {
  static let enabledKey = "menuBar.meetings"
  private(set) var alert: MeetingAlert?
  private(set) var later: [LocalEvent] = []
  /// Flips while an urgent meeting pulses (never under Reduce Motion).
  private(set) var pulseOn = true
  @ObservationIgnored private weak var store: AppStore?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var lastRefresh = Date.distantPast
  @ObservationIgnored var clock: () -> Date = Date.init
  /// The AppKit status item (outside SwiftUI's app scene, which re-rendered the whole app on every
  /// change in 0.1.61). Created when the setting turns on, removed when it turns off.
  @ObservationIgnored private var statusItem: NSStatusItem?
  @ObservationIgnored private var popover: NSPopover?
  @ObservationIgnored var installsStatusItem = true

  init(store: AppStore) {
    self.store = store
    loop = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let wait = self.tick()
        try? await Task.sleep(for: .milliseconds(wait))
      }
    }
  }

  private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  /// Recomputes the next meeting and returns how long to wait: quick while pulsing, slow otherwise.
  @discardableResult func tick() -> Int {
    guard enabled else {
      removeStatusItem()
      if alert != nil { alert = nil }
      if !later.isEmpty { later = [] }
      return 2_000
    }
    if installsStatusItem { installStatusItem() }
    guard let store, store.entered else {
      if alert != nil { alert = nil }
      if !later.isEmpty { later = [] }
      updateStatusItem()
      return 15_000
    }
    let now = clock()
    let next = MeetingAlert.next(in: store.events, now: now)
    // Assign only real changes: every assignment notifies SwiftUI.
    if next?.event.id != alert?.event.id || next?.level != alert?.level || next?.title() != alert?.title() || next?.startsIn != alert?.startsIn && next?.level == .soon { alert = next }
    let day = Calendar.current.dateInterval(of: .day, for: now)
    let upcoming = store.events.filter { event in
      event.allDay != true && event.ownResponse != "declined" && event.start > now
        && event.id != alert?.event.id && day.map { event.start < $0.end } ?? false
    }.sorted { $0.start < $1.start }.prefix(4).map { $0 }
    if upcoming.map(\.id) != later.map(\.id) { later = upcoming }
    // Today's calendar stays fresh while the icon is on, without disturbing the Calendar screen's sync.
    if store.calendarConnected, !store.isSample, !store.calendarSyncing, !store.busy, now.timeIntervalSince(lastRefresh) > 300,
      let start = day?.start
    {
      lastRefresh = now
      Task { await store.syncCalendar(from: start, to: start.addingTimeInterval(2 * 86_400), maxPages: 2) }
    }
    if let alert, alert.urgent, alert.prominent, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      pulseOn.toggle()
      updateStatusItem()
      return 700
    }
    if !pulseOn { pulseOn = true }
    updateStatusItem()
    return alert?.level == .soon ? 5_000 : 15_000
  }

  /// Menu bar text and symbol for the current state.
  var statusTitle: String? { alert?.title() }
  var statusSymbol: String {
    guard let alert, alert.level != .later else { return "water.waves" }
    if alert.prominent { return pulseOn ? "video.fill" : "video" }
    return alert.joinURL != nil ? "video" : "calendar"
  }

  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(togglePanel(_:))
    item.button?.imagePosition = .imageLeading
    statusItem = item
    updateStatusItem()
  }
  private func removeStatusItem() {
    popover?.close(); popover = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }
    let image = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: "Cove meetings")
    image?.isTemplate = true
    if button.image?.name() != statusSymbol { image?.setName(statusSymbol); button.image = image }
    let title = statusTitle.map { " " + $0 } ?? ""
    if button.title != title { button.title = title }
    button.toolTip = alert.map { $0.event.title } ?? "Cove · meetings"
  }
  @objc private func togglePanel(_ sender: NSStatusBarButton) {
    if let popover, popover.isShown { popover.performClose(nil); return }
    guard let store else { return }
    let panel = NSPopover()
    panel.behavior = .transient
    panel.contentViewController = NSHostingController(rootView: MeetingMenuPanel(store: store, model: self) { [weak panel] in
      panel?.performClose(nil)
    })
    popover = panel
    panel.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
  }
}

struct MeetingMenuPanel: View {
  @Bindable var store: AppStore
  let model: MeetingMenuBarModel
  var dismiss: () -> Void = {}
  @AppStorage(MeetingMenuBarModel.enabledKey) private var enabled = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !store.entered || store.isSample {
        Text("Open Cove and connect Gmail to see your meetings here.").font(.coveSecondary).foregroundStyle(Palette.body)
      } else if !store.calendarConnected {
        Text("Connect Google Calendar in Cove to see your meetings here.").font(.coveSecondary).foregroundStyle(Palette.body)
      } else if let alert = model.alert {
        nextCard(alert)
      } else {
        Label("Nothing else on your calendar today", systemImage: "checkmark.circle").font(.coveSecondary).foregroundStyle(Palette.body)
      }
      if !model.later.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Later today").font(.coveCaption).foregroundStyle(Palette.muted)
          ForEach(model.later) { event in
            HStack(spacing: 10) {
              Text(event.start.formatted(date: .omitted, time: .shortened)).font(.coveMetadata).monospacedDigit()
                .foregroundStyle(Palette.body).frame(width: 62, alignment: .leading)
              Text(event.title).font(.coveSecondary).lineLimit(1)
              Spacer(minLength: 4)
              if let url = MeetingLink.url(for: event) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "video").font(.cove(size: 11)) }
                  .buttonStyle(.plain).foregroundStyle(Palette.body).help("Join call")
              }
            }
          }
        }
      }
      Divider()
      HStack {
        Button("Open Cove") { openCove() }.buttonStyle(.plain).font(.coveControl)
        Spacer()
        Button("Hide this icon") { dismiss(); enabled = false }.buttonStyle(.plain).font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }
    .padding(16).frame(width: 300, alignment: .leading)
    .foregroundStyle(Palette.ink).background(Palette.canvas)
  }

  private func nextCard(_ alert: MeetingAlert) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(alert.level == .now ? "Now" : alert.level == .soon ? "Starting soon" : "Next").font(.coveCaption)
        .foregroundStyle(alert.level == .later ? Palette.muted : Palette.ink)
      Text(alert.event.title).font(.coveSubheading).lineLimit(2)
      Text(timeLine(alert)).font(.coveMetadata).foregroundStyle(Palette.body)
      if alert.withGuests, let guests = guestLine(alert.event) {
        Text(guests).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
      }
      HStack(spacing: 8) {
        if let url = alert.joinURL {
          Button { NSWorkspace.shared.open(url); dismiss() } label: { Label("Join", systemImage: "video.fill") }
            .buttonStyle(PrimaryButton(compact: true)).keyboardShortcut(.defaultAction)
        }
        Button("Open in Cove") {
          store.selectCalendarDay(alert.event.start)
          store.calendarEventID = alert.event.id
          store.screen = "calendar"
          openCove()
        }.buttonStyle(SecondaryButton(compact: true))
      }.padding(.top, 4)
    }
  }

  private func timeLine(_ alert: MeetingAlert) -> String {
    let range = alert.event.start.formatted(date: .omitted, time: .shortened) + " – " + alert.event.end.formatted(date: .omitted, time: .shortened)
    let minutes = Int((alert.startsIn / 60).rounded(.up))
    if alert.startsIn <= 0 { return range + " · started \(max(0, -Int(alert.startsIn / 60))) min ago" }
    return range + (minutes <= 60 ? " · in \(minutes) min" : "")
  }
  private func guestLine(_ event: LocalEvent) -> String? {
    let others = (event.attendees ?? []).filter { $0.isSelf != true && $0.response != "declined" }
    guard let first = others.first else { return nil }
    let name = first.name ?? first.email ?? "a guest"
    return others.count == 1 ? "With \(name)" : "With \(name) and \(others.count - 1) other\(others.count == 2 ? "" : "s")"
  }
  private func openCove() {
    dismiss()
    CoveAppDelegate.showMainWindow(in: CoveAppDelegate.mainWindows.allObjects)
  }
}
