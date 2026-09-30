import CoveCore
import SwiftUI

/// The live Pen reader separates message identity, Jev evidence, original content, and response actions.
struct ReaderView: View {
  @Bindable var store: AppStore
  let mail: Mail
  @State private var reply = ""
  @State private var replyTarget: Mail?
  @State private var showReply = false
  @State private var replyAll = false
  @State private var writingActivity = WritingActivity()
  @State private var replyBeforeSuggestion: String?
  @State private var assessmentHidden = false
  @State private var showEvidence = false
  @State private var replyFocusRequest = 0
  @State private var replySelection = NSRange(location: 0, length: 0)
  @State private var aiOpen = false
  var current: Mail { store.mails.first { $0.id == mail.id } ?? mail }
  private var replySource: Mail { replyTarget.map { target in store.mails.first { $0.id == target.id } ?? target } ?? current }
  private var replyAllRecipients: (to: String, cc: String)? {
    MailConversation.replyAllRecipients(for: replySource, accountEmail: store.accountEmail)
  }
  private var replyingToAll: Bool { replyAll && replyAllRecipients != nil }
  private var replyRecipient: String {
    replyingToAll ? replyAllRecipients!.to : MailConversation.replyRecipient(for: replySource, accountEmail: store.accountEmail)
  }
  private var replyCc: String { replyingToAll ? replyAllRecipients!.cc : "" }
  private func updateReply(_ value: String) {
    reply = value
    store.saveReply(id: replySource.id, text: value)
  }
  private var position: Int? { store.visible.firstIndex { $0.id == mail.id } }
  private var localDraft: Bool { current.labels.contains("DRAFT") && current.id.hasPrefix("local-") }
  private var conversationCount: Int { MailConversation.messages(in: store.mails, anchor: current).count }
  private var isConversation: Bool { conversationCount > 1 }

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        toolbar(compact: false)
        toolbar(compact: true)
      }.padding(.horizontal, 24).frame(height: 64)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            identity
            if let decision = current.decision, !assessmentHidden {
              assessment(decision)
            }
            Divider()
            ReaderConversation(store: store, anchor: current) { message, all in
              store.saveReply(id: replySource.id, text: reply)
              replyTarget = message
              reply = message.draft
              replyAll = all
              showReply = true
              Task { @MainActor in
                await Task.yield()
                proxy.scrollTo("reply", anchor: .bottom)
                replyFocusRequest += 1
              }
            }
            if !localDraft && (showReply || !replySource.draft.isEmpty) {
              replyEditor.id("reply")
              Label("You have the final say. Nothing sends without you.", systemImage: "checkmark.shield")
                .font(.coveMetadata).foregroundStyle(Palette.muted)
            }
          }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        Divider()
        responseBar { all in
          replyAll = all
          if localDraft {
            store.composeID = current.id; store.showComposer = true
          } else {
            showReply = true
            // Wait for the editor to participate in layout before revealing it.
            Task { @MainActor in
              await Task.yield()
              proxy.scrollTo("reply", anchor: .bottom)
              replyFocusRequest += 1
            }
          }
        }
      }
    }.background(Palette.canvas).foregroundStyle(Palette.ink)
    .onAppear {
      reply = current.draft; showReply = !reply.isEmpty
      let opened = current
      Task { await store.markViewed(opened) }
      // Jev checks eligible mail once for promises or requests; marketing and automated mail are skipped.
      Task { await store.checkForTasks(opened) }
    }
    .task { if !store.isSample { await AIProviderSettings.shared.restoreWritingConnection() } }
  }

  private func toolbar(compact: Bool) -> some View {
    HStack(spacing: compact ? 4 : 10) {
      Button { Task { await store.archive(current) } } label: {
        actionLabel("Archive", icon: "archivebox", compact: compact)
      }.disabled(store.busy).help("Archive email")
      snoozeMenu(compact: compact)
      Button {
        Task { await store.modify(current, add: current.isUnread ? [] : ["UNREAD"], remove: current.isUnread ? ["UNREAD"] : []) }
      } label: {
        actionLabel(current.isUnread ? "Mark read" : "Mark unread", icon: current.isUnread ? "envelope.open" : "envelope", compact: compact)
      }.disabled(store.busy)
      moreMenu(compact: compact)
      if current.taskCheck?.found == true && current.taskCheck?.createdTaskIDs == nil {
        Button { store.taskSuggestionMail = current } label: {
          actionLabel("Create tasks", icon: "checklist", compact: compact)
        }.help("Jev found a follow-up task in this email").accessibilityLabel("Create tasks from this email")
      }
      Spacer(minLength: 8)
      if let position {
        Text("\(position + 1) of \(store.visible.count)").font(.coveSecondary).fixedSize()
      }
      Button { store.moveSelection(by: -1) } label: { actionLabel("Previous email (↑)", icon: "chevron.up", compact: true) }
        .disabled(position == nil || position == 0).help("Previous email (↑)")
      Button { store.moveSelection(by: 1) } label: { actionLabel("Next email (↓)", icon: "chevron.down", compact: true) }
        .disabled(position == nil || position == store.visible.count - 1).help("Next email (↓)")
    }.buttonStyle(ReaderActionStyle()).foregroundStyle(Palette.body)
  }

  private func actionLabel(_ title: String, icon: String, compact: Bool) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icon).font(.system(size: 16)).accessibilityHidden(true)
      if !compact { Text(title).font(.coveControl).fixedSize() }
    }.frame(minWidth: compact ? 32 : 0, minHeight: 40)
      .padding(.horizontal, compact ? 0 : 9).contentShape(Rectangle()).accessibilityLabel(title)
  }

  private func snoozeMenu(compact: Bool = false, title: String = "Snooze") -> some View {
    Menu {
      Button("In one hour") { store.snooze(current, until: Date().addingTimeInterval(3600)) }
      Button("Tomorrow morning") {
        store.snoozeUntilTomorrowMorning(current)
      }
      if current.snoozedUntil != nil || store.cloudSnoozes.pending[current.id] != nil {
        Button("Return to inbox") { store.snooze(current, until: nil) }
      }
      Divider()
      Text(store.snoozeSyncDetail(for: current))
      Text("Notifications are not available yet")
    } label: { actionLabel(title, icon: "clock", compact: compact) }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .padding(.horizontal, title == "Remind me" ? 12 : 0).frame(height: 40)
      .background(title == "Remind me" ? Palette.canvas : .clear, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(title == "Remind me" ? Palette.inputBorder : .clear))
      .disabled(store.busy).help("\(title)").accessibilityLabel(title)
  }

  private func moreMenu(compact: Bool) -> some View {
    Menu {
      Button(current.isStarred ? "Remove follow-up flag" : "Flag for follow-up", systemImage: current.isStarred ? "flag.fill" : "flag") {
        Task { await store.toggleFlag(current) }
      }.disabled(current.labels.contains("DRAFT"))
      Button("Find tasks", systemImage: "checklist") { store.taskSuggestionMail = current }
        .disabled(current.labels.contains("DRAFT") || store.isSample)
      Button("Assess with Jev", systemImage: "sparkles") {
        assessmentHidden = false
        Task { await store.classify(current) }
      }
      if assessmentHidden { Button("Show Jev assessment") { assessmentHidden = false } }
      if !isConversation { TranslateMenu(store: store, mail: current) }
      InboxSplitMenuItems(store: store, mail: current)
      Divider()
      Button("Move to Trash", systemImage: "trash", role: .destructive) { store.queueTrash(current) }
    } label: { actionLabel("More", icon: "ellipsis", compact: compact) }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .disabled(store.busy).help("More message options · Move to Trash (⌘⌫)").accessibilityLabel("More message options")
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 16) {
      MailLabelChips(store: store, mail: current)
      Text(current.subject.isEmpty ? "New message" : current.subject).font(.coveTitle)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if isConversation {
        Text("\(conversationCount) messages").font(.coveSecondary).foregroundStyle(Palette.body)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { sender; Spacer(minLength: 12); date }
          VStack(alignment: .leading, spacing: 8) { sender; date.padding(.leading, 52) }
        }
      }
      if let attribution = store.labelAttribution(for: current) {
        Label(attribution, systemImage: "sparkles").font(.coveSecondary).foregroundStyle(Palette.body)
      }
    }
  }

  private var sender: some View {
    HStack(spacing: 12) {
      Text(current.initials).font(.coveLabel).foregroundStyle(Palette.body)
        .frame(width: 40, height: 40).background(Palette.sidebar, in: Circle()).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(current.sender).font(.coveSubheading)
          if current.isStarred { Image(systemName: "flag.fill").font(.coveMetadata).help("Flagged for follow-up") }
        }
        Text("\(current.senderEmail) · to \(current.to.isEmpty ? "me" : current.to)")
          .font(.coveSecondary).foregroundStyle(Palette.body).textSelection(.enabled)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }
  private var date: some View {
    Text(current.date, format: .dateTime.month(.abbreviated).day().hour().minute())
      .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize()
      .help(current.date.formatted(date: .complete, time: .complete))
  }

  private func assessment(_ decision: Decision) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack { assessmentHeading; Spacer(); urgency(decision) }
        VStack(alignment: .leading, spacing: 8) { assessmentHeading; urgency(decision) }
      }
      Text(decision.needsReply >= 0.65 ? "Reply or action likely" : decision.needsReply >= 0.35 ? "Review for next steps" : "Likely informational")
        .font(.coveSection)
      if let excerpt = decision.excerpt, !excerpt.isEmpty {
        Text(excerpt).font(.coveBody).lineSpacing(6).foregroundStyle(Palette.body).textSelection(.enabled)
        Text("Selected from the original email").font(.coveMetadata).foregroundStyle(Palette.body)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { assessmentActions; Spacer(minLength: 8); evidenceActions }
        VStack(alignment: .leading, spacing: 10) { assessmentActions; evidenceActions }
      }
      if showEvidence {
        Divider()
        JevMailFlagBadges(mail: current, isSample: store.isSample)
        Text("Jev estimates a \(Int(decision.needsReply * 100))% likelihood of needing action and a \(Int(decision.urgent * 100))% likelihood of action within 24 hours. These are model assessments, not a verified deadline.")
          .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        Text("Model: \(decision.model)").font(.coveMetadata).foregroundStyle(Palette.body).textSelection(.enabled)
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.assessment, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.assessmentBorder))
  }
  private var assessmentHeading: some View {
    Label(store.isSample ? "Sample assessment" : "Jev’s assessment", systemImage: "sparkles").font(.coveControl)
  }
  private func urgency(_ decision: Decision) -> some View {
    Text(decision.urgent >= 0.65 ? "May be time-sensitive" : decision.urgent >= 0.35 ? "Timing unclear" : "Low urgency")
      .font(.coveSecondary).foregroundStyle(Palette.body)
  }
  private var assessmentActions: some View {
    HStack(spacing: 10) {
      Button {
        Task { await store.toggleFlag(current) }
      } label: { Label(current.isStarred ? "Flagged" : "Flag for follow-up", systemImage: current.isStarred ? "flag.fill" : "flag") }
        .buttonStyle(SecondaryButton()).disabled(store.busy || current.labels.contains("DRAFT"))
        .help("Follow-up flags sync with Gmail’s stars")
      snoozeMenu(title: "Remind me")
    }
  }
  private var evidenceActions: some View {
    HStack(spacing: 12) {
      Button(showEvidence ? "Hide details" : "Why this?") { showEvidence.toggle() }
        .accessibilityValue(showEvidence ? "Expanded" : "Collapsed")
      Button("Hide") { assessmentHidden = true }.help("Hide this assessment while reading; restore it from More")
    }.buttonStyle(.plain).font(.coveSecondary).frame(minHeight: 40)
  }

  private func responseBar(replyAction: @escaping (Bool) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { responseActions(replyAction); Spacer(minLength: 12); noReplyNotice; askButton }
        VStack(alignment: .leading, spacing: 10) {
          MailChipLayout(spacing: 12) { responseActions(replyAction); askButton }
          noReplyNotice
        }
      }
    }.padding(.horizontal, 32).padding(.vertical, 18).background(Palette.canvas)
  }
  private func responseActions(_ replyAction: @escaping (Bool) -> Void) -> some View {
    Group {
      if !localDraft && !showReply
        && MailConversation.replyAllRecipients(for: current, accountEmail: store.accountEmail) != nil
      {
        ReplySplitButton(reply: { replyAction(false) }, replyAll: { replyAction(true) })
      } else {
        Button { replyAction(false) } label: {
          Label(localDraft ? "Continue writing" : showReply ? "Continue reply" : "Reply", systemImage: "arrowshape.turn.up.left")
        }.buttonStyle(PrimaryButton())
      }
      if !localDraft {
        Button { store.prepareHomeDelegation(current) } label: {
          Label("Forward", systemImage: "arrowshape.turn.up.right")
        }.buttonStyle(SecondaryButton()).disabled(store.busy)
          .help("Prepare a forwarding draft; attachments are not included")
      }
    }.fixedSize()
  }
  @ViewBuilder private var noReplyNotice: some View {
    if current.replyAddressLooksUnmonitored {
      Text("Sender uses a no-reply address.").font(.coveSecondary).foregroundStyle(Palette.body)
    }
  }
  @ViewBuilder private var askButton: some View {
    if !current.labels.contains("DRAFT") {
      Button { store.askAboutEmail(current) } label: { Label("Ask Cove", systemImage: "sparkles") }
      .buttonStyle(SecondaryButton()).fixedSize()
    }
  }
  var replyEditor: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("A reply, ready for your review", systemImage: "square.and.pencil").font(
          .coveLabel)
        Spacer()
        Text("Not sent").font(.coveMetadata).foregroundStyle(Palette.muted)
      }.padding(.horizontal, 17).padding(.vertical, 13).background(Palette.sidebar)
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("To  \(replyRecipient)")
            if replyingToAll { Text("Cc  \(replyCc)") }
          }.font(.coveSecondary).foregroundStyle(Palette.muted).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if replyAllRecipients != nil {
            // Switching keeps the text; only the recipients change.
            Button(replyingToAll ? "Reply to sender only" : "Reply all") { replyAll.toggle() }
              .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body).fixedSize()
          }
        }
        // Like the composer: the suggestion is previewed in place of the reply and applied on click;
        // the reply itself is untouched until then.
        ZStack(alignment: .topLeading) {
          ComposeTextEditor(text: Binding(get: { reply }, set: { updateReply($0) }), selection: $replySelection,
            accessibilityName: "Reply body", isEditable: writingActivity.preview == nil,
            focusRequest: replyFocusRequest, inset: NSSize(width: 0, height: 4))
            .opacity(writingActivity.preview == nil && !streamingReply ? 1 : 0)
            .allowsHitTesting(writingActivity.preview == nil && !streamingReply)
            .accessibilityHidden(writingActivity.preview != nil || streamingReply)
          if let preview = writingActivity.preview {
            // A streamed draft is already on screen; don't animate it a second time.
            WritingInkCanvas(text: preview, animated: !writingActivity.streamed,
              onEdit: writingActivity.working ? nil : { writingActivity.preview = $0 },
              onSelection: { writingActivity.previewSelection = $0 }, selectedRange: writingActivity.previewSelection)
              .id(writingActivity.revision).accessibilityLabel("Suggested reply")
          } else if streamingReply, let streaming = writingActivity.streaming {
            ScrollView {
              Text(streaming).font(.coveBody).lineSpacing(6).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityLabel("Reply being written")
          }
        }
        .frame(minHeight: 118)
        if writingActivity.preview != nil {
          HStack(spacing: 12) {
            Button("Apply", systemImage: "checkmark") { writingActivity.applyRequest += 1 }
              .buttonStyle(PrimaryButton(compact: true)).disabled(writingActivity.working)
            Button("Discard") { writingActivity.discardRequest += 1 }
              .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
            Spacer(minLength: 0)
            Text("Suggestion · not applied").font(.coveMetadata).foregroundStyle(Palette.muted)
          }
        } else if let before = replyBeforeSuggestion {
          HStack(spacing: 12) {
            Label("Suggestion applied", systemImage: "checkmark").font(.coveMetadata).foregroundStyle(Palette.body)
            Button("Undo") { updateReply(before); replyBeforeSuggestion = nil }
              .buttonStyle(.plain).font(.coveControl)
            Spacer(minLength: 0)
          }
        }
        if AIProviderSettings.shared.writingProvider() != nil {
          // Stays mounted while collapsed so a running request or pending suggestion isn't lost.
          AIWritingPanel(draft: Binding(get: { reply }, set: { updateReply($0) }), selection: replySelection, context: [replySource],
            availableContext: store.mails, voice: store.preferences.voice, instructions: store.preferences.instructions,
            voiceProfile: store.preferences.voiceProfile, memories: store.preferences.memoryPrompt, store: store,
            envelope: "Reply to: \(replyRecipient)\nSubject: \(replySource.subject)", envelopeIdentity: replySource.id,
            activity: writingActivity, reviewOnCanvas: true, inline: true, onClose: { aiOpen = false },
            isOpen: showAskLine, onOpen: { aiOpen = true; writingActivity.focusRequest += 1 },
            onApply: { value in
              replyBeforeSuggestion = reply
              updateReply(value)
              replySelection = NSRange(location: 0, length: 0)
              showReply = true
              aiOpen = false
            }, onConfigure: { store.screen = "integrations" })
        }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 10) { sendButton; templateMenu; Spacer(minLength: 8); discardButton }
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) { sendButton; Spacer(minLength: 8); discardButton }
            HStack(alignment: .center, spacing: 10) { templateMenu }
          }
        }
      }.padding(.horizontal, 18).padding(.vertical, 16)
    }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(
      RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
  }
}

extension ReaderView {
  private var sendButton: some View {
    Button {
      let source = replySource
      let recipient = replyRecipient
      let cc = replyCc
      let sentText = reply
      let subject = source.subject.lowercased().hasPrefix("re:") ? source.subject : "Re: \(source.subject)"
      Task {
        if await store.send(to: recipient, subject: subject, body: sentText, reply: source, cc: cc),
          replySource.id == source.id, reply == sentText
        {
          reply = ""
          showReply = false
        }
      }
    } label: {
      Label(store.isSample ? "Save sample reply" : "Send reply", systemImage: "paperplane")
    }.buttonStyle(PrimaryButton()).fixedSize().disabled(
      reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replyRecipient.isEmpty || store.busy
        || writingActivity.working || writingActivity.preview != nil)
  }
  private var templateMenu: some View {
    Menu {
      Button("Acknowledge") {
        updateReply(ReplyTemplates.reply(
          to: replySource.sender, voice: store.preferences.voice, signoff: store.preferences.signoff))
      }
      Button("Ask for more detail") {
        updateReply(ReplyTemplates.reply(
          to: replySource.sender, voice: store.preferences.voice, signoff: store.preferences.signoff,
          askForDetail: true))
      }
    } label: {
      Label("Template", systemImage: "text.badge.plus").font(.coveControl)
    }.menuStyle(.borderlessButton).fixedSize()
      .padding(.horizontal, 14).frame(height: 40)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.inputBorder))
      .help("Start with a reply template in your preferred voice")
  }
  private var showAskLine: Bool {
    aiOpen || writingActivity.working || writingActivity.preview != nil || writingActivity.needsAttention
  }
  private var streamingReply: Bool {
    writingActivity.working && !(writingActivity.streaming ?? "").isEmpty
  }
  private var discardButton: some View {
    Button {
      reply = ""
      showReply = false
      store.saveReply(id: replySource.id, text: "")
    } label: {
      Image(systemName: "trash").font(.system(size: 15)).frame(width: 40, height: 40).contentShape(Rectangle())
    }.buttonStyle(ReaderActionStyle()).help("Discard reply").accessibilityLabel("Discard reply")
  }
}

extension AppStore {
  func askAboutEmail(_ mail: Mail, question: String = "") {
    selectedID = mail.id
    screen = "mail"
    assistantInitialQuery = question
    showAssistant = true
  }
}

/// Reply is the primary action; Reply all is one click away in the attached menu.
struct ReplySplitButton: View {
  let reply: () -> Void
  let replyAll: () -> Void
  @Environment(\.isEnabled) private var enabled
  var body: some View {
    HStack(spacing: 0) {
      Button(action: reply) {
        Label("Reply", systemImage: "arrowshape.turn.up.left").font(.coveControl)
          .padding(.leading, 16).padding(.trailing, 12).frame(height: 40).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Reply")
      Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 22)
      Menu {
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
        Button("Reply all", systemImage: "arrowshape.turn.up.left.2", action: replyAll)
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
          .frame(width: 34, height: 40).contentShape(Rectangle())
      }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Reply options").accessibilityLabel("Reply options")
    }.foregroundStyle(.white)
      .background(enabled ? Palette.ink : Palette.disabled, in: RoundedRectangle(cornerRadius: 6))
      .fixedSize()
  }
}

struct ReaderActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? Palette.body : Palette.disabledText)
      .background(configuration.isPressed ? Palette.selection : hovering ? Palette.sidebar : .clear,
                  in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Palette.ink : .clear))
      .onHover { hovering = $0 }
  }
}
