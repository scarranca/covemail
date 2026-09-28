import CoveCore
import SwiftUI

struct ReaderConversation: View {
  let store: AppStore
  let anchor: Mail
  let onReply: (Mail) -> Void
  @State private var loading = false
  @State private var failure: String?
  @State private var retry = 0
  private var messages: [Mail] { MailConversation.messages(in: store.mails, anchor: anchor) }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !anchor.threadID.isEmpty && !anchor.labels.contains("DRAFT") {
        HStack(spacing: 8) {
          Label("Conversation", systemImage: "bubble.left.and.bubble.right").font(.coveSubheading)
          Text("\(messages.count) \(messages.count == 1 ? "message" : "messages")").font(.coveSecondary).foregroundStyle(Palette.body)
          Spacer(minLength: 0)
          if loading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing conversation") }
        }
        if let failure {
          VStack(alignment: .leading, spacing: 8) {
            Text("Showing downloaded messages. \(failure)").font(.coveSecondary).foregroundStyle(Palette.body)
              .fixedSize(horizontal: false, vertical: true)
            Button("Retry conversation") { retry += 1 }.buttonStyle(SecondaryButton(compact: true))
          }
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
      loading = !store.isSample && !anchor.threadID.isEmpty && !anchor.labels.contains("DRAFT")
      failure = nil
      defer { loading = false }
      do { try await store.refreshReaderThread(anchor) }
      catch is CancellationError { }
      catch { if !Task.isCancelled { failure = "The rest of the conversation couldn’t load. Try again." } }
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
      if !mail.labels.contains("DRAFT") {
        Menu {
          ForEach(["English", "Spanish", "French", "German", "Portuguese", "Japanese"], id: \.self) { language in
            Button(language) { store.askAboutEmail(mail, question: "Translate the selected email into \(language). Preserve its meaning and distinguish the translation from the original email.") }
          }
        } label: { Label("Translate", systemImage: "character.bubble") }
          .menuStyle(.borderlessButton).fixedSize().font(.coveControl)
          .help("Prepare a translation request in Ask Cove using your connected writing model")
      }
    }
  }
}

struct ReaderThreadMessage: View {
  let store: AppStore
  let mail: Mail
  let selected: Bool
  let onReply: (Mail) -> Void
  @State private var expanded: Bool
  init(store: AppStore, mail: Mail, selected: Bool, onReply: @escaping (Mail) -> Void) {
    self.store = store; self.mail = mail; self.selected = selected; self.onReply = onReply
    _expanded = State(initialValue: selected)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Divider()
      Button {
        expanded.toggle()
        if expanded { Task { await store.markViewed(mail) } }
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.coveMetadata).frame(width: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
              Text(mail.sender).font(.coveSubheading).foregroundStyle(Palette.ink)
              Text(mail.senderEmail).font(.coveSecondary).foregroundStyle(Palette.body)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
              Text(mail.date, format: .dateTime.month(.abbreviated).day()).font(.coveMetadata)
              if selected { Text("Selected").font(.coveMetadata) }
              else if mail.isUnread { Text("Unread").font(.coveMetadata) }
              if !mail.availableAttachments.isEmpty { Image(systemName: "paperclip").font(.coveMetadata) }
            }.foregroundStyle(Palette.body)
          }
          if !expanded {
            Text(mail.body.replacingOccurrences(of: "\n", with: " ")).font(.coveSecondary).foregroundStyle(Palette.body)
              .lineLimit(2).padding(.leading, 22)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "Collapse" : "Expand") message from \(mail.sender)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      if expanded {
        Text("To \(mail.to.isEmpty ? "me" : mail.to) · \(mail.date.formatted(date: .abbreviated, time: .shortened))")
          .font(.coveMetadata).foregroundStyle(Palette.body).textSelection(.enabled)
        ReaderMessageContent(store: store, mail: mail)
        Button { onReply(mail) } label: { Label("Reply to this message", systemImage: "arrowshape.turn.up.left") }
          .buttonStyle(SecondaryButton(compact: true))
      }
    }
  }
}
