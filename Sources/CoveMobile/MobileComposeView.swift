#if os(iOS)
import CoveCore
import SwiftUI
import UIKit

/// What the composer starts with: a new email, a reply to one message, or a forward.
struct MobileDraft: Identifiable {
  let id = UUID()
  var to = ""
  var cc = ""
  var subject = ""
  var body = ""
  var reply: Mail?
  var forwarding = false

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
  /// A new email that quotes the original. Attachments stay with the original (they aren't downloaded).
  init(forwarding mail: Mail) {
    forwarding = true
    subject = mail.subject.lowercased().hasPrefix("fwd:") ? mail.subject : "Fwd: " + mail.subject
    let sender = mail.sender.isEmpty ? mail.senderEmail : "\(mail.sender) <\(mail.senderEmail)>"
    body = """


    ---------- Forwarded message ---------
    From: \(sender)
    Date: \(mail.date.formatted(date: .abbreviated, time: .shortened))
    Subject: \(mail.subject)
    To: \(mail.to)

    \(mail.body)
    """
  }
}

/// The Mac's composer on a phone: To / Cc / Subject rows with fixed labels, the writing canvas, and the
/// inline "Ask Cove to write or change this…" line. A suggestion previews on the canvas with Apply and
/// Discard; Send stays disabled while one is pending, and sending waits out a 4-second Undo.
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
  @State private var askOpen = false
  @State private var confirmDiscard = false
  /// The request being written, shown read-only while Cove works (the field itself is cleared and locked).
  @State private var asked: String?
  /// Streamed text isn't re-animated when it becomes the preview (as on the Mac).
  @State private var streamed = false
  @State private var stage = ""
  @State private var voice = MobileVoice.load()
  @FocusState private var focus: Field?
  @Environment(\.dismiss) private var dismiss

  private enum Field { case to, cc, subject, body, ask }

  private var title: String { draft.forwarding ? "Forward" : draft.reply == nil ? "New message" : "Reply" }
  private var canSend: Bool {
    suggestion == nil && writing == nil && !draft.to.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(MobilePalette.line)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let account = mailbox.auth.email { staticRow("From", account) }
          field("To", text: $draft.to, field: .to, keyboard: .emailAddress) {
            if !showCc && draft.cc.isEmpty {
              Button("Cc") { showCc = true; focus = .cc }.font(.mobileControl).foregroundStyle(MobilePalette.body)
            }
          }
          if focus == .to { suggestions(for: $draft.to) }
          if showCc || !draft.cc.isEmpty { field("Cc", text: $draft.cc, field: .cc, keyboard: .emailAddress) }
          if focus == .cc { suggestions(for: $draft.cc) }
          field("Subject", text: $draft.subject, field: .subject)
          canvas.padding(.top, 14)
          if let reply = draft.reply {
            Label("Replying to \(reply.sender.isEmpty ? reply.senderEmail : reply.sender)", systemImage: "arrowshape.turn.up.left")
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).padding(.top, 12)
          }
          if draft.forwarding {
            Label("Attachments aren’t forwarded from iPhone yet.", systemImage: "paperclip")
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).padding(.top, 12)
          }
          if let sendError {
            Text(sendError).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).padding(.top, 10)
          }
        }.padding(.horizontal, 20).padding(.bottom, 24)
      }
      .scrollDismissesKeyboard(.interactively)
      askBar
    }
    .background(MobilePalette.canvas)
    .confirmationDialog("Discard this email?", isPresented: $confirmDiscard, titleVisibility: .visible) {
      Button("Discard", role: .destructive) { writing?.cancel(); dismiss() }
    }
    .onAppear { focus = draft.reply == nil ? .to : .body }
    .interactiveDismissDisabled(!draft.body.isEmpty && draft.reply == nil)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button("Cancel") {
        if draft.body.isEmpty || draft.reply != nil { close() } else { confirmDiscard = true }
      }.font(.mobileControl).foregroundStyle(MobilePalette.body)
      Spacer()
      VStack(spacing: 1) {
        Text(title).font(.mobileSection).foregroundStyle(MobilePalette.ink)
        if draft.reply != nil {
          Text("Draft saved on this iPhone").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }
      }
      Spacer()
      Button(action: send) { Label("Send", systemImage: "paperplane") }
        .buttonStyle(MobilePrimaryButton(compact: true)).disabled(!canSend)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }

  private func staticRow(_ title: String, _ value: String) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title).font(.mobileControl).foregroundStyle(MobilePalette.body).frame(width: 60, alignment: .leading)
        Text(value).font(.mobileText).foregroundStyle(MobilePalette.body).lineLimit(1)
        Spacer()
      }.padding(.vertical, 12)
      Divider().overlay(MobilePalette.line)
    }
  }

  private func field<Accessory: View>(_ title: String, text: Binding<String>, field: Field,
                                      keyboard: UIKeyboardType = .default,
                                      @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title).font(.mobileControl).foregroundStyle(MobilePalette.body).frame(width: 60, alignment: .leading)
        TextField("", text: text).font(.mobileText).foregroundStyle(MobilePalette.ink).keyboardType(keyboard)
          .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
          .autocorrectionDisabled(keyboard == .emailAddress)
          .focused($focus, equals: field)
          .accessibilityLabel(title)
        accessory()
      }.padding(.vertical, 12)
      Divider().overlay(focus == field ? MobilePalette.ink : MobilePalette.line)
    }
  }

  /// People from mail on this iPhone matching what's typed after the last comma.
  @ViewBuilder private func suggestions(for text: Binding<String>) -> some View {
    let parts = text.wrappedValue.components(separatedBy: ",")
    let current = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    let chosen = Set(parts.dropLast().flatMap { ContactDirectory.addresses($0).map { ContactDirectory.normalizedEmail($0.email) } })
    let matches = current.count >= 1 ? mailbox.contactSuggestions(current, excluding: chosen) : []
    if !matches.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(matches) { contact in
          Button {
            let kept = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let entry = contact.name == contact.email ? contact.email : "\(contact.name) <\(contact.email)>"
            text.wrappedValue = (kept + [entry]).joined(separator: ", ") + ", "
          } label: {
            HStack(spacing: 10) {
              MobileAvatar(name: contact.name, size: 28)
              VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
                Text(contact.email).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
              }
              Spacer()
              Text(contact.messages.count == 1 ? "1 email" : "\(contact.messages.count) emails")
                .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
          }.buttonStyle(MobileRowButtonStyle())
          if contact.id != matches.last?.id { Divider().overlay(MobilePalette.line).padding(.leading, 50) }
        }
      }
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(MobilePalette.line))
      .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder private var canvas: some View {
    if writing != nil && (suggestion ?? "").isEmpty {
      // Nothing returned yet: the canvas keeps the draft, quietly dimmed, under the thinking bar.
      Text(draft.body.isEmpty ? " " : draft.body).font(.mobileBody).foregroundStyle(MobilePalette.muted).lineSpacing(6)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    } else if let suggestion {
      // The suggestion previews on the canvas; the draft is unchanged until Apply.
      VStack(alignment: .leading, spacing: 14) {
        Label("Suggestion from Cove", systemImage: "sparkle").font(.mobileCaption).foregroundStyle(MobilePalette.badgeText)
        MobileRevealText(text: suggestion, animate: !streamed && writing == nil)
          .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        if writing == nil {
          HStack(spacing: 10) {
            Button("Apply draft") { draft.body = suggestion; self.suggestion = nil }
              .buttonStyle(MobilePrimaryButton(compact: true))
            Button("Discard") { self.suggestion = nil }.buttonStyle(MobileSecondaryButton(compact: true))
          }
        }
      }
      .padding(14)
      .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
    } else {
      TextField("Write your message", text: $draft.body, axis: .vertical)
        .font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(6).focused($focus, equals: .body)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    }
  }

  /// The ✦ at the left grows open into "Ask Cove to write or change this…" with writing tools.
  private var askBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      if writing != nil {
        HStack(alignment: .top, spacing: 12) {
          MobileThinkingBar(stage: stage)
          Button("Stop") { writing?.cancel() }.font(.mobileControl).foregroundStyle(MobilePalette.ink)
        }
        if let asked {
          Text("“\(asked)”").font(.mobileSecondary).foregroundStyle(MobilePalette.ink).lineLimit(2)
        }
      }
      if let aiError {
        Text(aiError).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
      }
      if (askOpen || writing != nil) && voice == nil && ai.ready && writing == nil {
        Text("Tip: Settings → Writing and Ask Cove → Learn my voice, so drafts sound like you.")
          .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      if askOpen || writing != nil {
        HStack(alignment: .bottom, spacing: 10) {
          Image(systemName: "sparkle").font(.system(size: 15, weight: .medium)).foregroundStyle(MobilePalette.ink)
            .padding(.bottom, 8).accessibilityHidden(true)
          TextField(ai.ready ? "Ask Cove to write or change this…" : "Set up AI in Settings to write with Cove",
                    text: $instruction, axis: .vertical)
            .lineLimit(1...4).font(.mobileText).focused($focus, equals: .ask)
            .padding(.vertical, 8)
            .onSubmit(write).disabled(!ai.ready || writing != nil)
          Menu {
            ForEach(["Rewrite", "Fix grammar", "Polish", "Shorten", "Make it warmer", "Make it more formal",
                     "Translate to English", "Translate to Spanish"], id: \.self) { tool in
              Button(tool) { instruction = tool; write() }
            }
          } label: {
            Image(systemName: "wand.and.stars").font(.system(size: 15)).frame(width: 34, height: 34)
          }
          .foregroundStyle(MobilePalette.ink)
          .disabled(!ai.ready || draft.body.isEmpty).accessibilityLabel("Writing tools")
          Button(action: write) {
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
              .foregroundStyle(canWrite ? Color.white : MobilePalette.disabledText)
              .frame(width: 34, height: 34)
              .background(canWrite ? MobilePalette.ink : MobilePalette.disabled, in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain).disabled(!canWrite).accessibilityLabel("Write")
          Button { askOpen = false; instruction = "" } label: { Image(systemName: "xmark").font(.system(size: 12)) }
            .foregroundStyle(MobilePalette.muted).padding(.bottom, 10).accessibilityLabel("Close")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 4)
        .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == .ask ? MobilePalette.ink : MobilePalette.inputBorder))
      } else {
        Button { askOpen = true; focus = .ask } label: {
          HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 15, weight: .medium))
              .frame(width: 34, height: 34).background(MobilePalette.sidebar, in: Circle())
            Text("Ask Cove to write or change this").font(.mobileControl)
          }.foregroundStyle(MobilePalette.ink)
        }.buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(MobilePalette.canvas)
    .overlay(alignment: .top) { Divider().overlay(MobilePalette.line) }
  }

  private var canWrite: Bool { ai.ready && writing == nil && !instruction.trimmingCharacters(in: .whitespaces).isEmpty }

  private func write() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, writing == nil else { return }
    aiError = nil
    suggestion = nil
    streamed = false
    asked = text
    instruction = ""
    focus = nil
    stage = draft.reply == nil ? "Writing with \(ai.modelLabel(ai.model(ai.provider), provider: ai.provider))…" : "Reading the conversation…"
    // Snapshot what this request is about; later edits don't change it.
    let body = draft.body
    let request = MobileWritingContext.instruction(
      text, from: (mailbox.accountName ?? MobileMe.shared.context.name, mailbox.auth.email ?? ""), to: draft.to, cc: draft.cc,
      subject: draft.subject, replying: draft.reply != nil, voice: voice, personal: MobileMe.shared.prompt)
    // The email being answered first, then the rest of its conversation, newest first.
    let mails = draft.reply.map { reply in [reply] + mailbox.conversation(for: reply).filter { $0.id != reply.id }.reversed() } ?? []
    writing = Task {
      defer { writing = nil }
      do {
        let prompt = try AIPrompt(intent: .write, instruction: request, mails: mails, draft: body)
        let result = try await ai.complete(prompt) { partial in
          streamed = true
          stage = "Writing…"
          suggestion = MobileWritingContext.clean(partial).body
        }
        try Task.checkCancellation()
        let cleaned = MobileWritingContext.clean(result)
        suggestion = cleaned.body
        if draft.subject.trimmingCharacters(in: .whitespaces).isEmpty, let subject = cleaned.subject { draft.subject = subject }
        asked = nil
      } catch is CancellationError {
        suggestion = nil
        instruction = asked ?? ""
        asked = nil
      } catch {
        instruction = asked ?? ""
        asked = nil
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
