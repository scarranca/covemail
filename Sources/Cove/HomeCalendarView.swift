import CoveCore
import SwiftUI

struct HomeCalendarView: View {
  @Bindable var store: AppStore
  @State private var showAllInvitations = false
  private var upcoming: [LocalEvent] { store.todayEvents.filter { $0.end > store.now } }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Today").font(HomeType.primarySection)
        Spacer()
        Button { Task { await store.refreshHomeCalendar() } } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }.buttonStyle(.plain).font(HomeType.action)
          .disabled(store.calendarSyncing || store.busy || !store.calendarConnected)
        Button("Calendar →") { store.selectCalendarDay(store.now); store.screen = "calendar" }
          .buttonStyle(.plain).font(HomeType.action)
      }
      if !store.calendarConnected && !store.isSample {
        Text("Bring your schedule and invitations into Home.").font(.coveBody).foregroundStyle(Palette.muted)
        Button("Connect Google Calendar") {
          Task {
            await store.connectCalendar()
            if store.calendarConnected { await store.refreshHomeCalendar() }
          }
        }.buttonStyle(SecondaryButton()).disabled(store.busy)
        if let error = store.calendarConnectError {
          Text(error).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        if store.calendarSyncing {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Refreshing your schedule…").font(.coveMetadata) }
        }
        if let error = store.calendarSyncError {
          Text("Showing saved events. " + error).font(.coveMetadata).foregroundStyle(Palette.danger)
        }
        if upcoming.isEmpty {
          Text(store.calendarSyncing ? "Looking for today’s events…" : "No more events in your saved schedule today.")
            .font(.coveBody).foregroundStyle(Palette.muted)
        }
        ForEach(Array(upcoming.prefix(4))) { event in
          Button { open(event) } label: {
            HStack(alignment: .top, spacing: 14) {
              VStack(alignment: .leading, spacing: 3) {
                Text(event.allDay == true ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                  .font(HomeType.action).monospacedDigit()
                if event.allDay != true {
                  Text(event.end.formatted(date: .omitted, time: .shortened))
                    .font(HomeType.metadata).monospacedDigit().foregroundStyle(Palette.muted)
                }
              }.frame(width: 82, alignment: .leading)
              VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(HomeType.itemTitle).foregroundStyle(Palette.ink)
                Text(event.isPendingInvitation ? "Awaiting your response" : event.ownResponse == "tentative" ? "Maybe" : event.calendarTitle)
                  .font(.coveMetadata).foregroundStyle(Palette.muted)
              }.frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: "chevron.right").font(.coveMetadata).foregroundStyle(Palette.muted)
            }.padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        if upcoming.count > 4 {
          Button("View all \(upcoming.count) events today →") { store.selectCalendarDay(store.now); store.screen = "calendar" }
            .buttonStyle(.plain).font(HomeType.action)
        }
        Divider()
        HStack {
          Text("Invitations").font(HomeType.primarySection)
          Spacer()
          Text("\(store.pendingInvitations.count) pending").font(.coveMetadata).foregroundStyle(Palette.muted)
        }
        Text("Your primary Google Calendar · next 90 days").font(.coveMetadata).foregroundStyle(Palette.muted)
        if let notice = store.invitationNotice {
          Label(notice, systemImage: "checkmark.circle").font(.coveMetadata).foregroundStyle(Palette.body)
        }
        if let error = store.invitationError {
          Text(error).font(.coveMetadata).foregroundStyle(Palette.danger).textSelection(.enabled)
        }
        if store.pendingInvitations.isEmpty && !store.calendarSyncing {
          Text("No pending invitations in your saved calendar. Refresh to check for new ones.")
            .font(.coveBody).foregroundStyle(Palette.muted)
        }
        ForEach(showAllInvitations ? store.pendingInvitations : Array(store.pendingInvitations.prefix(3))) { event in
          VStack(alignment: .leading, spacing: 10) {
            Button { open(event) } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(HomeType.itemTitle)
                Text(event.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                  .font(HomeType.compactBody).foregroundStyle(Palette.body)
                if let organizer = event.organizerName ?? event.organizerEmail {
                  Text("From \(organizer)").font(.coveMetadata).foregroundStyle(Palette.muted)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            InvitationResponseButtons(store: store, event: event)
            Divider().padding(.top, 4)
          }
        }
        if store.pendingInvitations.count > 3 {
          Button(showAllInvitations ? "Show fewer" : "View all invitations →") { showAllInvitations.toggle() }
            .buttonStyle(.plain).font(HomeType.action)
        }
      }
    }
  }
  private func open(_ event: LocalEvent) {
    store.selectCalendarDay(event.start)
    store.calendarEventID = event.id
    store.revealCalendar(for: event)
    store.screen = "calendar"
  }
}

struct InvitationResponseButtons: View {
  @Bindable var store: AppStore
  let event: LocalEvent
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { responses }.fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 8) { responses }
      }
      if store.respondingEventID == event.id { ProgressView().controlSize(.small) }
      Text(store.isSample ? "Sample response · stays on this Mac" : event.recurringEventID == nil ? "Your response is sent through Google Calendar." : "Responds to this occurrence. Google Calendar sends your response.")
        .font(HomeType.metadata).foregroundStyle(Palette.muted)
    }
  }

  private var responses: some View {
    ForEach(CalendarRSVP.allCases, id: \.rawValue) { response in
      Button(response.title) {
        Task { await store.respondToInvitation(event, response: response) }
      }.buttonStyle(SecondaryButton(compact: true))
        .disabled(store.busy || store.calendarSyncing || event.ownResponse == response.rawValue)
        .accessibilityLabel("\(response.title) invitation: \(event.title)")
    }
  }
}
