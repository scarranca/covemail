#if os(iOS)
import CoveCore
import SwiftUI

/// Contacts, as the Mac's directory (docs/design-source/Contacts.html): the most-messaged strip, a
/// searchable list built from downloaded mail, and a person's detail with recent conversations.
/// Google Contacts sync isn't implemented, on the Mac or here.
struct MobileContactsView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  let workspace: MobileWorkspace
  @State private var query = ""
  @State private var path: [Route] = []
  @State private var composing: MobileDraft?
  /// Shown inside the iPad sidebar layout rather than as a sheet: no Done button.
  var inline = false
  @State private var chosen: String?
  @Environment(\.horizontalSizeClass) private var sizeClass
  /// iPad: the directory and the person side by side, as on the Mac.
  private var split: Bool { inline && sizeClass == .regular }
  @State private var pageWidth: CGFloat = 1000
  private var listWidth: CGFloat { min(400, max(300, pageWidth * 0.45)) }

  private func show(_ email: String) {
    if split { chosen = email } else { path.append(.person(email)) }
  }
  @Environment(\.dismiss) private var dismiss

  enum Route: Hashable { case person(String), mail(String) }

  static func emails(_ count: Int) -> String { count == 1 ? "1 email" : "\(count) emails" }

  private var contacts: [MailContact] {
    mailbox.contacts
  }

  var body: some View {
    NavigationStack(path: $path) {
      let all = contacts
      let terms = MailSearchIndex.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
      let filtered = terms.isEmpty ? all : all.filter { contact in
        let haystack = MailSearchIndex.fold(contact.name + " " + contact.email)
        return terms.allSatisfy { haystack.contains($0) }
      }
      let month = Date().addingTimeInterval(-30 * 86_400)
      let top = all.sorted { $0.messageCount(since: month, through: Date()) > $1.messageCount(since: month, through: Date()) }
        .filter { $0.messageCount(since: month, through: Date()) > 0 }.prefix(6)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          MobileScreenHeader(title: "Contacts", detail: "\(all.count) people")
          if let status = mailbox.historyStatus {
            HStack(spacing: 8) { ProgressView(); Text(status) }.font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          } else {
            Text("From the \(mailbox.allLoaded.count) emails on this iPhone (up to \(MobileMailbox.historyDays) days).")
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(MobilePalette.muted)
            TextField("Search people", text: $query).font(.mobileText)
          }
          .padding(.horizontal, 12).frame(minHeight: 42)
          .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 7))
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(MobilePalette.line))
          if query.isEmpty && !top.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              MobileSectionTitle(title: "Most messaged", detail: "Last 30 days")
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                  ForEach(Array(top)) { contact in
                    Button { show(contact.email) } label: {
                      VStack(spacing: 6) {
                        MobileAvatar(name: contact.name, size: 52)
                        Text(contact.name.split(separator: " ").first.map(String.init) ?? contact.name)
                          .font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
                        Text(Self.emails(contact.messageCount(since: month, through: Date()))).font(.mobileMetadata)
                          .foregroundStyle(MobilePalette.muted)
                      }.frame(width: 76)
                    }.buttonStyle(.plain)
                  }
                }
              }
            }
          }
          VStack(alignment: .leading, spacing: 0) {
            MobileSectionTitle(title: query.isEmpty ? "All contacts" : "Matches", detail: "\(filtered.count)").padding(.bottom, 8)
            if filtered.isEmpty {
              Text(all.isEmpty ? "People you email appear here as mail downloads." : "No one matches “\(query)”.")
                .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
            }
            ForEach(filtered) { contact in
              Button { show(contact.email) } label: {
                HStack(spacing: 12) {
                  MobileAvatar(name: contact.name, size: 36)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
                    Text(contact.email).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
                  }
                  Spacer()
                  if let last = contact.lastMessage {
                    Text(MobileDates.short(last)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                  }
                }.padding(.vertical, 10).contentShape(Rectangle())
              }.buttonStyle(.plain)
              Divider().overlay(MobilePalette.line).padding(.leading, 48)
            }
          }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        .frame(maxWidth: split ? .infinity : 860).frame(maxWidth: .infinity)
      }
      .frame(width: split ? listWidth : nil)
      .frame(maxWidth: split ? nil : .infinity)
      .background(split ? MobilePalette.surface : MobilePalette.canvas)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
      .overlay(alignment: .trailing) {
        if split {
          HStack(spacing: 0) {
            Spacer().frame(width: listWidth)
            Divider().overlay(MobilePalette.line)
            Group {
              if let email = chosen, let contact = all.first(where: { $0.email == email }) {
                MobileContactDetail(contact: contact, email: { composing = $0 }, open: { path.append(.mail($0)) })
              } else {
                MobileEmptyState(title: "No one selected", detail: "Choose a person to see your recent conversations.",
                                 systemImage: "person.crop.rectangle")
                  .frame(maxHeight: .infinity)
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(MobilePalette.canvas)
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { if !inline { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .person(let email):
          if let contact = contacts.first(where: { $0.email == email }) {
            MobileContactDetail(contact: contact, email: { composing = $0 }, open: { path.append(.mail($0)) })
          }
        case .mail(let id):
          MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
        }
      }
      .sheet(item: $composing) { draft in MobileComposeView(mailbox: mailbox, ai: ai, draft: draft) }
    }
  }
}

struct MobileContactDetail: View {
  let contact: MailContact
  let email: (MobileDraft) -> Void
  let open: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 16) {
          MobileAvatar(name: contact.name, size: 64)
          VStack(alignment: .leading, spacing: 4) {
            Text(contact.name).font(.mobileDetailTitle)
            Text(contact.email).font(.mobileSecondary).foregroundStyle(MobilePalette.body).textSelection(.enabled)
          }
        }
        HStack(spacing: 10) {
          Button {
            var draft = MobileDraft()
            draft.to = contact.email
            email(draft)
          } label: { Label("Email", systemImage: "envelope") }.buttonStyle(MobilePrimaryButton())
        }
        MobileCard {
          HStack {
            stat("\(contact.messages.count)", "emails downloaded")
            Spacer()
            stat(contact.lastMessage.map { MobileDates.short($0) } ?? "–", "last message")
            Spacer()
            stat("\(contact.messageCount(since: Date().addingTimeInterval(-30 * 86_400), through: Date()))", "last 30 days")
          }
        }
        VStack(alignment: .leading, spacing: 0) {
          MobileSectionTitle(title: "Recent conversations").padding(.bottom, 8)
          ForEach(contact.recentConversations.prefix(12)) { mail in
            Button { open(mail.id) } label: {
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
                  Spacer()
                  Text(MobileDates.short(mail.date)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                }
                Text(mail.body.prefix(120).replacingOccurrences(of: "\n", with: " ")).font(.mobileSecondary)
                  .foregroundStyle(MobilePalette.body).lineLimit(1)
              }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().overlay(MobilePalette.line)
          }
        }
        Text("Activity comes from mail downloaded to this iPhone.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(20)
    }
    .background(MobilePalette.canvas)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.mobileSection)
      Text(label).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
    }
  }
}
#endif
