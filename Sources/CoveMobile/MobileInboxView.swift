#if os(iOS)
import CoveCore
import SwiftUI

struct MobileInboxView: View {
  @Bindable var mailbox: MobileMailbox
  let ai: MobileAI
  @State private var path: [String] = []
  @State private var composing = false

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if mailbox.folder == .inbox && mailbox.splitInbox {
          Picker("Inbox", selection: $mailbox.inboxTab) {
            ForEach(InboxSplit.allCases, id: \.self) { tab in
              let unread = mailbox.unreadCount(tab)
              Text(unread > 0 ? "\(tab.title) \(unread)" : tab.title).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
        let mails = mailbox.visible
        ForEach(mails) { mail in
          NavigationLink(value: mail.id) { MobileMailRow(mail: mail) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              if mail.labels.contains("INBOX") {
                Button { mailbox.archive(mail) } label: { Label("Archive", systemImage: "archivebox") }
                  .tint(.indigo)
              }
              Button(role: .destructive) { mailbox.trash(mail) } label: { Label("Trash", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
              Button { mailbox.setRead(mail, mail.isUnread) } label: {
                Label(mail.isUnread ? "Read" : "Unread", systemImage: mail.isUnread ? "envelope.open" : "envelope.badge")
              }.tint(.blue)
              Button { mailbox.toggleStar(mail) } label: {
                Label(mail.isStarred ? "Unstar" : "Star", systemImage: mail.isStarred ? "star.slash" : "star")
              }.tint(.yellow)
            }
            .onAppear {
              // The real end of the list loads older mail; no Load more button (as on the Mac).
              if mail.id == mails.last?.id { Task { await mailbox.loadOlder() } }
            }
        }
        footer.listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .refreshable { await mailbox.sync() }
      .navigationTitle(mailbox.folder.title)
      .navigationDestination(for: String.self) { id in MobileReaderView(mailbox: mailbox, ai: ai, mailID: id) }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Picker("Folder", selection: $mailbox.folder) {
              ForEach(MobileMailbox.Folder.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
          } label: { Label("Folders", systemImage: "line.3.horizontal") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button { composing = true } label: { Label("New email", systemImage: "square.and.pencil") }
        }
      }
      .sheet(isPresented: $composing) {
        MobileComposeView(mailbox: mailbox, ai: ai, draft: .init())
      }
      .sheet(item: $mailbox.restoredDraft) { draft in
        MobileComposeView(mailbox: mailbox, ai: ai, draft: draft)
      }
      .alert("Cove", isPresented: Binding(get: { mailbox.error != nil }, set: { if !$0 { mailbox.error = nil } })) {
        Button("OK", role: .cancel) { mailbox.error = nil }
      } message: { Text(mailbox.error ?? "") }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack(spacing: 8) {
      if mailbox.syncing || mailbox.loadingOlder { ProgressView() }
      if let status = mailbox.status {
        Text(status)
      } else if mailbox.visible.isEmpty && !mailbox.syncing {
        Text(mailbox.folder == .inbox ? "Nothing here. Enjoy the quiet." : "No emails in \(mailbox.folder.title).")
      }
    }
    .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16)
  }
}

struct MobileMailRow: View {
  let mail: Mail

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      MobileAvatar(mail: mail)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          // Unread mail keeps its emphasis (DESIGN.md).
          Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender)
            .font(mail.isUnread ? .mobileSubheading : .coveMobile(15, relativeTo: .subheadline))
            .foregroundStyle(MobilePalette.ink).lineLimit(1)
          Spacer(minLength: 8)
          if mail.isStarred {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Starred")
          }
          Text(Self.date(mail.date)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }
        Text(mail.subject.isEmpty ? "(No subject)" : mail.subject)
          .font(mail.isUnread ? .mobileLabel : .mobileSecondary)
          .foregroundStyle(mail.isUnread ? MobilePalette.ink : MobilePalette.body).lineLimit(1)
        Text(mail.body.prefix(200).replacingOccurrences(of: "\n", with: " "))
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).lineLimit(2)
      }
      if mail.isUnread {
        Circle().fill(MobilePalette.accent).frame(width: 8, height: 8).padding(.top, 6)
          .accessibilityLabel("Unread")
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  static func date(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}
#endif
