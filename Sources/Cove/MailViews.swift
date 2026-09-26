import CoveCore
import SwiftUI

struct MailboxView: View {
  @Bindable var store: AppStore
  @FocusState private var searching: Bool
  @FocusState private var listFocused: Bool
  var body: some View {
    GeometryReader { geometry in
      let mailList = store.visible
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 19) {
            if store.selectedLabelID != nil {
              Button { store.screen = "categories" } label: {
                Label("Categories", systemImage: "chevron.left").font(.coveControl)
              }.buttonStyle(.plain).foregroundStyle(Palette.body).help("Back to all categories")
            }
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                if let parent = store.selectedGmailLabel?.parent {
                  Text(parent).font(.coveMetadata).foregroundStyle(Palette.body)
                } else if store.selectedJevFlag != nil {
                  Label("Jev flags", systemImage: "sparkles").font(.coveMetadata).foregroundStyle(Palette.body)
                }
                Text(store.folderTitle).font(.coveTitle).lineLimit(2)
              }
              Spacer()
              Button {
                Task { if store.mailScopeLabelID != nil { await store.loadLabelMail() } else { await store.sync() } }
              } label: {
                Image(systemName: "arrow.clockwise")
              }.buttonStyle(.plain).help("Sync Gmail (⌘R)").disabled(store.busy)
            }
            if store.isFocusedMailView {
              Text("\(store.focusedMails.count) downloaded · \(store.focusedMails.filter(\.isUnread).count) unread")
                .font(.coveSecondary).foregroundStyle(Palette.body)
            }
            HStack {
              Image(systemName: "magnifyingglass")
              TextField(
                store.isFocusedMailView ? "Search within this view" : "Search your mail", text: $store.search,
                prompt: Text(store.isFocusedMailView ? "Search within this view" : "Search your mail").foregroundStyle(Palette.muted)
              ).textFieldStyle(.plain).focused(
                $searching)
              Text("⌘ K").font(.coveMetadata)
            }.font(.coveSecondary).foregroundStyle(Palette.muted)
              .padding(.horizontal, 12).padding(.vertical, 10).background(
                .white, in: RoundedRectangle(cornerRadius: 7)
              ).overlay(
                RoundedRectangle(cornerRadius: 7).stroke(searching ? Palette.ink : Palette.line))
            if store.isFocusedMailView {
              HStack(spacing: 18) {
                Button("All \(store.focusedMails.count)") { store.labelUnreadOnly = false; store.reconcileSelection() }
                  .fontWeight(store.labelUnreadOnly ? .regular : .medium)
                Button("Unread \(store.focusedMails.filter(\.isUnread).count)") { store.labelUnreadOnly = true; store.reconcileSelection() }
                  .fontWeight(store.labelUnreadOnly ? .medium : .regular)
                Spacer()
                Menu {
                  Button("Newest first", systemImage: store.labelOldestFirst ? "arrow.down" : "checkmark") { store.labelOldestFirst = false }
                  Button("Oldest first", systemImage: store.labelOldestFirst ? "checkmark" : "arrow.up") { store.labelOldestFirst = true }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                  .menuStyle(.borderlessButton).frame(width: 24).help("Sort emails")
                  .accessibilityLabel("Sort emails")
              }.buttonStyle(.plain).font(.coveSecondary).foregroundStyle(Palette.body)
            } else {
            HStack(spacing: 20) {
              Button {
                store.priorityOnly = true
                store.reconcileSelection()
              } label: {
                Text("Priority \(store.attentionCount)").fontWeight(
                  store.priorityOnly ? .medium : .regular
                )
                .foregroundStyle(store.priorityOnly ? Palette.body : Palette.muted)
              }
              Button {
                store.priorityOnly = false
                store.reconcileSelection()
              } label: {
                Text("All mail").fontWeight(!store.priorityOnly ? .medium : .regular)
                  .foregroundStyle(!store.priorityOnly ? Palette.body : Palette.muted)
              }
              Spacer()
            }.buttonStyle(.plain).font(.coveText).foregroundStyle(Palette.muted)
            }
          }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 18)
          Divider()
          if !store.isFocusedMailView {
          HStack(spacing: 10) {
            Text("\(store.attentionCount) need attention").font(.coveControl)
            Text("·").foregroundStyle(Palette.muted)
            Text("\(draftCount) \(draftCount == 1 ? "draft" : "drafts") ready").font(.coveSecondary).foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
          }.foregroundStyle(Palette.body).lineLimit(1)
            .padding(.horizontal, 22).frame(height: 40)
          Divider()
          }
          if let error = store.labelMailError, store.isFocusedMailView {
            Text(error).font(.coveMetadata).foregroundStyle(Palette.danger)
              .fixedSize(horizontal: false, vertical: true).padding(12)
          }
          if store.visible.isEmpty {
            ContentUnavailableView(
              store.search.isEmpty ? (store.isFocusedMailView ? "No emails in this view" : "A little breathing room") : "No matching mail",
              systemImage: store.search.isEmpty ? "tray" : "magnifyingglass",
              description: Text(
                store.search.isEmpty
                  ? "Messages in this view will appear here."
                  : "Try a name, subject, or phrase in your downloaded mail.")
            ).frame(maxHeight: .infinity)
          } else {
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 0) {
                  ForEach(Array(mailList.enumerated()), id: \.element.id) { index, mail in
                    if !store.isFocusedMailView && (index == 0
                      || daySection(mail.date) != daySection(mailList[index - 1].date))
                    {
                      Text(daySection(mail.date)).font(.coveControl)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 9)
                    }
                    MailListRow(store: store, mail: mail) { listFocused = true }.id(mail.id)
                    Divider()
                  }
                }
              }
              .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
              }
            }
          }
          if (store.mailScopeLabelID.map { store.labelNextPages[$0] != nil } ?? (store.nextPage != nil)) && !store.isSample {
            Button("Load older mail") { Task {
              if store.mailScopeLabelID != nil { await store.loadLabelMail(older: true) }
              else { await store.sync(older: true) }
            } }.buttonStyle(SecondaryButton()).padding().disabled(store.busy)
          }
          if store.isFocusedMailView {
            Text(store.selectedJevFlag != nil ? "Jev assessments · downloaded mail" : store.folder == "Flagged" ? "Follow-up flags sync with Gmail’s stars." : "Includes inbox and archived emails.")
              .font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 12).padding(.vertical, 10)
          }
          Divider()
          HStack(spacing: 6) {
            if store.busy { ProgressView().controlSize(.mini) }
            Text(
              store.status.isEmpty
                ? (store.isSample ? "Sample mailbox" : "Gmail · saved locally") : store.status
            ).lineLimit(2)
            Spacer()
            Text("↑ ↓ emails · Esc back").fixedSize().help("Up and Down select emails. Escape or Left returns to the list. Shortcuts pause while you type.")
          }.font(.coveMetadata).foregroundStyle(Palette.muted).padding(12)
        }.frame(width: min(392, max(300, geometry.size.width * 0.328))).background(Palette.surface)
          .focusable().focusEffectDisabled().focused($listFocused)
        Divider()
        if let mail = store.selected {
          ReaderView(store: store, mail: mail).id(mail.id)
        } else {
          UnselectedMailView(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background(MailNavigationShortcut(store: store) { listFocused = true }.frame(width: 0, height: 0))
    .background(Button("") { searching = true }.keyboardShortcut("k").hidden())
    .task(id: store.folder) {
      guard store.mailScopeLabelID != nil else { return }
      do {
        while store.busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        await store.loadLabelMail()
      } catch {}
    }
    .onAppear { listFocused = true }
    .onChange(of: store.search) { _, _ in store.reconcileSelection() }
    .onChange(of: store.folder) { _, _ in listFocused = true }

  }

  private var draftCount: Int {
    store.mails.filter { (!$0.draft.isEmpty || $0.labels.contains("DRAFT")) && !$0.labels.contains("TRASH") }.count
  }

  private func daySection(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }
}
struct MailRow: View {
  let mail: Mail
  let selected: Bool
  var hovered = false
  var actionsVisible = false
  var labelView = false
  var categoryLabels: [GmailLabel] = []
  var isSample = false
  private var titleWeight: Font.Weight { mail.isUnread ? .bold : selected ? .medium : .regular }
  private var titleColor: Color { mail.isUnread || selected ? Palette.ink : Palette.mailReadText }
  private var rowColor: Color {
    if selected { return Palette.mailSelection }
    if hovered { return Palette.mailHover }
    return mail.isUnread ? Palette.canvas : Palette.mailRead
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      senderLine
      Text(mail.subject.isEmpty ? "New message" : mail.subject).fontWeight(titleWeight).lineLimit(1)
      Text(mail.body.replacingOccurrences(of: "\n", with: " ")).font(.coveSecondary)
        .foregroundStyle(Palette.body).lineLimit(1)
      badges
      JevMailFlagBadges(mail: mail, isSample: isSample)
    }.font(.coveText).foregroundStyle(titleColor)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 22).padding(.vertical, 12).frame(minHeight: 106, alignment: .top)
      .background(rowColor).contentShape(Rectangle())
      .accessibilityElement(children: .combine).accessibilityValue(mail.isUnread ? "Unread" : "Read")
  }
  private var senderLine: some View {
    HStack(spacing: 6) {
      if mail.isUnread { Circle().fill(Palette.ink).frame(width: 8, height: 8).accessibilityHidden(true) }
      if mail.isStarred { Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(Palette.ink).help("Flagged for follow-up · starred in Gmail") }
      Text(mail.sender).fontWeight(titleWeight).lineLimit(1)
      Spacer(minLength: 5)
      Text(mail.date, style: .time).font(mail.isUnread ? .coveCaption : .coveMetadata)
        .foregroundStyle(mail.isUnread || selected ? Palette.body : Palette.muted)
        .frame(width: 114, alignment: .trailing).opacity(actionsVisible ? 0 : 1)
    }
  }
  private var badges: some View {
    HStack(spacing: 8) {
      if labelView {
        Label(mail.labels.contains("INBOX") ? "Inbox" : mail.labels.contains("SENT") ? "Sent" : mail.labels.contains("DRAFT") ? "Draft" : "Archived", systemImage: mail.labels.contains("INBOX") ? "tray" : "archivebox").badgeStyle()
      }
      if !mail.draft.isEmpty {
        Label("Draft ready", systemImage: "square.and.pencil")
          .font(.coveCaption).foregroundStyle(Palette.body)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(selected ? Palette.selection : Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
      } else if !labelView, let label = categoryLabels.first {
        Text(label.name).lineLimit(1).badgeStyle()
        if categoryLabels.count > 1 { Text("+\(categoryLabels.count - 1)").font(.coveMetadata) }
      }
      if mail.isUnread {
        Spacer(minLength: 0)
        Text("Unread").font(.coveCaption).foregroundStyle(Palette.ink)
      }
    }
  }
}
/// The open target and quick actions are sibling buttons, so hovering an action never opens the mail.
struct MailListRow: View {
  @Bindable var store: AppStore
  let mail: Mail
  var onSelect: () -> Void = {}
  @State private var hovered = false
  @FocusState private var actionFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var selected: Bool { store.selectedID == mail.id }
  private var actionsVisible: Bool { hovered || selected || actionFocused }
  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button { store.select(mail); onSelect() } label: {
        MailRow(mail: mail, selected: selected, hovered: hovered, actionsVisible: actionsVisible, labelView: store.selectedLabelID != nil, categoryLabels: store.agentLabels(on: mail), isSample: store.isSample)
      }.buttonStyle(.plain).accessibilityLabel("Open \(mail.subject.isEmpty ? "message" : mail.subject) from \(mail.sender)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      HStack(spacing: 2) {
        MailRowAction(title: mail.isStarred ? "Remove follow-up flag" : "Flag for follow-up", icon: mail.isStarred ? "flag.fill" : "flag") {
          Task { await store.toggleFlag(mail) }
        }.disabled(store.busy || mail.labels.contains("DRAFT"))
        MailRowAction(title: "Archive email", icon: "archivebox") { Task { await store.archive(mail) } }
          .disabled(store.busy || !mail.labels.contains("INBOX") || mail.labels.contains("DRAFT"))
        MailRowAction(title: mail.isUnread ? "Mark as read" : "Mark as unread", icon: mail.isUnread ? "envelope.open" : "envelope.badge") {
          Task { await store.modify(mail, add: mail.isUnread ? [] : ["UNREAD"], remove: mail.isUnread ? ["UNREAD"] : []) }
        }.disabled(store.busy || mail.labels.contains("DRAFT"))
        MailRowAction(title: "Delete email · 5 seconds to undo", icon: "trash") { store.queueTrash(mail) }.disabled(store.busy)
      }.focused($actionFocused).padding(.trailing, 17).padding(.top, 6)
        .opacity(actionsVisible ? 1 : 0).allowsHitTesting(actionsVisible).accessibilityHidden(!actionsVisible)
    }.onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: actionsVisible)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
      .contextMenu {
        Button(mail.isStarred ? "Remove follow-up flag" : "Flag for follow-up", systemImage: mail.isStarred ? "flag.fill" : "flag") {
          Task { await store.toggleFlag(mail) }
        }.disabled(store.busy || mail.labels.contains("DRAFT"))
        Button("Archive", systemImage: "archivebox") { Task { await store.archive(mail) } }
          .disabled(store.busy || !mail.labels.contains("INBOX") || mail.labels.contains("DRAFT"))
        Button(mail.isUnread ? "Mark as read" : "Mark as unread", systemImage: "envelope") {
          Task { await store.modify(mail, add: mail.isUnread ? [] : ["UNREAD"], remove: mail.isUnread ? ["UNREAD"] : []) }
        }.disabled(store.busy || mail.labels.contains("DRAFT"))
        Button("Delete", systemImage: "trash", role: .destructive) { store.queueTrash(mail) }.disabled(store.busy)
      }
  }
}
private struct MailRowAction: View {
  let title: String
  let icon: String
  let action: () -> Void
  @State private var hovered = false
  var body: some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 12)).frame(width: 26, height: 26)
        .foregroundStyle(hovered && icon == "trash" ? Palette.danger : Palette.body)
        .background(hovered ? Palette.canvas : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).help(title).accessibilityLabel(title).onHover { hovered = $0 }
  }
}
extension View {
  func badgeStyle() -> some View {
    self.font(.coveCaption).foregroundStyle(Palette.body).padding(
      .horizontal, 7
    ).padding(.vertical, 3).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
  }
}
struct ReaderView: View {
  @Bindable var store: AppStore
  let mail: Mail
  @State private var reply = ""
  @State private var showReply = false
  @State private var showAIWriting = false
  var current: Mail { store.mails.first { $0.id == mail.id } ?? mail }
  private var position: Int? { store.visible.firstIndex { $0.id == mail.id } }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 24) {
        tool("Archive", icon: "archivebox") {
          Task { await store.archive(current) }
        }
        tool("Delete email (⌘⌫)", icon: "trash") { store.queueTrash(current) }
        tool(
          current.isUnread ? "Mark as read" : "Mark as unread",
          icon: current.isUnread ? "envelope.open" : "envelope.badge"
        ) {
          Task {
            await store.modify(
              current, add: current.isUnread ? [] : ["UNREAD"],
              remove: current.isUnread ? ["UNREAD"] : [])
          }
        }
        Menu {
          Button("In one hour") { store.snooze(current, until: Date().addingTimeInterval(3600)) }
          Button("Tomorrow morning") {
            store.snooze(
              current,
              until: Calendar.current.nextDate(
                after: Date(), matching: DateComponents(hour: 9), matchingPolicy: .nextTime))
          }
          if current.snoozedUntil != nil {
            Button("Return to inbox") { store.snooze(current, until: nil) }
          }
        } label: {
          Image(systemName: "clock").font(.cove(size: 17))
        }.menuStyle(.borderlessButton).frame(width: 24).help("Snooze on this Mac").disabled(store.busy)
        tool(current.isStarred ? "Remove follow-up flag" : "Flag for follow-up · syncs with Gmail’s star", icon: current.isStarred ? "flag.fill" : "flag") {
          Task { await store.toggleFlag(current) }
        }.disabled(current.labels.contains("DRAFT"))
        Spacer()
        if let position {
          Text("\(position + 1) of \(store.visible.count)").font(.coveSecondary).fixedSize()
        }
        tool("Previous email (↑)", icon: "chevron.up", navigation: true) { navigate(-1) }
          .disabled(position == nil || position == 0)
        tool("Next email (↓)", icon: "chevron.down", navigation: true) { navigate(1) }
          .disabled(position == nil || position == store.visible.count - 1)
      }.foregroundStyle(Palette.muted).padding(.horizontal, 30).frame(height: 66)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          MailLabelChips(store: store, mail: current)
          if current.decision == nil {
            Button { Task { await store.classify(current) } } label: {
              Label("Assess with Jev", systemImage: "sparkles")
            }.buttonStyle(.plain).font(.coveControl).disabled(store.busy)
          }
          Text(current.subject.isEmpty ? "New message" : current.subject).font(
            .coveTitle
          ).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 12) {
            Text(current.initials).font(.coveLabel)
              .foregroundStyle(Palette.body).frame(width: 40, height: 40)
              .background(Palette.selection, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
              Text(current.sender).font(.coveSubheading)
              Text("to \(current.to.isEmpty ? "me" : current.to) · \(current.senderEmail)").font(
                .coveSecondary
              ).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(2)
            }
            Spacer()
            Text(current.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
              .coveMetadata
            ).foregroundStyle(Palette.muted)
            Menu {
              Button(
                current.isStarred ? "Remove follow-up flag" : "Flag for follow-up",
                systemImage: current.isStarred ? "flag.fill" : "flag"
              ) {
                Task {
                  await store.modify(
                    current, add: current.isStarred ? [] : ["STARRED"],
                    remove: current.isStarred ? ["STARRED"] : [])
                }
              }
              Button("Ask Cove", systemImage: "sparkles") { store.showAssistant = true }
              Button("Organize with Jev", systemImage: "tray") {
                Task { await store.classify(current) }
              }
            } label: {
              Image(systemName: "ellipsis").font(.cove(size: 18))
            }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.busy)
              .help("More message options").accessibilityLabel("More message options")
          }
          if let attribution = store.labelAttribution(for: current) {
            Label(attribution, systemImage: "sparkles").font(.coveSecondary).foregroundStyle(Palette.body)
          }
          JevMailFlagBadges(mail: current, isSample: store.isSample)
          if let decision = current.decision {
            JevAssessmentView(decision: decision, isSample: store.isSample)
          }
          if let excerpt = current.decision?.excerpt {
            VStack(alignment: .leading, spacing: 8) {
              Label("The key passage", systemImage: "sparkles").font(
                .coveControl)
              Text(excerpt).font(.coveText).lineSpacing(5).foregroundStyle(Palette.body)
                .textSelection(.enabled)
              Text("Selected from the original email").font(.coveMetadata).foregroundStyle(
                Palette.body)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
              Palette.summary, in: RoundedRectangle(cornerRadius: 8))
          }
          EmailBodyView(store: store, mail: current).id(current.id).padding(.vertical, 2)
          if !current.availableAttachments.isEmpty {
            attachmentList
          }
          if current.labels.contains("DRAFT") && current.id.hasPrefix("local-") {
            Button("Continue writing") {
              store.composeID = current.id
              store.showComposer = true
            }.buttonStyle(PrimaryButton())
          } else if showReply || !current.draft.isEmpty {
            replyEditor
          } else {
            HStack {
              Button {
                showReply = true
              } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
              }.buttonStyle(PrimaryButton())
              Button {
                store.showAssistant = true
              } label: {
                Label("Ask about this email", systemImage: "sparkles")
              }.buttonStyle(SecondaryButton()).controlSize(.large)
            }
          }
          Label(
            "You have the final say. Nothing sends without you.", systemImage: "checkmark.shield"
          ).font(.coveMetadata).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 20)
          .frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
      }
    }
    .onAppear {
      reply = current.draft
      showReply = !reply.isEmpty
      // An unstructured task finishes even if the user moves to the next email quickly.
      let opened = current
      Task { await store.markViewed(opened) }
    }
    .task { if !store.isSample { await AIProviderSettings.shared.restoreWritingConnection() } }
    .sheet(isPresented: $showAIWriting) {
      AIWritingSheet(context: [current], initialText: reply, onInsert: { value in
        reply = value
        showReply = true
        store.saveReply(id: current.id, text: value)
      }, onConfigure: { store.screen = "integrations" }, store: store)
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
        TextEditor(text: $reply).font(.coveBody).lineSpacing(6).scrollContentBackground(
          .hidden
        ).accessibilityLabel("Reply body").frame(
          minHeight: 118
        ).onChange(of: reply) { _, value in store.saveReply(id: current.id, text: value) }
        HStack {
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
          Spacer()
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
  private func navigate(_ offset: Int) {
    guard let position else { return }
    let next = position + offset
    guard store.visible.indices.contains(next) else { return }
    store.select(store.visible[next])
  }
  func tool(_ title: String, icon: String, navigation: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: icon).font(.cove(size: 17)) }.buttonStyle(.plain)
      .help(title).accessibilityLabel(title).disabled(!navigation && store.busy)
  }
}
