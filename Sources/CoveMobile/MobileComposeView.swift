#if os(iOS)
import CoveCore
import SwiftUI
import UIKit

/// What the composer starts with: a new email, or a reply to one message.
struct MobileDraft: Identifiable {
  let id = UUID()
  var to = ""
  var cc = ""
  var subject = ""
  var body = ""
  var reply: Mail?

  init() {}
  init(replyingTo mail: Mail, all: Bool, accountEmail: String) {
    reply = mail
    if all, let recipients = MailConversation.replyAllRecipients(for: mail, accountEmail: accountEmail) {
      to = recipients.to
      cc = recipients.cc
    } else {
      to = MailConversation.replyRecipient(for: mail, accountEmail: accountEmail)
    }
    subject = mail.subject.lowercased().hasPrefix("re:") ? mail.subject : "Re: " + mail.subject
    body = mail.draft
  }
}

struct MobileComposeView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  @State var draft: MobileDraft
  @State private var instruction = ""
  @State private var suggestion: String?
  @State private var writing: Task<Void, Never>?
  @State private var aiError: String?
  @State private var sendError: String?
  @State private var showCc = false
  @State private var confirmDiscard = false
  @FocusState private var focus: Field?
  @Environment(\.dismiss) private var dismiss

  private enum Field { case to, cc, subject, body, ask }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          field("To", text: $draft.to, field: .to, keyboard: .emailAddress)
          if showCc || !draft.cc.isEmpty { field("Cc", text: $draft.cc, field: .cc, keyboard: .emailAddress) }
          field("Subject", text: $draft.subject, field: .subject)
          ZStack(alignment: .topLeading) {
            if let suggestion {
              // The suggestion previews on the canvas; the draft is unchanged until Apply.
              Text(suggestion).font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(5)
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                .padding(.vertical, 12).textSelection(.enabled)
            } else {
              TextField("Write your email", text: $draft.body, axis: .vertical)
                .font(.mobileBody).lineSpacing(5).focused($focus, equals: .body)
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                .padding(.vertical, 12)
            }
          }
          if let suggestion {
            HStack(spacing: 10) {
              Button("Apply") { draft.body = suggestion; self.suggestion = nil }.buttonStyle(MobilePrimaryButton())
              Button("Discard") { self.suggestion = nil }.buttonStyle(MobileSecondaryButton())
            }.padding(.bottom, 12)
          }
          if let reply = draft.reply {
            Text("Replying to \(reply.sender.isEmpty ? reply.senderEmail : reply.sender)")
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).padding(.top, 8)
          }
          if let sendError {
            Text(sendError).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).padding(.top, 8)
          }
        }.padding(.horizontal, 16)
      }
      .safeAreaInset(edge: .bottom) { askBar }
      .navigationTitle(draft.reply == nil ? "New email" : "Reply")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if draft.body.isEmpty || draft.reply != nil { close() } else { confirmDiscard = true }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send", action: send).disabled(suggestion != nil || writing != nil
            || draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if !showCc && draft.cc.isEmpty {
          ToolbarItem(placement: .secondaryAction) { Button("Add Cc") { showCc = true; focus = .cc } }
        }
      }
      .confirmationDialog("Discard this email?", isPresented: $confirmDiscard) {
        Button("Discard", role: .destructive) { dismiss() }
      }
      .onAppear { focus = draft.reply == nil ? .to : .body }
    }
    .interactiveDismissDisabled(!draft.body.isEmpty && draft.reply == nil)
  }

  private func field(_ title: String, text: Binding<String>, field: Field, keyboard: UIKeyboardType = .default) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title).font(.mobileSecondary).foregroundStyle(MobilePalette.muted).frame(width: 56, alignment: .leading)
        TextField("", text: text).font(.mobileBody).keyboardType(keyboard)
          .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
          .autocorrectionDisabled(keyboard == .emailAddress)
          .focused($focus, equals: field)
          .accessibilityLabel(title)
      }.padding(.vertical, 12)
      Divider()
    }
  }

  /// "Ask Cove to write or change this…", as in the Mac composer.
  private var askBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      if writing != nil {
        HStack(spacing: 8) { ProgressView(); Text("Writing with \(ai.modelLabel(ai.model(ai.provider), provider: ai.provider))…") }
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
      }
      if let aiError {
        Text(aiError).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Image(systemName: "sparkle").foregroundStyle(MobilePalette.badgeText).accessibilityHidden(true)
        TextField(ai.ready ? "Ask Cove to write or change this…" : "Set up AI in Settings to write with Cove",
                  text: $instruction, axis: .vertical)
          .lineLimit(1...3).font(.mobileBody).focused($focus, equals: .ask)
          .onSubmit(write).disabled(!ai.ready)
        Menu {
          ForEach(["Fix grammar", "Make it shorter", "Make it warmer", "Make it more formal", "Translate to English"], id: \.self) { tool in
            Button(tool) { instruction = tool; write() }
          }
        } label: { Image(systemName: "wand.and.stars") }
          .disabled(!ai.ready || draft.body.isEmpty).accessibilityLabel("Writing tools")
        if writing != nil {
          Button { writing?.cancel() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Stop writing")
        } else {
          Button(action: write) { Image(systemName: "arrow.up") }
            .disabled(!ai.ready || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Write")
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }.padding(12)
  }

  private func write() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, writing == nil else { return }
    aiError = nil
    suggestion = nil
    // Snapshot what this request is about; later edits don't change it.
    let body = draft.body
    // The email being answered first, then the rest of its conversation, newest first.
    let mails = draft.reply.map { reply in [reply] + mailbox.conversation(for: reply).filter { $0.id != reply.id }.reversed() } ?? []
    writing = Task {
      defer { writing = nil }
      do {
        let prompt = try AIPrompt(intent: .write, instruction: text, mails: mails, draft: body)
        let result = try await ai.complete(prompt) { partial in suggestion = partial }
        try Task.checkCancellation()
        suggestion = result.trimmingCharacters(in: .whitespacesAndNewlines)
        instruction = ""
      } catch is CancellationError {
        suggestion = nil
      } catch {
        // The draft is untouched; the attempted model stays visible.
        suggestion = nil
        aiError = error.localizedDescription + " (" + ai.modelLabel(ai.model(ai.provider), provider: ai.provider) + ")"
      }
    }
  }

  private func send() {
    sendError = nil
    let snapshot = draft
    do {
      try mailbox.send(to: snapshot.to, cc: snapshot.cc, subject: snapshot.subject, body: snapshot.body,
                       reply: snapshot.reply) { [mailbox] in
        // Undo (or a failed send) brings the email back in the composer.
        if let reply = snapshot.reply { mailbox.saveDraft(snapshot.body, for: reply) }
        mailbox.restoredDraft = snapshot
      }
      dismiss()
    } catch {
      sendError = error.localizedDescription
    }
  }

  private func close() {
    if let reply = draft.reply { mailbox.saveDraft(draft.body, for: reply) }
    writing?.cancel()
    dismiss()
  }
}
#endif
