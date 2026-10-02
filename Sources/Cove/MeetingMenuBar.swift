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
    guard enabled, let store, store.entered else {
      alert = nil; later = []; pulseOn = true
      return 15_000
    }
    let now = clock()
    alert = MeetingAlert.next(in: store.events, now: now)
    let day = Calendar.current.dateInterval(of: .day, for: now)
    later = store.events.filter { event in
      event.allDay != true && event.ownResponse != "declined" && event.start > now
        && event.id != alert?.event.id && day.map { event.start < $0.end } ?? false
    }.sorted { $0.start < $1.start }.prefix(4).map { $0 }
    // Today's calendar stays fresh while the icon is on, without disturbing the Calendar screen's sync.
    if store.calendarConnected, !store.isSample, !store.calendarSyncing, !store.busy, now.timeIntervalSince(lastRefresh) > 300,
      let start = day?.start
    {
      lastRefresh = now
      Task { await store.syncCalendar(from: start, to: start.addingTimeInterval(2 * 86_400), maxPages: 2) }
    }
    if let alert, alert.urgent, alert.prominent, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      pulseOn.toggle()
      return 700
    }
    pulseOn = true
    return alert?.level == .soon ? 5_000 : 15_000
  }
}

struct MeetingMenuBarLabel: View {
  let model: MeetingMenuBarModel
  var body: some View {
    if let alert = model.alert, let title = alert.title() {
      HStack(spacing: 4) {
        Image(systemName: icon(alert))
        Text(title)
      }
    } else {
      Image(systemName: "water.waves")
    }
  }
  private func icon(_ alert: MeetingAlert) -> String {
    if alert.prominent { return model.pulseOn ? "video.fill" : "video" }
    return alert.joinURL != nil ? "video" : "calendar"
  }
}

struct MeetingMenuPanel: View {
  @Bindable var store: AppStore
  let model: MeetingMenuBarModel
  @Environment(\.openWindow) private var openWindow
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
        Button("Hide this icon") { enabled = false }.buttonStyle(.plain).font(.coveMetadata).foregroundStyle(Palette.muted)
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
          Button { NSWorkspace.shared.open(url) } label: { Label("Join", systemImage: "video.fill") }
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
    openWindow(id: "main")
    NSApp.activate()
  }
}
