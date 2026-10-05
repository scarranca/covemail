#if os(iOS)
import CoveCore
import SwiftUI

/// Search: instant matches in mail on this iPhone (the Mac's folded index), then all of Gmail on submit.
struct MobileSearchView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  let workspace: MobileWorkspace
  @State private var query = ""
  @State private var running: Task<Void, Never>?
  @State private var path: [String] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("Search your mail").font(.mobileSection)
            Text("People, subjects or words in the email. Mail on this iPhone matches as you type; press Search for all of Gmail. Operators like from: and has:attachment work too.")
              .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 12)
          .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface)
        } else {
          let local = mailbox.localMatches(query)
          section(local.isEmpty ? "Nothing matches on this iPhone" : "On this iPhone · \(local.count)")
          rows(local)
          if let results = mailbox.searchResults {
            let fresh = results.filter { result in !local.contains { $0.id == result.id } }
            section(fresh.isEmpty ? "No other matches in Gmail" : "More from Gmail · \(fresh.count)")
            rows(fresh)
          } else if mailbox.searching {
            HStack(spacing: 8) { ProgressView(); Text("Searching Gmail…") }
              .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
              .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface)
          } else {
            Text("Press Search to look through all of Gmail.").font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
              .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(MobilePalette.surface)
      .environment(\.defaultMinListRowHeight, 0)
      .navigationTitle("Search")
      .navigationDestination(for: String.self) { id in
        MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
      }
      .searchable(text: $query, prompt: "Search your mail")
      .onSubmit(of: .search) {
        running?.cancel()
        running = Task { await mailbox.search(query) }
      }
      .onChange(of: query) { _, value in
        running?.cancel()
        mailbox.clearSearch()
      }
    }
  }

  private func section(_ title: String) -> some View {
    Text(title).font(.mobileControl).foregroundStyle(MobilePalette.muted)
      .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
      .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface)
  }

  private func rows(_ mails: [Mail]) -> some View {
    ForEach(mails) { mail in
      Button { path.append(mail.id) } label: { MobileMailRow(mail: mail) }
        .buttonStyle(MobileRowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(mail.isUnread ? MobilePalette.canvas : MobilePalette.mailRead)
        .listRowSeparatorTint(MobilePalette.line)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }
  }
}
#endif
