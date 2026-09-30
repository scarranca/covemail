import CoveCore
import SwiftUI

/// Messages in a thread read as separate cards; per-message actions live in each card's header.
struct ReaderConversation: View {
  let store: AppStore
  let anchor: Mail
  let onReply: (Mail, Bool) -> Void
  @State private var loading = false
  @State private var failure: String?
  @State private var retry = 0
  private var messages: [Mail] { MailConversation.messages(in: store.mails, anchor: anchor) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if loading && messages.count > 1 {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Updating conversation…").font(.coveMetadata).foregroundStyle(Palette.body)
        }.accessibilityElement(children: .combine)
      }
      if let failure {
        HStack(spacing: 12) {
          Text("Showing downloaded messages. \(failure)").font(.coveSecondary).foregroundStyle(Palette.body)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Retry") { retry += 1 }.buttonStyle(SecondaryButton(compact: true))
        }
      }
      if messages.count == 1 {
        ReaderMessageContent(store: store, mail: messages[0])
      } else {
        ForEach(messages) { message in
          ReaderThreadMessage(store: store, mail: message, selected: message.id == anchor.id, onReply: onReply)
        }
      }
    }
    .task(id: "\(store.accountEmail):\(anchor.id):\(retry)") {
      store.includeStoredThread(of: anchor)
      loading = !store.isSample && !anchor.threadID.isEmpty && !anchor.labels.contains("DRAFT")
      failure = nil
      defer { loading = false }
      do { try await store.refreshReaderThread(anchor) }
      catch is CancellationError { }
      catch { if !Task.isCancelled { failure = "The rest of the conversation couldn’t load." } }
    }
  }
}

struct ReaderMessageContent: View {
  let store: AppStore
  let mail: Mail
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      EmailBodyView(store: store, mail: mail).id(mail.id)
      if !mail.availableAttachments.isEmpty { ReaderAttachments(store: store, mail: mail) }
    }
  }
}

/// Translation prepares an Ask Cove question; it never changes the email or a draft.
struct TranslateMenu: View {
  let store: AppStore
  let mail: Mail
  var body: some View {
    Menu {
      ForEach(["English", "Spanish", "French", "German", "Portuguese", "Japanese"], id: \.self) { language in
        Button(language) { store.askAboutEmail(mail, question: "Translate the selected email into \(language). Preserve its meaning and distinguish the translation from the original email.") }
      }
    } label: { Label("Translate", systemImage: "character.bubble") }
      .disabled(mail.labels.contains("DRAFT"))
  }
}

struct ReaderThreadMessage: View {
  let store: AppStore
  let mail: Mail
  let selected: Bool
  let onReply: (Mail, Bool) -> Void
  @State private var expanded: Bool
  init(store: AppStore, mail: Mail, selected: Bool, onReply: @escaping (Mail, Bool) -> Void) {
    self.store = store; self.mail = mail; self.selected = selected; self.onReply = onReply
    _expanded = State(initialValue: selected)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded {
        Divider().padding(.horizontal, 16)
        ReaderMessageContent(store: store, mail: mail).padding(16)
      }
    }
    .background(expanded ? Palette.canvas : Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Palette.inputBorder : Palette.line))
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      Button {
        expanded.toggle()
        if expanded { Task { await store.markViewed(mail) } }
      } label: {
        HStack(alignment: .center, spacing: 12) {
          Text(mail.initials).font(.coveMetadata).foregroundStyle(Palette.body)
            .frame(width: 32, height: 32).background(Palette.sidebar, in: Circle()).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              if mail.isUnread {
                Circle().fill(Palette.ink).frame(width: 7, height: 7).accessibilityLabel("Unread")
              }
              Text(mail.sender).font(.coveLabel).foregroundStyle(Palette.ink).lineLimit(1)
            }
            Text(expanded ? "to \(mail.to.isEmpty ? "me" : mail.to)" : snippet)
              .font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(1)
          }.frame(maxWidth: .infinity, alignment: .leading)
          if !mail.availableAttachments.isEmpty {
            Image(systemName: "paperclip").font(.coveMetadata).foregroundStyle(Palette.body)
              .accessibilityLabel("Has attachments")
          }
          Text(mail.date, format: expanded
            ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day())
            .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize()
            .help(mail.date.formatted(date: .complete, time: .shortened))
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") message from \(mail.sender)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      if expanded { actions }
    }.padding(.leading, 16).padding(.trailing, expanded ? 8 : 16).frame(minHeight: 60)
  }

  private var canReplyAll: Bool {
    MailConversation.replyAllRecipients(for: mail, accountEmail: store.accountEmail) != nil
  }
  private var snippet: String {
    mail.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
  }

  private var actions: some View {
    HStack(spacing: 0) {
      Button { onReply(mail, false) } label: {
        Image(systemName: "arrowshape.turn.up.left").frame(width: 32, height: 32).contentShape(Rectangle())
      }.buttonStyle(ReaderActionStyle()).help("Reply").accessibilityLabel("Reply to \(mail.sender)")
      Menu {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply(mail, false) }
        if canReplyAll {
          Button("Reply all", systemImage: "arrowshape.turn.up.left.2") { onReply(mail, true) }
        }
        Button("Forward", systemImage: "arrowshape.turn.up.right") { store.prepareHomeDelegation(mail) }
          .disabled(store.busy)
        Divider()
        TranslateMenu(store: store, mail: mail)
      } label: {
        Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Message actions").accessibilityLabel("Actions for message from \(mail.sender)")
    }.foregroundStyle(Palette.body)
  }
}
