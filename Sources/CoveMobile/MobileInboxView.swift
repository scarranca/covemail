#if os(iOS)
import CoveCore
import SwiftUI

/// Mail, as in the Mac's mail column (docs/design-source/Main.html and the Pen `1. Cove` frame): a
/// 24-point folder title, search, Important / Other with an Unread filter, date sections and rows
/// whose unread mail is white and bold while read mail sits on F7F7F7.
struct MobileInboxView: View {
  @Bindable var mailbox: MobileMailbox
  let ai: MobileAI
  let workspace: MobileWorkspace
  @State private var path: [String] = []
  @State private var composing = false
  @State private var query = ""
  @State private var gmailSearch: Task<Void, Never>?
  @FocusState private var searchFocused: Bool
  /// On iPad the list is a column: a tap selects the email for the reader beside it (as on the Mac)
  /// instead of pushing it.
  var selection: Binding<String?>?
  /// Several emails chosen with two fingers (or Select), for one action on all of them.
  @State private var picked: Set<String> = []
  @State private var editMode: EditMode = .inactive
  private var picking: Bool { editMode.isEditing }

  private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    if selection != nil {
      list
    } else {
      NavigationStack(path: $path) {
        list.navigationDestination(for: String.self) { id in
          MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
        }
      }
    }
  }

  private func open(_ id: String) {
    if let selection { selection.wrappedValue = id } else { path.append(id) }
  }

  private var list: some View {
      // A multiple-selection list: iOS selects rows with a two-finger drag (and trackpad drags),
      // entering selection mode on its own.
      List(selection: $picked) {
        header.listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
          .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface).selectionDisabled()
        if searching {
          searchResults
        } else {
          mailRows(mailbox.visible, sections: true, paginates: true)
          footer.listRowSeparator(.hidden).listRowBackground(MobilePalette.surface).selectionDisabled()
        }
      }
      .environment(\.editMode, $editMode)
      .onChange(of: picked) { _, ids in
        if !ids.isEmpty && !picking { withAnimation { editMode = .active } }
      }
      .onChange(of: mailbox.folder) { _, _ in endPicking() }
      .safeAreaInset(edge: .bottom) { if picking { bulkBar } }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(MobilePalette.surface)
      .environment(\.defaultMinListRowHeight, 0)
      .refreshable { await mailbox.sync() }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $composing) { MobileComposeView(mailbox: mailbox, ai: ai, draft: .init()) }
      .sheet(item: $mailbox.restoredDraft) { draft in MobileComposeView(mailbox: mailbox, ai: ai, draft: draft) }
      #if DEBUG
      .onAppear {
        // Screenshot checks: `-CoveOpenFirst` opens the newest email; `-CoveCompose` opens the composer.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CoveOpenFirst"), path.isEmpty, let first = mailbox.visible.first { open(first.id) }
        if arguments.contains("-CoveCompose") { composing = true }
        if arguments.contains("-CoveSelectSome") {
          editMode = .active
          picked = Set(mailbox.visible.prefix(2).map(\.id))
        }
        if let index = arguments.firstIndex(of: "-CoveOpen"), arguments.indices.contains(index + 1), path.isEmpty,
           let mail = mailbox.allLoaded.first(where: { $0.subject.localizedCaseInsensitiveContains(arguments[index + 1]) }) {
          open(mail.id)
        }
      }
      #endif
      .alert("Cove", isPresented: Binding(get: { mailbox.error != nil }, set: { if !$0 { mailbox.error = nil } })) {
        Button("OK", role: .cancel) { mailbox.error = nil }
      } message: { Text(mailbox.error ?? "") }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 4) {
        Menu {
          Picker("Folder", selection: $mailbox.folder) {
            ForEach(MobileMailbox.Folder.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
          }
        } label: {
          HStack(spacing: 6) {
            Text(mailbox.folder.title).font(.mobileTitle).foregroundStyle(MobilePalette.ink)
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(MobilePalette.body)
          }
        }
        .accessibilityLabel("Folder: \(mailbox.folder.title)").accessibilityHint("Choose another folder")
        Spacer()
        Button { Task { await mailbox.sync() } } label: {
          if mailbox.syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
        }.buttonStyle(MobileIconButton()).disabled(mailbox.syncing).accessibilityLabel("Sync Gmail")
        if picking {
          Button("Done") { endPicking() }.buttonStyle(MobileSecondaryButton(compact: true))
        } else {
          Button("Select") { withAnimation { editMode = .active } }.font(.mobileControl).foregroundStyle(MobilePalette.body)
            .padding(.horizontal, 6)
          Button { composing = true } label: { Image(systemName: "square.and.pencil") }
            .buttonStyle(MobileIconButton()).accessibilityLabel("New email")
        }
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(MobilePalette.muted)
        TextField("Search your mail", text: $query, prompt: Text("Search your mail").foregroundStyle(MobilePalette.muted))
          .font(.mobileText).focused($searchFocused).submitLabel(.search)
          .onSubmit { searchGmail() }
          .onChange(of: query) { _, value in
            if value.isEmpty { gmailSearch?.cancel(); mailbox.clearSearch() }
          }
        if !query.isEmpty {
          Button { query = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill") }
            .foregroundStyle(MobilePalette.muted).accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 12).frame(minHeight: 42)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? MobilePalette.ink : MobilePalette.line))
      if !searching { filterBar }
    }
    .padding(.bottom, 6)
  }

  @ViewBuilder private var filterBar: some View {
    HStack(alignment: .bottom, spacing: 16) {
      if mailbox.folder == .inbox && mailbox.splitInbox {
        MobileUnderlineTabs(selection: $mailbox.inboxTab, options: InboxSplit.allCases.map {
          ($0, $0.title, mailbox.unreadCount($0))
        })
      } else {
        Text(statusLine).font(.mobileSecondary).foregroundStyle(MobilePalette.body).padding(.vertical, 8)
      }
      Spacer(minLength: 0)
      if mailbox.folder == .inbox {
        let on = mailbox.unreadOnly
        Button { mailbox.unreadOnly.toggle() } label: {
          Label("Unread", systemImage: on ? "envelope.badge.fill" : "envelope.badge")
            .font(.mobileControl).foregroundStyle(on ? MobilePalette.canvas : MobilePalette.body)
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? MobilePalette.ink : MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? MobilePalette.ink : MobilePalette.line))
        }
        .buttonStyle(.plain).padding(.bottom, 4)
        .accessibilityLabel("Unread only").accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }

  private var statusLine: String {
    let count = mailbox.visible.count
    let unread = mailbox.visible.filter(\.isUnread).count
    return "\(count) downloaded" + (unread > 0 ? " · \(unread) unread" : "")
  }

  // MARK: Rows

  @ViewBuilder
  private func mailRows(_ mails: [Mail], sections: Bool, paginates: Bool) -> some View {
    ForEach(Array(mails.enumerated()), id: \.element.id) { index, mail in
      if sections && (index == 0 || MobileDates.section(mail.date) != MobileDates.section(mails[index - 1].date)) {
        Text(MobileDates.section(mail.date)).font(.mobileControl).foregroundStyle(MobilePalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
          .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface)
          .accessibilityAddTraits(.isHeader).selectionDisabled()
      }
      // A plain button, so rows have no disclosure chevron (the Mac's rows have none).
      Group {
        if picking {
          // While choosing, a tap toggles the email instead of opening it.
          MobileMailRow(mail: mail)
        } else {
          Button { open(mail.id) } label: { MobileMailRow(mail: mail) }.buttonStyle(MobileRowButtonStyle())
        }
      }
        .tag(mail.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(picked.contains(mail.id) || selection?.wrappedValue == mail.id ? MobilePalette.mailSelection
                           : mail.isUnread ? MobilePalette.canvas : MobilePalette.mailRead)
        .listRowSeparatorTint(MobilePalette.line)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          if mail.labels.contains("INBOX") {
            Button { mailbox.archive(mail) } label: { Label("Archive", systemImage: "archivebox") }.tint(MobilePalette.ink)
          }
          Button(role: .destructive) { mailbox.trash(mail) } label: { Label("Delete", systemImage: "trash") }
            .tint(MobilePalette.danger)
        }
        .swipeActions(edge: .leading) {
          Button { mailbox.setRead(mail, mail.isUnread) } label: {
            Label(mail.isUnread ? "Read" : "Unread", systemImage: mail.isUnread ? "envelope.open" : "envelope.badge")
          }.tint(Color(white: 0.45))
          Button { mailbox.toggleStar(mail) } label: {
            Label(mail.isStarred ? "Unflag" : "Flag", systemImage: mail.isStarred ? "flag.slash" : "flag")
          }.tint(MobilePalette.badgeText)
        }
        .contextMenu {
          Button(mail.isStarred ? "Remove follow-up flag" : "Flag for follow-up", systemImage: "flag") { mailbox.toggleStar(mail) }
          if mail.labels.contains("INBOX") {
            Button("Archive", systemImage: "archivebox") { mailbox.archive(mail) }
          }
          Button(mail.isUnread ? "Mark as read" : "Mark as unread", systemImage: "envelope") { mailbox.setRead(mail, mail.isUnread) }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) { mailbox.trash(mail) }
        }
        .onAppear {
          // The real end of the list loads older mail; no Load more button (as on the Mac).
          if paginates, mail.id == mails.last?.id { Task { await mailbox.loadOlder() } }
        }
    }
  }

  @ViewBuilder private var searchResults: some View {
    let local = mailbox.localMatches(query)
    Text(local.isEmpty ? "Nothing matches on this iPhone" : "On this iPhone · \(local.count)")
      .font(.mobileControl).foregroundStyle(MobilePalette.muted)
      .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 8, trailing: 20))
      .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface).selectionDisabled()
    mailRows(local, sections: false, paginates: false)
    if let results = mailbox.searchResults {
      let fresh = results.filter { result in !local.contains { $0.id == result.id } }
      Text(fresh.isEmpty ? "No other matches in Gmail" : "More from Gmail · \(fresh.count)")
        .font(.mobileControl).foregroundStyle(MobilePalette.muted)
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
        .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface).selectionDisabled()
      mailRows(fresh, sections: false, paginates: false)
    } else {
      Button { searchGmail() } label: {
        HStack(spacing: 8) {
          if mailbox.searching { ProgressView() } else { Image(systemName: "magnifyingglass") }
          Text(mailbox.searching ? "Searching Gmail…" : "Search all of Gmail for “\(query)”")
        }
      }
      .buttonStyle(MobileSecondaryButton(expands: true)).disabled(mailbox.searching)
      .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20))
      .listRowSeparator(.hidden).listRowBackground(MobilePalette.surface).selectionDisabled()
    }
  }

  private func endPicking() {
    withAnimation { editMode = .inactive }
    picked = []
  }

  private var pickedMails: [Mail] {
    (mailbox.visible + (mailbox.searchResults ?? [])).filter { picked.contains($0.id) }
      .reduce(into: [Mail]()) { list, mail in if !list.contains(where: { $0.id == mail.id }) { list.append(mail) } }
  }

  /// Actions for the chosen emails, like the Mac's bulk changes: archive, read/unread, flag, Trash
  /// (one Undo for all of them).
  private var bulkBar: some View {
    let mails = pickedMails
    let allRead = !mails.isEmpty && mails.allSatisfy { !$0.isUnread }
    let allFlagged = !mails.isEmpty && mails.allSatisfy(\.isStarred)
    return VStack(spacing: 10) {
      HStack {
        Text(mails.isEmpty ? "Select emails" : mails.count == 1 ? "1 email selected" : "\(mails.count) emails selected")
          .font(.mobileLabel).foregroundStyle(MobilePalette.ink)
        Spacer()
        Button(picked.count == mailbox.visible.count ? "Deselect all" : "Select all") {
          picked = picked.count == mailbox.visible.count ? [] : Set(mailbox.visible.map(\.id))
        }.font(.mobileControl).foregroundStyle(MobilePalette.body)
      }
      HStack(spacing: 8) {
        bulkButton("Archive", "archivebox") { mailbox.archive(mails) }
          .disabled(!mails.contains { $0.labels.contains("INBOX") })
        bulkButton(allRead ? "Unread" : "Read", allRead ? "envelope.badge" : "envelope.open") { mailbox.setRead(mails, !allRead) }
        bulkButton(allFlagged ? "Unflag" : "Flag", allFlagged ? "flag.slash" : "flag") { mailbox.toggleStar(mails) }
        bulkButton("Delete", "trash", destructive: true) { mailbox.trash(mails) }
      }.disabled(mails.isEmpty)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .background(MobilePalette.canvas)
    .overlay(alignment: .top) { Divider().overlay(MobilePalette.line) }
  }

  private func bulkButton(_ title: String, _ icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
    Button {
      action()
      endPicking()
    } label: {
      VStack(spacing: 3) {
        Image(systemName: icon).font(.system(size: 16))
        Text(title).font(.mobileCaption)
      }.frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(MobileSecondaryButton(compact: true, destructive: destructive, expands: true))
  }

  private func searchGmail() {
    guard searching else { return }
    gmailSearch?.cancel()
    gmailSearch = Task { await mailbox.search(query) }
  }

  @ViewBuilder private var footer: some View {
    if mailbox.visible.isEmpty && !mailbox.syncing {
      if mailbox.folder == .inbox {
        MobileEmptyState(title: "All caught up",
                         detail: mailbox.unreadOnly ? "Nothing unread in \(mailbox.inboxTab.title)." : "Nothing in \(mailbox.inboxTab.title) right now.",
                         systemImage: "sun.horizon")
      } else {
        MobileEmptyState(title: "A little breathing room", detail: "Messages in \(mailbox.folder.title) will appear here.")
      }
    } else {
      HStack(spacing: 8) {
        if mailbox.syncing || mailbox.loadingOlder { ProgressView() }
        if let status = mailbox.status { Text(status) } else if mailbox.loadingOlder { Text("Loading older mail…") }
      }
      .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
      .frame(maxWidth: .infinity).padding(.vertical, 18)
    }
  }
}

/// One email, as the Mac's `MailRow`: unread dot, follow-up flag, sender and time, subject and preview.
struct MobileMailRow: View {
  let mail: Mail

  private var weight: Font.Weight { mail.isUnread ? .bold : .regular }
  private var titleColor: Color { mail.isUnread ? MobilePalette.ink : MobilePalette.mailReadText }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        if mail.isUnread { Circle().fill(MobilePalette.ink).frame(width: 8, height: 8).accessibilityHidden(true) }
        if mail.isStarred {
          Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(MobilePalette.ink)
            .accessibilityLabel("Flagged for follow-up")
        }
        Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender).font(.coveMobile(14, weight: weight, relativeTo: .subheadline))
          .lineLimit(1)
        Spacer(minLength: 6)
        Text(MobileDates.short(mail.date)).font(mail.isUnread ? .mobileCaption : .mobileMetadata)
          .foregroundStyle(mail.isUnread ? MobilePalette.body : MobilePalette.muted)
      }
      Text(mail.subject.isEmpty ? "(No subject)" : mail.subject)
        .font(.coveMobile(14, weight: mail.isUnread ? .bold : .regular, relativeTo: .subheadline)).lineLimit(1)
      Text(mail.body.prefix(220).replacingOccurrences(of: "\n", with: " "))
        .font(.mobileSecondary).foregroundStyle(MobilePalette.body).lineLimit(2)
      if !mail.draft.isEmpty || mail.labels.contains("DRAFT") || !mail.availableAttachments.isEmpty {
        HStack(spacing: 6) {
          if !mail.draft.isEmpty { MobileTag(text: "Draft ready", systemImage: "square.and.pencil") }
          else if mail.labels.contains("DRAFT") { MobileTag(text: "Draft", systemImage: "doc", fill: MobilePalette.badge) }
          if !mail.availableAttachments.isEmpty {
            MobileTag(text: "\(mail.availableAttachments.count)", systemImage: "paperclip")
          }
        }.padding(.top, 2)
      }
    }
    .foregroundStyle(titleColor)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20).padding(.vertical, 13)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(mail.isUnread ? "Unread" : "Read")
  }
}
#endif

#if os(iOS)
/// Rows darken to the Mac's selected color (#EBEBEB) while pressed.
struct MobileRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? MobilePalette.mailSelection : .clear)
  }
}
#endif
