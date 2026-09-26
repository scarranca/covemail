import CoveCore
import SwiftUI

struct CalendarSearchView: View {
  @Bindable var store: AppStore
  var select: (LocalEvent) -> Void
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  private var results: [LocalEvent] {
    CalendarSearch.matches(store.events, query: query, now: store.now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Find an event").font(.coveSection)
      TextField(
        "Search saved events", text: $query,
        prompt: Text("Title, guest, location or notes").foregroundStyle(Palette.muted)
      )
      .textFieldStyle(CoveFieldStyle(focus: $searchFocused))
      .accessibilityLabel("Search saved events")
      .onSubmit {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let event = results.first
        {
          select(event)
        }
      }
      Text(
        store.calendarConnected && !store.isSample
          ? "Saved events on this Mac, including Google weeks you’ve synced."
          : "Saved calendar events on this Mac."
      )
      .font(.coveSecondary).foregroundStyle(Palette.muted)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          if results.isEmpty {
            Text(
              query.isEmpty
                ? "No saved events yet." : "No matching events. Try a title, guest or location."
            )
            .font(.coveBody).foregroundStyle(Palette.muted).padding(.vertical, 24)
          }
          ForEach(results.prefix(50)) { event in
            let hidden = !store.isCalendarVisible(for: event)
            Button {
              select(event)
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.coveLabel).lineLimit(2)
                Text(event.start, format: .dateTime.month(.abbreviated).day().year())
                  + Text(
                    event.allDay == true
                      ? " · All day"
                      : " · " + event.start.formatted(date: .omitted, time: .shortened))
                Text(
                  hidden
                    ? event.calendarTitle + " · Hidden; selecting reveals it"
                    : event.calendarTitle)
              }.font(.coveMetadata).foregroundStyle(Palette.body)
                .multilineTextAlignment(.leading).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }.frame(height: 280)
      Text(
        results.count > 50
          ? "Showing 50 of \(results.count) matches. Refine your search to see more."
          : "\(results.count) \(results.count == 1 ? "event" : "events") · upcoming first"
      )
      .font(.coveMetadata).foregroundStyle(Palette.muted)
    }.padding(20).frame(width: 390).background(Palette.canvas)
      .task {
        await Task.yield()
        searchFocused = true
      }
  }
}
