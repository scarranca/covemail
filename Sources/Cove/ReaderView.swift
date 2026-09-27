import CoveCore
import SwiftUI

/// The live Pen reader separates message identity, Jev evidence, original content, and response actions.
struct ReaderView: View {
  @Bindable var store: AppStore
  let mail: Mail
  @State private var reply = ""
  @State private var showReply = false
  @State private var showAIWriting = false
  @State private var assessmentHidden = false
  @State private var showEvidence = false
  @FocusState private var replyFocused: Bool
  var current: Mail { store.mails.first { $0.id == mail.id } ?? mail }
  private var position: Int? { store.visible.firstIndex { $0.id == mail.id } }
  private var localDraft: Bool { current.labels.contains("DRAFT") && current.id.hasPrefix("local-") }

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
            VStack(alignment: .leading, spacing: 20) {
              Divider()
              EmailBodyView(store: store, mail: current).id(current.id)
              if !current.labels.contains("DRAFT") { Menu {
                ForEach(["English", "Spanish", "French", "German", "Portuguese", "Japanese"], id: \.self) { language in
                  Button(language) {
                    store.askAboutEmail(current, question: "Translate the selected email into \(language). Preserve its meaning and distinguish the translation from the original email.")
                  }
                }
              } label: {
                Label("Translate", systemImage: "character.bubble")
              }.menuStyle(.borderlessButton).fixedSize().font(.coveControl)
                .help("Prepare a translation request in Ask Cove using your connected writing model")
              }
            }
            if !current.availableAttachments.isEmpty { attachmentList }
            if !localDraft && (showReply || !current.draft.isEmpty) {
              replyEditor.id("reply")
              Label("You have the final say. Nothing sends without you.", systemImage: "checkmark.shield")
                .font(.coveMetadata).foregroundStyle(Palette.muted)
            }
          }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        Divider()
        responseBar {
          if localDraft {
            store.composeID = current.id; store.showComposer = true
          } else {
            showReply = true
            // Wait for the editor to participate in layout before revealing it.
            Task { @MainActor in
              await Task.yield()
              proxy.scrollTo("reply", anchor: .bottom)
              replyFocused = true
            }
          }
        }
      }
    }.background(Palette.canvas).foregroundStyle(Palette.ink)
    .onAppear {
      reply = current.draft; showReply = !reply.isEmpty
      let opened = current
      Task { await store.markViewed(opened) }
    }
    .task { if !store.isSample { await AIProviderSettings.shared.restoreWritingConnection() } }
    .sheet(isPresented: $showAIWriting) {
      AIWritingSheet(context: [current], initialText: reply, onInsert: { value in
        reply = value; showReply = true
        store.saveReply(id: current.id, text: value)
      }, onConfigure: { store.screen = "integrations" }, store: store)
    }
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
        store.snooze(current, until: Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9), matchingPolicy: .nextTime))
      }
      if current.snoozedUntil != nil { Button("Return to inbox") { store.snooze(current, until: nil) } }
    } label: { actionLabel(title, icon: "clock", compact: compact) }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .padding(.horizontal, title == "Remind me" ? 12 : 0).frame(height: 40)
      .background(title == "Remind me" ? Palette.canvas : .clear, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(title == "Remind me" ? Palette.inputBorder : .clear))
      .disabled(store.busy).help("\(title) on this Mac").accessibilityLabel("\(title) on this Mac")
  }

  private func moreMenu(compact: Bool) -> some View {
    Menu {
      Button(current.isStarred ? "Remove follow-up flag" : "Flag for follow-up", systemImage: current.isStarred ? "flag.fill" : "flag") {
        Task { await store.toggleFlag(current) }
      }.disabled(current.labels.contains("DRAFT"))
      Button("Assess with Jev", systemImage: "sparkles") {
        assessmentHidden = false
        Task { await store.classify(current) }
      }
      if assessmentHidden { Button("Show Jev assessment") { assessmentHidden = false } }
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
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { sender; Spacer(minLength: 12); date; moreMenu(compact: true) }
        VStack(alignment: .leading, spacing: 8) {
          sender
          HStack { date; Spacer(); moreMenu(compact: true) }.padding(.leading, 52)
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

  private func responseBar(replyAction: @escaping () -> Void) -> some View {
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
  private func responseActions(_ replyAction: @escaping () -> Void) -> some View {
    Group {
      Button(action: replyAction) {
        Label(localDraft ? "Continue writing" : showReply ? "Continue reply" : "Reply", systemImage: "arrowshape.turn.up.left")
      }.buttonStyle(PrimaryButton())
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
  private var attachmentList: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(current.availableAttachments.count == 1 ? "Attachment" : "Attachments")
        .font(.coveControl)
      ForEach(current.availableAttachments) { attachment in
        HStack(spacing: 12) {
          Image(systemName: "paperclip").foregroundStyle(Palette.muted)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(attachment.filename).font(.coveLabel)
              .lineLimit(2).textSelection(.enabled)
            if let byteCount = attachment.byteCount {
              Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
                .font(.coveMetadata).foregroundStyle(Palette.muted)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          Button {
            let source = current
            Task { await store.downloadAttachment(attachment, from: source) }
          } label: {
            Label("Save", systemImage: "arrow.down.to.line")
          }.buttonStyle(SecondaryButton()).disabled(store.busy)
            .accessibilityLabel("Save \(attachment.filename)")
        }.padding(12).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
      }
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
        Text("To  \(current.replyRecipient)").font(.coveSecondary).foregroundStyle(Palette.muted)
        TextEditor(text: $reply).focused($replyFocused).font(.coveBody).lineSpacing(6).scrollContentBackground(
          .hidden
        ).accessibilityLabel("Reply body").frame(
          minHeight: 118
        ).onChange(of: reply) { _, value in store.saveReply(id: current.id, text: value) }
        MailChipLayout(spacing: 12) {
          Button {
            let source = current
            let sentText = reply
            let subject =
              source.subject.lowercased().hasPrefix("re:")
              ? source.subject : "Re: \(source.subject)"
            Task {
              if await store.send(
                to: source.replyRecipient, subject: subject, body: sentText, reply: source),
                current.id == source.id, reply == sentText
              {
                reply = ""
                showReply = false
              }
            }
          } label: {
            Label(store.isSample ? "Save sample reply" : "Send reply", systemImage: "paperplane")
          }.buttonStyle(PrimaryButton()).disabled(
            reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
          Menu {
            Button("Acknowledge") {
              reply = ReplyTemplates.reply(
                to: current.sender, voice: store.preferences.voice,
                signoff: store.preferences.signoff)
            }
            Button("Ask for more detail") {
              reply = ReplyTemplates.reply(
                to: current.sender, voice: store.preferences.voice,
                signoff: store.preferences.signoff, askForDetail: true)
            }
          } label: {
            Label("Template", systemImage: "square.and.pencil")
          }.menuStyle(.borderlessButton).frame(width: 95)
            .help("Start with a reply template in your preferred voice")
          if AIProviderSettings.shared.writingProvider() != nil {
            Button("Write with AI", systemImage: "sparkles") { showAIWriting = true }
              .buttonStyle(SecondaryButton()).disabled(store.busy)
          }
          Button {
            reply = ""
            showReply = false
            store.saveReply(id: current.id, text: "")
          } label: {
            Image(systemName: "trash")
          }.buttonStyle(.plain).help("Discard reply").accessibilityLabel("Discard reply")
        }
      }.padding(.horizontal, 18).padding(.vertical, 16)
    }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(
      RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
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

private struct ReaderActionStyle: ButtonStyle {
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
