#if os(iOS)
import CoveCore
import SwiftUI

/// Gmail search (the same bounded search as the Mac's), opening results in the reader.
struct MobileSearchView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  @State private var query = ""
  @State private var running: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      List {
        if let results = mailbox.searchResults {
          if results.isEmpty && !mailbox.searching {
            ContentUnavailableView.search(text: query)
          }
          ForEach(results) { mail in
            NavigationLink(value: mail.id) { MobileMailRow(mail: mail) }
          }
        } else if !mailbox.searching {
          Text("Search all of Gmail: people, subjects, or words in the email. Gmail operators like from: and has:attachment work too.")
            .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
            .listRowSeparator(.hidden)
        }
        if mailbox.searching {
          HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .navigationTitle("Search")
      .navigationDestination(for: String.self) { id in MobileReaderView(mailbox: mailbox, ai: ai, mailID: id) }
      .searchable(text: $query, prompt: "Search mail")
      .onSubmit(of: .search) {
        running?.cancel()
        running = Task { await mailbox.search(query) }
      }
      .onChange(of: query) { _, value in
        if value.isEmpty { running?.cancel(); mailbox.clearSearch() }
      }
    }
  }
}
#endif
