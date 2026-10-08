#if os(iOS)
import CoveCore
import SwiftUI

/// Cove for iPad: the Mac's three columns. A gray sidebar (wordmark, New message, Home, Mail and its
/// folders, Calendar, Tasks, Contacts, then Settings), the mail list, and the reader, which stays empty
/// until an email is chosen (docs/design-source/InboxUnselected.html). Other destinations fill the
/// space beside the sidebar. In Slide Over or narrow Split View the app uses the iPhone tabs instead.
struct MobileIPadRoot: View {
  let auth: MobileAuth
  @Bindable var mailbox: MobileMailbox
  let workspace: MobileWorkspace
  let ai: MobileAI
  @State private var destination: Destination = .home
  @State private var selectedMail: String?
  @State private var columns: NavigationSplitViewVisibility = .all
  @State private var composing = false
  @State private var showSettings = false

  enum Destination: Hashable { case home, mail, calendar, tasks, contacts }

  init(auth: MobileAuth, mailbox: MobileMailbox, workspace: MobileWorkspace, ai: MobileAI) {
    self.auth = auth
    self.mailbox = mailbox
    self.workspace = workspace
    self.ai = ai
    #if DEBUG
    // Screenshot checks: the same `-CoveTab` names pick the sidebar destination.
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "-CoveTab"), arguments.indices.contains(index + 1) {
      let map: [String: Destination] = ["home": .home, "mail": .mail, "calendar": .calendar, "tasks": .tasks, "contacts": .contacts]
      _destination = State(initialValue: map[arguments[index + 1]] ?? .home)
    }
    // `-CoveHideSidebar` checks the wide (landscape-width) layouts on a portrait simulator.
    if arguments.contains("-CoveHideSidebar") { _columns = State(initialValue: .detailOnly) }
    #endif
  }

  var body: some View {
    Group {
      if destination == .mail {
        NavigationSplitView(columnVisibility: $columns) {
          sidebar
        } content: {
          MobileInboxView(mailbox: mailbox, ai: ai, workspace: workspace, selection: $selectedMail)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
          reader
        }
      } else {
        NavigationSplitView(columnVisibility: $columns) {
          sidebar
        } detail: {
          page
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $composing) { MobileComposeView(mailbox: mailbox, ai: ai, draft: .init()) }
    .sheet(isPresented: $showSettings) { MobileSettingsView(auth: auth, mailbox: mailbox, workspace: workspace, ai: ai) }
    .onChange(of: mailbox.folder) { _, _ in selectedMail = nil }
    .onChange(of: mailbox.inboxTab) { _, _ in selectedMail = nil }
    #if DEBUG
    .task {
      if ProcessInfo.processInfo.arguments.contains("-CoveOpenFirst") {
        try? await Task.sleep(for: .milliseconds(300))
        selectedMail = mailbox.visible.first?.id
      }
    }
    #endif
  }

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 18) {
      MobileWordmark(size: 24).padding(.top, 8).padding(.horizontal, 6)
      Button { composing = true } label: {
        Label("New message", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
      }.buttonStyle(MobilePrimaryButton(expands: true))
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          nav("Home", icon: "house", selected: destination == .home) { destination = .home }
          nav("Mail", icon: "tray", selected: destination == .mail,
              badge: destination == .mail ? nil : mailbox.unreadCount(.important)) { destination = .mail }
          nav("Calendar", icon: "calendar", selected: destination == .calendar) { destination = .calendar }
          nav("Contacts", icon: "person.crop.rectangle", selected: destination == .contacts) { destination = .contacts }
          nav("Tasks", icon: "checklist", selected: destination == .tasks,
              badge: workspace.openTasks.isEmpty ? nil : workspace.openTasks.count) { destination = .tasks }
          if destination == .mail {
            Text("Mail").font(.mobileMetadata).foregroundStyle(MobilePalette.body)
              .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach(MobileMailbox.Folder.allCases) { folder in
              nav(folder.title, icon: folder.systemImage, selected: mailbox.folder == folder,
                  badge: folder == .inbox ? mailbox.unreadCount(.important) : nil) { mailbox.folder = folder }
            }
          }
        }
      }
      Spacer(minLength: 0)
      if mailbox.syncing || mailbox.historyStatus != nil || mailbox.status != nil {
        HStack(spacing: 8) {
          if mailbox.syncing || mailbox.historyStatus != nil { ProgressView() }
          Text(mailbox.status ?? mailbox.historyStatus ?? "Checking Gmail…").lineLimit(3)
        }.font(.mobileMetadata).foregroundStyle(MobilePalette.body)
      }
      VStack(spacing: 2) {
        nav("Settings", icon: "gearshape", selected: false) { showSettings = true }
        HStack(spacing: 10) {
          MobileAvatar(name: auth.email ?? "", size: 26)
          Text(auth.email ?? "").font(.mobileMetadata).foregroundStyle(MobilePalette.body).lineLimit(1)
        }.padding(.horizontal, 10).padding(.top, 6)
      }
    }
    .padding(.horizontal, 14).padding(.bottom, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(MobilePalette.sidebar)
    .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 280)
    .toolbar(.hidden, for: .navigationBar)
  }

  private func nav(_ title: String, icon: String, selected: Bool, badge: Int? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 11) {
        Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
        Text(title).font(selected ? .mobileLabel : .coveMobile(13, relativeTo: .callout))
        Spacer()
        if let badge, badge > 0 { Text("\(badge)").font(.mobileCaption).monospacedDigit() }
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(.horizontal, 10).frame(minHeight: 40)
      .background(selected ? MobilePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: Columns

  @ViewBuilder private var reader: some View {
    if let id = selectedMail, mailbox.mail(id: id) != nil {
      NavigationStack {
        MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id) { selectNext(after: id) }
          .id(id)
      }
    } else {
      VStack(spacing: 14) {
        Image(systemName: "envelope.open").font(.system(size: 26)).foregroundStyle(MobilePalette.ink)
          .frame(width: 64, height: 64).background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 14))
        Text("No email selected").font(.mobileDetailTitle).foregroundStyle(MobilePalette.ink)
        Text("Choose an email from the list to read it here.").font(.mobileSecondary).foregroundStyle(MobilePalette.body)
        Text("Your mail stays encrypted on this iPad.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MobilePalette.canvas)
    }
  }

  /// After archive, unread or trash, the next email in the list opens (or the empty reader).
  private func selectNext(after id: String) {
    let list = mailbox.visible
    if let index = list.firstIndex(where: { $0.id == id }) {
      let rest = list.filter { $0.id != id }
      selectedMail = rest.indices.contains(index) ? rest[index].id : rest.last?.id
    } else {
      selectedMail = nil
    }
  }

  @ViewBuilder private var page: some View {
    switch destination {
    case .home:
      MobileHomeView(auth: auth, mailbox: mailbox, workspace: workspace, ai: ai, tab: tabBinding)
    case .calendar:
      MobileCalendarView(auth: auth, workspace: workspace)
    case .tasks:
      MobileTasksView(auth: auth, workspace: workspace, mailbox: mailbox, ai: ai)
    case .contacts:
      MobileContactsView(mailbox: mailbox, ai: ai, workspace: workspace, inline: true)
    case .mail:
      EmptyView()
    }
  }

  /// Home's "Open Mail / Calendar / Tasks" buttons move the sidebar selection.
  private var tabBinding: Binding<MobileTab> {
    Binding(get: { .home }, set: { tab in
      switch tab {
      case .mail, .search: destination = .mail
      case .calendar: destination = .calendar
      case .tasks: destination = .tasks
      case .home: destination = .home
      }
    })
  }
}
#endif
