import CoveCore
import SwiftUI

struct MailboxView: View {
  @Bindable var store: AppStore
  @FocusState private var searching: Bool
  @FocusState private var listFocused: Bool
  @State private var pageLoader = MailPageLoader()
  @State private var atListEnd = false
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
              }.buttonStyle(.plain).help("Sync Gmail (⌘R)").disabled(store.syncing)
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
            } else if store.folder == "Inbox" || store.priorityOnly {
              InboxFilterBar(store: store)
            }
          }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 18)
          Divider()
          if let error = store.labelMailError, store.isFocusedMailView {
            Text(error).font(.coveMetadata).foregroundStyle(Palette.danger)
              .fixedSize(horizontal: false, vertical: true).padding(12)
          }
          if store.visible.isEmpty, store.effectiveInboxTab == .important {
            InboxDuskView(title: "All caught up",
                          detail: store.labelUnreadOnly ? "Nothing unread in Important." : "Nothing in Important right now.")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if store.visible.isEmpty {
            VStack(spacing: 12) {
              ContentUnavailableView(
                store.search.isEmpty ? (store.isFocusedMailView ? "No emails in this view" : "A little breathing room") : "No matching mail",
                systemImage: store.search.isEmpty ? "tray" : "magnifyingglass",
                description: Text(
                  store.search.isEmpty
                    ? "Messages in this view will appear here."
                    : "Nothing matches in mail on this Mac.")
              )
              GmailSearchMoreButton(store: store)
            }.frame(maxHeight: .infinity)
          } else {
            ScrollViewReader { proxy in
              GeometryReader { viewport in
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
                    GmailSearchMoreButton(store: store)
                    paginationFooter
                      .background(GeometryReader { end in
                        Color.clear.preference(key: MailListEndKey.self,
                          value: end.frame(in: .named("mail-list-viewport")).minY)
                      })
                  }
                }
                .coordinateSpace(name: "mail-list-viewport")
                .onPreferenceChange(MailListEndKey.self) { y in
                  let visible = y.map { $0 >= 0 && $0 <= viewport.size.height } ?? false
                  if !visible { pageLoader.leftEnd() }
                  atListEnd = visible
                }
                .onChange(of: store.selectedID) { _, id in
                  if let id { proxy.scrollTo(id) }
                }
              }
            }
          }
          if store.isFocusedMailView {
            Text(store.selectedJevFlag != nil ? "Jev assessments · downloaded mail" : store.folder == "Flagged" ? "Follow-up flags sync with Gmail’s stars." : "Includes inbox and archived emails.")
              .font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 12).padding(.vertical, 10)
          }
          Divider()
          HStack(spacing: 6) {
            if store.busy || store.syncing { ProgressView().controlSize(.mini) }
            Text(
              store.status.isEmpty
                ? (store.isSample ? "Sample mailbox" : "Gmail · saved locally") : store.status
            ).lineLimit(2)
            Spacer()
            Text("↑ ↓ emails · Esc back").fixedSize().help("Up and Down select emails. Escape or Left returns to the list. Shortcuts pause while you type.")
          }.font(.coveMetadata).foregroundStyle(Palette.muted).padding(12)
        }.frame(width: min(392, max(300, geometry.size.width * 0.328))).background(Palette.surface)
          .overlay(alignment: .bottom) { InboxMoveToast(store: store).padding(.bottom, 58) }
          .focusable().focusEffectDisabled().focused($listFocused)
        Divider()
        if let mail = store.selected {
          ReaderView(store: store, mail: mail).id(store.accountEmail + ":" + mail.id)
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
        while store.syncing { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        await store.loadLabelMail()
      } catch {}
    }
    .onAppear { listFocused = true }
    .onChange(of: store.search) { _, _ in store.reconcileSelection(); resetPaginationEnd() }
    .onChange(of: store.folder) { _, _ in listFocused = true; resetPaginationEnd() }
    .onChange(of: store.accountEmail) { _, _ in resetPaginationEnd() }
    .onChange(of: [store.priorityOnly, store.labelUnreadOnly, store.labelOldestFirst]) { _, _ in resetPaginationEnd() }
    .onChange(of: store.effectiveInboxTab) { _, _ in resetPaginationEnd() }
    .onChange(of: paginationTrigger) { _, _ in
      Task { await loadNextPage() }
    }

  }

  private func resetPaginationEnd() {
    atListEnd = false
    pageLoader.leftEnd()
  }

  private struct PaginationTrigger: Equatable {
    let request: MailPageRequest?
    let atEnd: Bool
    let allowed: Bool
    let loading: Bool
  }
  private var paginationTrigger: PaginationTrigger {
    .init(request: store.nextMailPageRequest, atEnd: atListEnd,
      allowed: store.canLoadNextMailPage && !store.visible.isEmpty, loading: pageLoader.loading)
  }
  private func loadNextPage(retry: Bool = false) async {
    let request = store.nextMailPageRequest
    await pageLoader.load(request, atEnd: atListEnd,
      allowed: store.canLoadNextMailPage && !store.visible.isEmpty, retry: retry) {
        guard let request else { return nil }
        return await store.loadNextMailPage(request)
      }
  }
  private var paginationFooter: some View {
    VStack(spacing: 8) {
      if pageLoader.loading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading more mail…").font(.coveSecondary).foregroundStyle(Palette.muted)
        }.padding(12)
      } else if let failed = pageLoader.failed, failed == store.nextMailPageRequest {
        Text("Couldn’t load more mail.").font(.coveSecondary).foregroundStyle(Palette.body)
        Button("Try again") { Task { await loadNextPage(retry: true) } }
          .buttonStyle(SecondaryButton(compact: true)).disabled(!store.canLoadNextMailPage)
      }
    }.frame(maxWidth: .infinity, minHeight: 1)
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
    }.background(MailRowPointerTarget(mailID: mail.id))
      .onHover { hovered = $0 }
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
        InboxSplitMenuItems(store: store, mail: mail)
        Divider()
        if mail.labels.contains("SPAM") {
          Button("Not spam", systemImage: "tray.and.arrow.down") { Task { await store.markNotSpam(mail) } }.disabled(store.busy)
        } else {
          Button("Report spam", systemImage: "xmark.octagon") { Task { await store.reportSpam(mail) } }
            .disabled(store.busy || mail.labels.contains("DRAFT") || mail.labels.contains("SENT"))
        }
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


/// Searches all of Gmail for the current search words and brings up to 20 matches onto this Mac.
struct GmailSearchMoreButton: View {
  @Bindable var store: AppStore
  @State private var searching = false
  @State private var result: String?
  @State private var lastQuery = ""
  var body: some View {
    let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.count >= 2 && !store.isSample {
      VStack(spacing: 6) {
        Button {
          searching = true; result = nil; lastQuery = query
          Task {
            do {
              let found = try await store.aiSearchMail(query)
              guard store.search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { searching = false; return }
              // Show matches that live outside the current folder, keeping the search.
              let shown = Set(store.visible.map(\.id))
              if found.contains(where: { !shown.contains($0.id) }) { store.folder = "All mail" }
              result = found.isEmpty ? "Gmail has no other emails matching “\(query)”." : "Found \(found.count) email\(found.count == 1 ? "" : "s") in Gmail."
            } catch is CancellationError {} catch { result = error.localizedDescription }
            searching = false
          }
        } label: {
          HStack(spacing: 8) {
            if searching { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
            Text(searching ? "Searching Gmail…" : "Search all of Gmail for “\(query)”").lineLimit(1)
          }.font(.coveControl).padding(.horizontal, 14).frame(height: 36)
        }.buttonStyle(.plain).foregroundStyle(Palette.body).disabled(searching || store.busy)
        if let result, lastQuery == query {
          Text(result).font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
  }
}

/// Important / Other tabs with unread counts, and the Unread filter, which composes with either tab.
struct InboxFilterBar: View {
  @Bindable var store: AppStore
  var body: some View {
    // Narrow list columns keep the tabs and fall back to an icon-only Unread toggle.
    ViewThatFits(in: .horizontal) {
      bar(compactUnread: false)
      bar(compactUnread: true)
    }
  }
  private func bar(compactUnread: Bool) -> some View {
    HStack(spacing: 16) {
      if store.priorityOnly {
        Button { store.priorityOnly = false; store.reconcileSelection() } label: {
          HStack(spacing: 6) {
            Text("Needs attention \(store.attentionCount)")
            Image(systemName: "xmark").font(.cove(size: 9, weight: .semibold))
          }.font(.coveControl).foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
        }.help("Show the whole Inbox").accessibilityLabel("Clear Needs attention filter")
      } else if store.splitsInbox && store.folder == "Inbox" {
        let counts = store.inboxUnreadCounts
        ForEach(InboxSplit.allCases, id: \.self) { tab in
          let selected = store.inboxTab == tab && store.search.isEmpty
          Button { store.chooseInboxTab(tab) } label: {
            HStack(spacing: 5) {
              Text(tab.title).fontWeight(selected ? .medium : .regular)
              if let count = counts[tab], count > 0 {
                Text(count > 99 ? "99+" : "\(count)").font(.coveMetadata).monospacedDigit()
              }
            }.foregroundStyle(selected ? Palette.ink : Palette.muted)
              .padding(.bottom, 6)
              .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Palette.ink : .clear).frame(height: 2)
              }
              .fixedSize()
          }.help(tab == .important ? "People and mail that needs you" : "Newsletters, notifications and automated mail")
            .accessibilityLabel("\(tab.title), \(counts[tab] ?? 0) unread")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
      } else {
        Text("\(store.inboxUnreadCount) unread").foregroundStyle(Palette.body).padding(.bottom, 6)
      }
      Spacer(minLength: 0)
      if store.folder == "Inbox" && !store.priorityOnly {
        let on = store.labelUnreadOnly
        Button { store.labelUnreadOnly.toggle(); store.reconcileSelection() } label: {
          Label("Unread", systemImage: on ? "envelope.badge.fill" : "envelope.badge")
            .labelStyle(UnreadLabelStyle(iconOnly: compactUnread))
            .font(.coveControl).foregroundStyle(on ? Palette.canvas : Palette.body)
            .padding(.horizontal, 10).frame(height: 26)
            .background {
              RoundedRectangle(cornerRadius: 6).fill(on ? Palette.ink : Palette.canvas)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Palette.ink : Palette.line))
            }
            .fixedSize()
        }.focusEffectDisabled().help(on ? "Show read mail too" : "Show only unread mail")
          .accessibilityLabel("Unread only").accessibilityAddTraits(on ? .isSelected : [])
      }
    }.buttonStyle(.plain).font(.coveText).lineLimit(1)
  }
}

private struct UnreadLabelStyle: LabelStyle {
  let iconOnly: Bool
  func makeBody(configuration: Configuration) -> some View {
    if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
  }
}

/// Feedback for the split: this email, or every email from its sender. The vote always wins.
struct InboxSplitMenuItems: View {
  @Bindable var store: AppStore
  let mail: Mail
  var body: some View {
    if store.splitsInbox && !mail.labels.contains("DRAFT") && !mail.labels.contains("SENT") {
      let target = store.inboxSplit(of: mail).opposite
      let sender = mail.sender.isEmpty ? mail.senderEmail : mail.sender
      Divider()
      Button("Move to \(target.title)", systemImage: target == .important ? "star" : "tray.2") {
        store.moveToInboxTab(mail, target)
      }
      Button("Always \(target.title) from \(sender)", systemImage: "person.crop.circle.badge.checkmark") {
        store.alwaysInboxTab(target, forSenderOf: mail)
      }
    }
  }
}

struct InboxMoveToast: View {
  @Bindable var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Group {
      if let undo = store.inboxMoveUndo {
        HStack(spacing: 12) {
          Text(undo.message).font(.coveControl).lineLimit(1)
          Button("Undo") { store.undoInboxMove() }
            .buttonStyle(.plain).font(.coveControl).padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
          .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
          .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
          .padding(.horizontal, 16)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.inboxMoveUndo?.id)
  }
}
