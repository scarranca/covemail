#if os(iOS)
import CoveCore
import SwiftUI

struct MobileReaderView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  let mailID: String
  @State private var expanded: Set<String> = []
  @State private var reply: MobileDraft?
  @State private var asking = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let mail = mailbox.mail(id: mailID) {
        content(mail)
      } else {
        ContentUnavailableView("This email is no longer here", systemImage: "tray")
      }
    }
    .background(MobilePalette.canvas)
  }

  private func content(_ mail: Mail) -> some View {
    let thread = mailbox.conversation(for: mail)
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(mail.subject.isEmpty ? "(No subject)" : mail.subject)
          .font(.mobileDetailTitle).foregroundStyle(MobilePalette.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        ForEach(thread) { message in
          MobileMessageCard(mail: message, accountEmail: mailbox.auth.email ?? "",
                            expanded: message.id == mail.id || expanded.contains(message.id)) {
            if expanded.contains(message.id) { expanded.remove(message.id) } else {
              expanded.insert(message.id)
              // Other messages are marked read only when opened (as on the Mac).
              mailbox.setRead(message, true)
            }
          } reply: { all in reply = MobileDraft(replyingTo: message, all: all, accountEmail: mailbox.auth.email ?? "") }
        }
      }
      .padding(16)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { mailbox.setRead(mail, true) }
    .toolbar {
      ToolbarItemGroup(placement: .bottomBar) {
        Button { reply = MobileDraft(replyingTo: mail, all: false, accountEmail: mailbox.auth.email ?? "") } label: {
          Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        Spacer()
        if mail.labels.contains("INBOX") {
          Button { mailbox.archive(mail); dismiss() } label: { Label("Archive", systemImage: "archivebox") }
        } else {
          Button { mailbox.moveToInbox(mail) } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
        }
        Spacer()
        Button { asking = true } label: { Label("Ask Cove", systemImage: "sparkle") }
        Spacer()
        Menu {
          Button { mailbox.toggleStar(mail) } label: {
            Label(mail.isStarred ? "Unstar" : "Star", systemImage: mail.isStarred ? "star.slash" : "star")
          }
          Button { mailbox.setRead(mail, false); dismiss() } label: { Label("Mark as unread", systemImage: "envelope.badge") }
          Button(role: .destructive) { mailbox.trash(mail); dismiss() } label: { Label("Move to Trash", systemImage: "trash") }
        } label: { Label("More", systemImage: "ellipsis") }
      }
    }
    .sheet(item: $reply) { draft in MobileComposeView(mailbox: mailbox, ai: ai, draft: draft) }
    .sheet(isPresented: $asking) { MobileAskCoveView(ai: ai, mail: mail, thread: thread) }
  }
}

/// One message of a conversation: a header, and the text when expanded.
struct MobileMessageCard: View {
  let mail: Mail
  let accountEmail: String
  let expanded: Bool
  let toggle: () -> Void
  let reply: (_ all: Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: toggle) {
        HStack(alignment: .top, spacing: 10) {
          MobileAvatar(mail: mail)
          VStack(alignment: .leading, spacing: 2) {
            Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender).font(.mobileLabel).foregroundStyle(MobilePalette.ink)
            Text(expanded ? "to " + (mail.to.isEmpty ? "me" : mail.to) : String(mail.body.prefix(90)))
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
          }
          Spacer()
          Text(mail.date.formatted(date: .abbreviated, time: .shortened))
            .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Text(mail.body.isEmpty ? "(This email has no text.)" : mail.body)
          .font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(5)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if !mail.availableAttachments.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(mail.availableAttachments) { attachment in
              Label(attachment.filename, systemImage: "paperclip").font(.mobileSecondary)
                .foregroundStyle(MobilePalette.body)
            }
            Text("Open attachments in Gmail or Cove on the Mac.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
        }
        HStack(spacing: 10) {
          Button("Reply") { reply(false) }.buttonStyle(MobileSecondaryButton())
          if MailConversation.replyAllRecipients(for: mail, accountEmail: accountEmail) != nil {
            Button("Reply all") { reply(true) }.buttonStyle(MobileSecondaryButton())
          }
        }
      }
    }
    .padding(16)
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(MobilePalette.line))
  }
}

/// Ask Cove about the open email.
struct MobileAskCoveView: View {
  let ai: MobileAI
  let mail: Mail
  let thread: [Mail]
  @State private var question = ""
  @State private var answer = ""
  @State private var asked = ""
  @State private var running: Task<Void, Never>?
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if !asked.isEmpty {
            Text(asked).font(.mobileLabel).foregroundStyle(MobilePalette.body)
          }
          if running != nil && answer.isEmpty {
            HStack(spacing: 8) { ProgressView(); Text("Reading this email…") }
              .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
          }
          if !answer.isEmpty {
            Text(Self.markdown(answer)).font(.mobileBody).foregroundStyle(MobilePalette.ink)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          if let error {
            Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger)
          }
          if asked.isEmpty && error == nil {
            Text("Ask about this email: what it needs from you, the dates in it, or how to reply.")
              .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
          }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom) {
        HStack(spacing: 10) {
          TextField("Ask Cove about this email…", text: $question, axis: .vertical)
            .lineLimit(1...4).font(.mobileBody)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 20))
            .onSubmit(ask)
          Button(action: ask) { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
            .buttonStyle(.glassProminent)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || running != nil)
            .accessibilityLabel("Ask")
        }.padding(12)
      }
      .navigationTitle("Ask Cove").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { running?.cancel(); dismiss() } }
        ToolbarItem(placement: .status) {
          Text(ai.modelLabel(ai.model(ai.provider), provider: ai.provider)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func ask() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, running == nil else { return }
    asked = text
    question = ""
    answer = ""
    error = nil
    // The selected email first, then the rest of the conversation, newest first.
    let mails = [mail] + thread.filter { $0.id != mail.id }.reversed()
    running = Task {
      defer { running = nil }
      do {
        let prompt = try AIPrompt(intent: .answer, instruction: text, mails: mails)
        let result = try await ai.complete(prompt) { partial in answer = partial }
        answer = result
      } catch is CancellationError {
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
#endif
