#if os(iOS)
import CoveCore
import SwiftUI

/// The Mac's email reader (Pen `1. Cove`, reader `CQs4F`) on a phone: labels, a 20-point subject, the
/// sender header, Jev's assessment when there is one, the "Original email" with its conversation, and a
/// fixed Reply / Forward / ✦ Ask Cove bar.
struct MobileReaderView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  let workspace: MobileWorkspace
  let mailID: String
  @State private var expanded: Set<String> = []
  @State private var draft: MobileDraft?
  @State private var asking = false
  @State private var assessmentHidden = false
  @State private var showEvidence = false
  @State private var taskNotice: String?
  @State private var pickingDate = false
  /// On iPad the reader is a column: leaving an email (archive, unread, trash) is handled by the list.
  var onLeave: (() -> Void)?
  @Environment(\.dismiss) private var dismiss

  private func leave() { if let onLeave { onLeave() } else { dismiss() } }

  var body: some View {
    Group {
      if let mail = mailbox.mail(id: mailID) {
        content(mail)
      } else {
        MobileEmptyState(title: "This email is no longer here", detail: "It may have moved to Trash or another folder.")
      }
    }
    .background(MobilePalette.canvas)
  }

  private var account: String { mailbox.auth.email ?? "" }

  private func content(_ mail: Mail) -> some View {
    let thread = mailbox.conversation(for: mail)
    let linked = workspace.tasks(for: mail)
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        tags(mail)
        Text(mail.subject.isEmpty ? "(No subject)" : mail.subject)
          .font(.coveMobile(22, weight: .medium, relativeTo: .title2)).foregroundStyle(MobilePalette.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        senderHeader(mail)
        if let decision = mail.decision, !assessmentHidden { assessment(decision, mail: mail) }
        if !linked.isEmpty { linkedTasks(linked) }
        if let taskNotice {
          Label(taskNotice, systemImage: "checkmark.circle").font(.mobileSecondary).foregroundStyle(MobilePalette.body)
        }
        Divider().overlay(MobilePalette.line)
        if thread.count > 1 {
          HStack(spacing: 10) {
            Image(systemName: "envelope").font(.system(size: 15)).accessibilityHidden(true)
            Text("Conversation · \(thread.count) messages").font(.mobileSection)
          }.foregroundStyle(MobilePalette.ink)
          ForEach(thread) { message in
            MobileMessageCard(mailbox: mailbox, mail: message, accountEmail: account,
                              expanded: message.id == mail.id || expanded.contains(message.id)) {
              if expanded.contains(message.id) { expanded.remove(message.id) } else {
                expanded.insert(message.id)
                // Other messages are marked read only when opened (as on the Mac).
                mailbox.setRead(message, true)
              }
            } reply: { all in draft = MobileDraft(replyingTo: message, all: all, accountEmail: account) }
          }
        } else {
          MobileEmailBody(mail: mail)
          MobileAttachmentList(mailbox: mailbox, mail: mail)
        }
      }
      .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) { responseBar(mail) }
    .navigationBarTitleDisplayMode(.inline)
    // The reader owns the bottom edge (Reply / Forward / Ask Cove), as on the Mac.
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if mail.labels.contains("INBOX") {
          Button { mailbox.archive(mail); leave() } label: { Label("Archive", systemImage: "archivebox") }
        } else {
          Button { mailbox.moveToInbox(mail) } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
        }
        if mail.labels.contains("INBOX") || mailbox.isSnoozed(mail) {
          Menu {
            MobileSnoozeChoices(mail: mail, mailbox: mailbox, onChosen: { leave() }, pickDate: { pickingDate = true })
            Text(MobileSnoozeCopy.footer(mailbox.snoozeNotificationsAllowed))
          } label: { Label("Snooze", systemImage: "clock") }
        }
        Button { mailbox.setRead(mail, false); leave() } label: { Label("Mark unread", systemImage: "envelope.badge") }
        Menu {
          Button { mailbox.toggleStar(mail) } label: {
            Label(mail.isStarred ? "Remove follow-up flag" : "Flag for follow-up", systemImage: mail.isStarred ? "flag.slash" : "flag")
          }
          if workspace.auth.tasksConnected {
            Button { createTask(mail) } label: { Label("Create task", systemImage: "checklist") }
          }
          Button { draft = MobileDraft(forwarding: mail) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
          if PushSettings.shared.enabled {
            Menu {
              let rule = MobilePush.shared.rule(for: mail.senderEmail)
              Button { MobilePush.shared.alwaysNotify(mail.senderEmail) } label: {
                Label("Always notify", systemImage: rule == "always" ? "checkmark" : "bell.badge")
              }
              Button { MobilePush.shared.mute(mail.senderEmail) } label: {
                Label("Mute notifications", systemImage: rule == "muted" ? "checkmark" : "bell.slash")
              }
              if rule != nil { Button("Use the usual rules") { MobilePush.shared.resetSender(mail.senderEmail) } }
            } label: { Label("Notifications from \(mail.sender.isEmpty ? mail.senderEmail : mail.sender)", systemImage: "bell") }
          }
          if assessmentHidden, mail.decision != nil {
            Button { assessmentHidden = false } label: { Label("Show Jev assessment", systemImage: "sparkles") }
          }
          Divider()
          Button(role: .destructive) { mailbox.trash(mail); leave() } label: { Label("Move to Trash", systemImage: "trash") }
        } label: { Label("More", systemImage: "ellipsis") }
      }
    }
    .onAppear {
      mailbox.setRead(mail, true)
      MobilePush.shared.clearNotification(for: mail.id)
    }
    .sheet(item: $draft) { draft in MobileComposeView(mailbox: mailbox, ai: ai, draft: draft) }
    .sheet(isPresented: $pickingDate) { MobileSnoozeDatePicker(mail: mail, mailbox: mailbox, onChosen: { leave() }) }
    .sheet(isPresented: $asking) {
      MobileAskCoveView(ai: ai, mailbox: mailbox, mail: mail, thread: thread) { text in
        asking = false
        var reply = MobileDraft(replyingTo: mail, all: false, accountEmail: account)
        reply.body = text
        draft = reply
      }
    }
  }

  // MARK: Header

  private func tags(_ mail: Mail) -> some View {
    HStack(spacing: 8) {
      if mail.labels.contains("INBOX") { MobileTag(text: "Inbox") }
      else if mail.labels.contains("SENT") { MobileTag(text: "Sent") }
      else if mail.labels.contains("DRAFT") { MobileTag(text: "Draft") }
      else { MobileTag(text: "Archived") }
      if mail.labels.contains("INBOX") {
        MobileTag(text: InboxSplit.split(mail).title, fill: MobilePalette.canvas)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(MobilePalette.line))
      }
      if mail.isStarred { MobileTag(text: "Flagged", systemImage: "flag.fill") }
    }
  }

  private func senderHeader(_ mail: Mail) -> some View {
    HStack(alignment: .top, spacing: 12) {
      MobileAvatar(mail: mail, size: 40)
      VStack(alignment: .leading, spacing: 3) {
        Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender).font(.mobileSection).foregroundStyle(MobilePalette.ink)
        Text(mail.senderEmail + " · to " + (mail.to.isEmpty || mail.to.localizedCaseInsensitiveContains(account) ? "me" : mail.to))
          .font(.mobileSecondary).foregroundStyle(MobilePalette.body).lineLimit(2).textSelection(.enabled)
        Text(mail.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
          .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: Jev

  private func assessment(_ decision: Decision, mail: Mail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(mailbox.auth.isSample ? "Sample assessment" : "Jev’s assessment", systemImage: "sparkles").font(.mobileControl)
        Spacer()
        Text(decision.urgent >= 0.65 ? "May be time-sensitive" : decision.urgent >= 0.35 ? "Timing unclear" : "Low urgency")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.body)
      }
      Text(decision.needsReply >= 0.65 ? "Reply or action likely" : decision.needsReply >= 0.35 ? "Review for next steps" : "Likely informational")
        .font(.mobileSection)
      if let excerpt = decision.excerpt, !excerpt.isEmpty {
        Text(excerpt).font(.mobileBody).lineSpacing(5).foregroundStyle(MobilePalette.body).textSelection(.enabled)
        Text("Selected from the original email").font(.mobileMetadata).foregroundStyle(MobilePalette.body)
      }
      HStack(spacing: 10) {
        Button { mailbox.toggleStar(mail) } label: {
          Label(mail.isStarred ? "Flagged" : "Flag for follow-up", systemImage: mail.isStarred ? "flag.fill" : "flag")
        }.buttonStyle(MobileSecondaryButton(compact: true))
        if workspace.auth.tasksConnected && decision.needsReply >= 0.35 && workspace.tasks(for: mail).isEmpty {
          Button { createTask(mail) } label: { Label("Create task", systemImage: "checklist") }
            .buttonStyle(MobileSecondaryButton(compact: true))
        }
      }
      HStack(spacing: 16) {
        Button(showEvidence ? "Hide details" : "Why this?") { showEvidence.toggle() }
        Button("Hide") { assessmentHidden = true }
      }.buttonStyle(.plain).font(.mobileSecondary).foregroundStyle(MobilePalette.body)
      if showEvidence {
        Divider()
        Text("Jev estimates a \(Int(decision.needsReply * 100))% likelihood of needing action and a \(Int(decision.urgent * 100))% likelihood of action within 24 hours. These are model assessments, not a verified deadline.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(MobilePalette.ink)
    .background(MobilePalette.assessment, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(MobilePalette.assessmentBorder))
  }

  private func linkedTasks(_ tasks: [GoogleTask]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Tasks from this conversation", systemImage: "checklist").font(.mobileControl).foregroundStyle(MobilePalette.ink)
      ForEach(tasks) { task in
        HStack(spacing: 10) {
          Button { Task { await workspace.setCompleted(task, true) } } label: {
            Image(systemName: "circle").font(.system(size: 18)).foregroundStyle(MobilePalette.inputBorder)
          }.buttonStyle(.plain).accessibilityLabel("Mark \(task.title) done")
          Text(task.title).font(.mobileText).foregroundStyle(MobilePalette.ink)
          Spacer()
          if let due = task.dueDay { Text(MobileDates.section(due)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted) }
        }
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(MobilePalette.line))
  }

  // MARK: Response bar

  private func responseBar(_ mail: Mail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if Self.isNoReply(mail.senderEmail) {
        Text("Sender uses a no-reply address.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      HStack(spacing: 10) {
        Button { draft = MobileDraft(replyingTo: mail, all: false, accountEmail: account) } label: {
          Label(mail.draft.isEmpty ? "Reply" : "Edit draft", systemImage: "arrowshape.turn.up.left")
        }.buttonStyle(MobilePrimaryButton())
        if MailConversation.replyAllRecipients(for: mail, accountEmail: account) != nil {
          Button { draft = MobileDraft(replyingTo: mail, all: true, accountEmail: account) } label: {
            Image(systemName: "arrowshape.turn.up.left.2")
          }.buttonStyle(MobileSecondaryButton()).accessibilityLabel("Reply all")
        }
        Button { draft = MobileDraft(forwarding: mail) } label: {
          Label("Forward", systemImage: "arrowshape.turn.up.right")
        }.buttonStyle(MobileSecondaryButton())
        Spacer(minLength: 0)
        Button { asking = true } label: {
          Image(systemName: "sparkle").font(.system(size: 18, weight: .medium)).foregroundStyle(MobilePalette.ink)
            .frame(width: 44, height: 44).background(MobilePalette.sidebar, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Ask Cove about this email")
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    .background(MobilePalette.canvas)
    .overlay(alignment: .top) { Divider().overlay(MobilePalette.line) }
  }

  private func createTask(_ mail: Mail) {
    Task {
      if await workspace.createTask(from: mail, accountEmail: account) {
        taskNotice = "Added to Google Tasks"
      } else {
        taskNotice = workspace.tasksError
      }
    }
  }

  static func isNoReply(_ address: String) -> Bool {
    let lower = address.lowercased()
    return lower.contains("no-reply") || lower.contains("noreply") || lower.contains("donotreply") || lower.contains("do-not-reply")
  }
}

/// The email's text with the Mac's reading spacing (Inter, 6-point extra leading, bounded width).
struct MobileMessageBody: View {
  let mail: Mail
  var body: some View {
    Text(mail.body.isEmpty ? "(This email has no text.)" : mail.body)
      .font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(6)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One message of a conversation, as the Mac's conversation cards: a header, and the text when expanded.
struct MobileMessageCard: View {
  let mailbox: MobileMailbox
  let mail: Mail
  let accountEmail: String
  let expanded: Bool
  let toggle: () -> Void
  let reply: (_ all: Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: toggle) {
        HStack(alignment: .top, spacing: 10) {
          MobileAvatar(mail: mail, size: 32)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              if mail.isUnread { Circle().fill(MobilePalette.ink).frame(width: 7, height: 7) }
              Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender)
                .font(.coveMobile(14, weight: mail.isUnread ? .semibold : .medium)).foregroundStyle(MobilePalette.ink)
            }
            Text(expanded ? "to " + (mail.to.isEmpty ? "me" : mail.to) : String(mail.body.prefix(90)).replacingOccurrences(of: "\n", with: " "))
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
          }
          Spacer()
          Text(MobileDates.short(mail.date)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          if !mail.availableAttachments.isEmpty {
            Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(MobilePalette.muted)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityHint(expanded ? "Collapse this message" : "Expand this message")
      if expanded {
        MobileEmailBody(mail: mail, heading: mail.htmlBody?.isEmpty == false)
        MobileAttachmentList(mailbox: mailbox, mail: mail)
        HStack(spacing: 10) {
          Button { reply(false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            .buttonStyle(MobileSecondaryButton(compact: true))
          if MailConversation.replyAllRecipients(for: mail, accountEmail: accountEmail) != nil {
            Button { reply(true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
              .buttonStyle(MobileSecondaryButton(compact: true))
          }
        }
      }
    }
    .padding(16)
    .background(expanded ? MobilePalette.canvas : MobilePalette.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }
}

/// "Ask about this email": the Mac's inline Ask Cove panel as a sheet, with suggested questions, an
/// answer container and a composer. Nothing is sent without the user's approval.
struct MobileAskCoveView: View {
  let ai: MobileAI
  let mailbox: MobileMailbox
  let mail: Mail
  let thread: [Mail]
  var draftReply: ((String) -> Void)?
  @State private var question = ""
  @State private var answer = ""
  @State private var asked = ""
  @State private var running: Task<Void, Never>?
  @State private var drafting = false
  @State private var error: String?
  @State private var readingFiles = false
  @State private var filesRead = 0
  @Environment(\.dismiss) private var dismiss

  private let suggestions = ["What needs my attention?", "Which dates are mentioned?", "Summarize this conversation"]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "sparkle").font(.system(size: 16, weight: .medium))
        Text("Ask about this email").font(.mobileSection)
        Spacer()
        Button { running?.cancel(); dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(MobileIconButton()).accessibilityLabel("Close")
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
      Divider().overlay(MobilePalette.line)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if asked.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                  Button(suggestion) { question = suggestion; ask() }
                    .buttonStyle(MobileSecondaryButton(compact: true)).disabled(!ai.ready)
                }
              }
            }
            if !ai.ready {
              Text("Choose an AI model in Settings → AI models to ask Cove. Apple Intelligence works on this iPhone with no account.")
                .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text(asked).font(.mobileText).foregroundStyle(MobilePalette.ink)
              .padding(.horizontal, 14).padding(.vertical, 10)
              .background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
              .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 14) {
              if running != nil && answer.isEmpty {
                HStack(spacing: 8) { ProgressView(); Text(drafting ? "Writing a reply…" : readingFiles ? "Reading attachments…" : "Reading this email…") }
                  .font(.mobileSecondary).foregroundStyle(MobilePalette.body)
              }
              if !answer.isEmpty {
                Text(Self.markdown(answer)).font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(4)
                  .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              }
              if !answer.isEmpty, filesRead > 0, running == nil {
                Label("Read \(filesRead) attachment\(filesRead == 1 ? "" : "s")", systemImage: "paperclip")
                  .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
              }
              if let error {
                Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
              }
              if running == nil, !answer.isEmpty, !drafting, draftReply != nil {
                HStack(spacing: 10) {
                  Button { writeReply() } label: { Label("Draft reply", systemImage: "square.and.pencil") }
                    .buttonStyle(MobileSecondaryButton(compact: true))
                  Button { UIPasteboard.general.string = answer } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(MobileSecondaryButton(compact: true))
                }
              }
              Text("Sources: this email\(thread.count > 1 ? " and \(thread.count - 1) more in the conversation" : "") · \(ai.modelLabel(ai.model(ai.provider), provider: ai.provider))")
                .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MobilePalette.line))
          }
        }.padding(20)
      }
      VStack(spacing: 10) {
        HStack(alignment: .bottom, spacing: 10) {
          TextField("Ask about this email…", text: $question, axis: .vertical)
            .lineLimit(1...4).font(.mobileBody).onSubmit(ask)
          Button(action: running == nil ? ask : { running?.cancel() }) {
            Image(systemName: running == nil ? "arrow.up" : "stop.fill").font(.system(size: 14, weight: .semibold))
              .foregroundStyle(canAsk || running != nil ? Color.white : MobilePalette.disabledText)
              .frame(width: 34, height: 34)
              .background(canAsk || running != nil ? MobilePalette.ink : MobilePalette.disabled, in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain).disabled(!canAsk && running == nil)
            .accessibilityLabel(running == nil ? "Ask" : "Stop")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MobilePalette.inputBorder))
        Label("Nothing is sent without your approval.", systemImage: "checkmark.shield")
          .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
    }
    .background(MobilePalette.canvas)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var canAsk: Bool { ai.ready && !question.trimmingCharacters(in: .whitespaces).isEmpty }

  private func ask() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, running == nil, ai.ready else { return }
    asked = text
    question = ""
    // "Remember …" / "Forget …" edit About you directly; no model is asked.
    if let command = PersonalContext.command(in: text) {
      answer = MobileMe.shared.handle(command)
      return
    }
    run(.answer, instruction: text)
  }

  private func writeReply() {
    drafting = true
    run(.write, instruction: "Write a reply to this email. Use what was just discussed: \(String(answer.prefix(800)))") { text in
      draftReply?(text)
    }
  }

  private func run(_ intent: AIIntent, instruction: String, then: ((String) -> Void)? = nil) {
    answer = intent == .answer ? "" : answer
    error = nil
    // The selected email first, then the rest of the conversation, newest first.
    let mails = [mail] + thread.filter { $0.id != mail.id }.reversed()
    running = Task {
      defer { running = nil; drafting = false }
      do {
        // Questions about this email also see its PDFs and text files (amounts, capture lines, dates).
        var files: [AgentAttachmentText] = []
        var notes: [String] = []
        if intent == .answer, mail.availableAttachments.contains(where: AttachmentText.readable) {
          readingFiles = true
          defer { readingFiles = false }
          do { (files, notes) = try await mailbox.attachmentTexts(mail) }
          catch is CancellationError { throw CancellationError() }
          catch { notes = ["Attachments couldn’t be read: " + error.localizedDescription] }
        }
        filesRead = files.count
        let evidence = (MobileMe.shared.prompt ?? "") + (notes.isEmpty ? "" : "\nAttachment notes: " + notes.joined(separator: " "))
        let prompt = try AIPrompt(intent: intent, instruction: instruction, mails: mails, evidence: evidence, files: files)
        let result = try await ai.complete(prompt) { partial in if intent == .answer { answer = partial } }
        if intent == .answer { answer = result } else { then?(result.trimmingCharacters(in: .whitespacesAndNewlines)) }
      } catch is CancellationError {
      } catch {
        self.error = error.localizedDescription + " (" + ai.modelLabel(ai.model(ai.provider), provider: ai.provider) + ")"
      }
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
#endif
