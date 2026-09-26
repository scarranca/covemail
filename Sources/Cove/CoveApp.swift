import SwiftUI

@main struct CoveApp: App {
  @State private var store = AppStore()
  @StateObject private var updater = AppUpdater.shared
  init() { DesignAssets.registerFonts() }
  var body: some Scene {
    WindowGroup {
      RootView(store: store)
        .task { updater.start(store: store) }
        .frame(minWidth: 1040, minHeight: 700)
        .preferredColorScheme(.light)
    }
    .defaultSize(width: 1420, height: 920)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        Button(updater.menuTitle, action: updater.checkForUpdates)
          .disabled(!updater.canCheck && !updater.restartPending)
      }
      CommandGroup(replacing: .newItem) {
        Button(store.newItemTitle) {
          store.startNewItem()
        }.keyboardShortcut("n").disabled(!store.entered)
      }
      CommandGroup(after: .newItem) {
        Button("Sync Gmail") { Task { await store.sync() } }.keyboardShortcut("r").disabled(
          store.busy || !store.entered)
        Button("Ask Cove") { store.showAssistant = true }.keyboardShortcut("j").disabled(
          !store.entered)
      }
      CommandMenu("Go") {
        Button("Home") { store.screen = "home" }.keyboardShortcut("0").disabled(!store.entered)
        Button("Mail") { store.chooseFolder("Inbox") }.keyboardShortcut("1")
        Button("Calendar") { store.screen = "calendar" }.keyboardShortcut("2")
        Button("Contacts") { store.screen = "contacts" }.keyboardShortcut("4").disabled(
          !store.entered)
        Button("Your Agents") { store.screen = "agents" }.keyboardShortcut("3")
        Button("Categories") { store.screen = "categories" }.disabled(!store.entered)
        Button("Integrations") { store.screen = "integrations" }.disabled(!store.entered)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { store.showConnections = true }.keyboardShortcut(",")
      }
    }
  }
}

struct Logo: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "water.waves").font(.cove(size: 28, weight: .medium))
      Text("cove").font(.cove(size: 26, weight: .semibold))
    }.foregroundStyle(Palette.ink)
  }
}
struct RootView: View {
  @Bindable var store: AppStore
  @State private var availableSize = CGSize(width: 1420, height: 920)
  var body: some View {
    Group {
      if store.showConnections {
        SettingsView(store: store)
      } else if store.entered {
        HStack(spacing: 0) {
          if store.screen == "integrations" {
            SettingsSidebar(store: store, section: "Integrations") { destination in
              store.settingsSection = destination
              store.showConnections = true
            }.frame(width: 224)
          } else {
            Sidebar(store: store).frame(width: 224)
          }
          Divider()
          switch store.screen {
          case "home": AgentHubView(store: store)
          case "agent": AgentView(store: store)
          case "agents": CustomAgentsView(store: store)
          case "calendar": CalendarView(store: store)
          case "contacts": ContactsView(store: store)
          case "categories": MailCategoriesView(store: store)
          case "integrations": IntegrationsView(store: store)
          default: MailboxView(store: store)
          }
        }
      } else {
        WelcomeView(store: store)
      }
    }
    .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
      if store.connectionIssue != nil {
        ConnectionStatusTag(store: store).padding(.horizontal, 18).padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas)
      }
    }
    .overlay(alignment: .bottom) { MailDeletionToast(store: store).padding(.bottom, 22) }
    .background(MailDeleteShortcut(store: store).frame(width: 0, height: 0))
    .font(.coveBody).tint(Palette.ink).foregroundStyle(Palette.ink).background(Palette.canvas)
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { availableSize = geometry.size }
          .onChange(of: geometry.size) { _, size in availableSize = size }
      }
    }
    .task {
      if store.needsContentRefresh { await store.sync() }
      await store.pollMailbox()
      await store.refreshLabels(force: false)
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(30))
          store.now = Date()
          await store.pollMailbox()
          await store.refreshLabels(force: false)
        } catch { break }
      }
    }
    .sheet(isPresented: $store.showAssistant) {
      AssistantView(store: store, availableSize: availableSize)
    }
    .sheet(isPresented: $store.showComposer) { ComposerView(store: store, availableSize: availableSize) }
    .alert(
      "Cove couldn’t finish",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK") { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
}
struct Sidebar: View {
  @Bindable var store: AppStore
  let folders: [(String, String)] = [
    ("Inbox", "tray"), ("Flagged", "flag"), ("Snoozed", "clock"), ("Sent", "paperplane"),
    ("Drafts", "doc.badge.ellipsis"), ("Archive", "archivebox"),
  ]
  var body: some View {
    VStack(alignment: .leading, spacing: store.screen == "calendar" ? 12 : 22) {
      Logo().padding(.top, store.screen == "calendar" ? 24 : 35)
      Button {
        store.showConnections = true
      } label: {
        HStack(spacing: 10) {
          CoveAvatar(
            initials: store.isSample ? "AL" : String(store.accountEmail.prefix(2)).uppercased(),
            size: 34)
          VStack(alignment: .leading, spacing: 3) {
            Text(store.isSample ? "Alex Lee" : store.accountEmail).font(
              .coveLabel
            ).lineLimit(1)
            Text(store.isSample ? "Sample mailbox" : "Personal · Gmail").font(.coveMetadata)
              .foregroundStyle(Palette.body)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down").font(.cove(size: 10))
        }
      }.buttonStyle(.plain)
      Button {
        store.startNewItem()
      } label: {
        HStack {
          Image(systemName: store.screen == "contacts" || store.screen == "calendar" || store.screen == "agents" ? "plus" : "square.and.pencil")
          Text(store.newItemTitle)
          Spacer()
          Text("⌘ N").opacity(0.65).font(.coveMetadata)
        }.frame(maxWidth: .infinity)
      }.buttonStyle(PrimaryButton())
      ScrollView {
        VStack(spacing: 3) {
          if store.screen == "home" {
            nav("Agent Hub", icon: "sparkles", selected: true) {}
            nav("Mail", icon: "tray", selected: false) { store.chooseFolder("Inbox") }
            nav("Calendar", icon: "calendar", selected: false) { store.screen = "calendar" }
            nav("Contacts", icon: "person.crop.rectangle", selected: false) { store.screen = "contacts" }
            nav("Agents", icon: "sparkles", selected: false) { store.screen = "agents" }
          } else if store.screen == "calendar" {
            nav("Home", icon: "house", selected: false) { store.screen = "home" }
            nav("Mail", icon: "tray", selected: false) { store.chooseFolder("Inbox") }
            nav("Calendar", icon: "calendar", selected: true) {}
            nav("Contacts", icon: "person.crop.rectangle", selected: false) { store.screen = "contacts" }
            CalendarNavigation(store: store).padding(.top, 12)
          } else if store.screen == "contacts" {
            nav("Mail", icon: "tray", selected: false) { store.chooseFolder("Inbox") }
            nav("Calendar", icon: "calendar", selected: false) { store.screen = "calendar" }
            nav("Contacts", icon: "person.crop.rectangle", selected: true) {}
            nav("Agents", icon: "sparkles", selected: false) { store.screen = "agents" }
            contactNavigation
          } else {
            nav("Home", icon: "house", selected: store.screen == "home") {
              store.screen = "home"
            }
            ForEach(folders, id: \.0) { name, icon in
              nav(name, icon: icon, selected: store.screen == "mail" && store.folder == name) {
                store.chooseFolder(name)
              }
            }
            nav("Categories", icon: "square.grid.2x2", selected: store.screen == "categories" || (store.screen == "mail" && store.selectedLabelID != nil)) {
              store.screen = "categories"
            }
            JevFlagsNavigation(store: store)
            Divider().padding(.vertical, 12)
            nav("Calendar", icon: "calendar", selected: store.screen == "calendar") {
              store.screen = "calendar"
            }
            nav("Contacts", icon: "person.crop.rectangle", selected: store.screen == "contacts") {
              store.screen = "contacts"
            }
            nav("Agents", icon: "sparkles", selected: store.screen == "agents") {
              store.screen = "agents"
            }
          }
        }
      }
      Spacer(minLength: 0)
      if store.screen == "calendar" {
        Button { store.screen = "agents" } label: {
          Label("Your agents", systemImage: "sparkles").font(.coveSecondary)
        }.buttonStyle(.plain)
      } else {
      Button {
        store.screen = "agents"
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          Label("Your agents", systemImage: "sparkles").font(.coveLabel)
          Text(
            store.busy
              ? store.status : "\(store.customAgents.agents.filter { $0.status == .active }.count) active · \(store.customAgents.agents.count) custom agents"
          ).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(2)
          if store.screen == "home", let lastSync = store.lastSync {
            Text("Last checked \(lastSync.formatted(.relative(presentation: .named)))")
              .font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
          RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
      }.buttonStyle(.plain)
      }
      if store.screen != "home" {
      Button {
        store.screen = "integrations"
      } label: {
        Label("Integrations", systemImage: "square.stack.3d.up")
          .font(.coveLabel)
      }.buttonStyle(.plain).foregroundStyle(store.screen == "integrations" ? Palette.ink : Palette.body)
      Button {
        store.showConnections = true
      } label: {
        Label("Settings", systemImage: "gearshape").font(.coveLabel)
      }.buttonStyle(.plain).foregroundStyle(Palette.body)
      }
    }.padding(.horizontal, 18).padding(.bottom, 20).background(Palette.sidebar)
  }
  private var contactNavigation: some View {
    VStack(spacing: 3) {
      Text("Your groups").font(.coveMetadata).foregroundStyle(Palette.body)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 16)
      ForEach(["All contacts", "Favorites"] + store.contactGroups, id: \.self) { group in
        nav(
          group, icon: group == "Favorites" ? "star" : "person.2",
          selected: store.contactGroup == group
        ) { store.contactGroup = group }
      }
    }
  }
  func nav(_ name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      HStack(spacing: 11) {
        Image(systemName: icon).frame(width: 18)
        Text(name)
        Spacer()
        if name == "Inbox" {
          Text("\(store.inboxCount)").font(.coveSecondary).foregroundStyle(Palette.body)
        }
      }.font(.coveLabel).padding(.horizontal, 10)
        .padding(.vertical, 10).background(
          selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7)
        ).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}
