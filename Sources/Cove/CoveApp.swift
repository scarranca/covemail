import CoveCore
import SwiftUI

/// Reopens Cove's window from the Dock or Finder. Closing the window keeps Cove running (sync,
/// drafts and state live in the app), but AppKit can count leftover helper windows as "visible",
/// so SwiftUI's default reopen may never create a new window. This decides explicitly.
final class CoveAppDelegate: NSObject, NSApplicationDelegate {
  /// Opens a new main window; set by the first window that appears (valid after it closes).
  @MainActor static var openMainWindow: (() -> Void)?
  /// Windows showing Cove's main view; a window leaves this set when it closes. Helper windows
  /// (toolbars, previews) are never candidates.
  @MainActor static let mainWindows = NSHashTable<NSWindow>.weakObjects()
  @MainActor static func track(_ window: NSWindow) {
    guard !mainWindows.contains(window) else { return }
    mainWindows.add(window)
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
      MainActor.assumeIsolated { if let closed = note.object as? NSWindow { mainWindows.remove(closed) } }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { Self.showMainWindow(in: Self.mainWindows.allObjects) }
    return false
  }

  enum ReopenAction: Equatable { case none, restore, open }
  /// Pure decision, testable without AppKit windows: a showing main window needs nothing; a
  /// minimized or hidden one is restored; otherwise a new window opens.
  static func reopenAction(windows: [(canBecomeMain: Bool, visible: Bool, minimized: Bool)]) -> ReopenAction {
    let main = windows.filter(\.canBecomeMain)
    if main.contains(where: { $0.visible && !$0.minimized }) { return .none }
    return main.isEmpty ? .open : .restore
  }

  @MainActor static func showMainWindow(in windows: [NSWindow], activate: () -> Void = { NSApp.activate() }) {
    let candidates = windows
    switch reopenAction(windows: candidates.map { (true, $0.isVisible, $0.isMiniaturized) }) {
    case .none:
      activate()
    case .restore:
      let window = candidates.first { $0.isMiniaturized } ?? candidates[0]
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      activate()
    case .open:
      openMainWindow?()
      activate()
    }
  }
}

@main struct CoveApp: App {
  @NSApplicationDelegateAdaptor(CoveAppDelegate.self) private var appDelegate
  @State private var store: AppStore
  @StateObject private var updater = AppUpdater.shared
  init() {
    DesignAssets.registerFonts()
    let store = AppStore()
    _store = State(initialValue: store)
    // Owned for the life of the app: nothing in the scene reads it, so @State wouldn't keep it alive.
    MeetingMenuBarModel.start(store: store)
  }
  var body: some Scene {
    WindowGroup(id: "main") {
      RootView(store: store)
        .modifier(MainWindowOpener())
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
          store.syncing || !store.entered)
        Button("Ask Cove") { store.showAssistant = true }.keyboardShortcut("j").disabled(
          !store.entered)
      }
      CommandMenu("Go") {
        Button("Home") { store.screen = "home" }.keyboardShortcut("0").disabled(!store.entered)
        Button("Mail") { store.chooseFolder("Inbox") }.keyboardShortcut("1")
        Button("Calendar") { store.screen = "calendar" }.keyboardShortcut("2")
        Button("Contacts") { store.screen = "contacts" }.keyboardShortcut("4").disabled(
          !store.entered)
        Button("Tasks") { store.screen = "tasks" }.keyboardShortcut("5").disabled(!store.entered)
        Button("Your Agents") { store.screen = "agents" }.keyboardShortcut("3")
        Button("Categories") { store.screen = "categories" }.disabled(!store.entered)
        Button("Connections") { store.screen = "integrations" }.disabled(!store.entered)
      }
      CommandMenu("Account") {
        // ⌃1…⌃9: ⌘0–⌘5 already go to Cove's destinations.
        ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element) { index, email in
          Button(email) { Task { await store.switchAccount(to: email) } }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
            .disabled(store.switchingAccount || email.caseInsensitiveCompare(store.accountEmail) == .orderedSame)
        }
        if !store.accounts.isEmpty { Divider() }
        Button("Add Account…") { Task { await store.addAccount() } }
          .disabled(store.isSample || store.busy || store.switchingAccount)
        Button("Add Work Account (Own Google Client)…") { store.showOrgClientSheet = true }
          .disabled(store.isSample || store.busy || store.switchingAccount)
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
          case "tasks": TasksView(store: store)
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
    .overlay(alignment: .bottom) {
      VStack(spacing: 8) { SignInWaitingBar(store: store); SendUndoToast(store: store); MailDeletionToast(store: store) }.padding(.bottom, 22)
    }
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
      store.pollCloud()
      store.pollPersonal()
      await store.refreshLabels(force: false)
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(30))
          store.now = Date()
          await store.pollMailbox()
          store.pollCloud()
          store.pollPersonal()
          await store.refreshLabels(force: false)
        } catch { break }
      }
    }
    .sheet(isPresented: $store.showAssistant, onDismiss: { store.assistantInitialQuery = "" }) {
      AssistantView(store: store, availableSize: availableSize, initialQuery: store.assistantInitialQuery)
    }
    .sheet(isPresented: $store.showComposer) { ComposerView(store: store, availableSize: availableSize) }
    .sheet(isPresented: $store.showOrgClientSheet) { OrgClientSheet(store: store) }
    .sheet(item: $store.taskSuggestionMail) { mail in TaskSuggestionsView(store: store, mail: mail) }
    .overlay(alignment: .bottom) { PostSendTaskToast(store: store) }
    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.postSend)
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
/// One navigation model on every screen: the same five destinations, then the current
/// destination's own sub-navigation, then Integrations and Settings at the bottom.
struct Sidebar: View {
  @Bindable var store: AppStore
  let folders: [(String, String)] = [
    ("Inbox", "tray"), ("Flagged", "flag"), ("Snoozed", "clock"), ("Sent", "paperplane"),
    ("Drafts", "doc.badge.ellipsis"), ("Archive", "archivebox"), ("Spam", "xmark.octagon"),
  ]
  private var inMail: Bool { store.screen == "mail" || store.screen == "categories" }
  private var inAgents: Bool { store.screen == "agents" || store.screen == "agent" }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Logo().padding(.top, 30)
      AccountSwitcher(store: store)
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
        VStack(spacing: 2) {
          nav("Home", icon: "house", selected: store.screen == "home", shortcut: "⌘0") { store.screen = "home" }
          nav("Mail", icon: "tray", selected: inMail, shortcut: "⌘1",
              badge: inMail ? nil : store.inboxBadgeCount) { store.chooseFolder("Inbox") }
          nav("Calendar", icon: "calendar", selected: store.screen == "calendar", shortcut: "⌘2") { store.screen = "calendar" }
          nav("Agents", icon: "sparkles", selected: inAgents, shortcut: "⌘3") { store.screen = "agents" }
          nav("Contacts", icon: "person.crop.rectangle", selected: store.screen == "contacts", shortcut: "⌘4") { store.screen = "contacts" }
          nav("Tasks", icon: "checklist", selected: store.screen == "tasks", shortcut: "⌘5") { store.screen = "tasks" }
          if inMail {
            section("Mail")
            ForEach(folders, id: \.0) { name, icon in
              nav(name, icon: icon, selected: store.screen == "mail" && store.folder == name,
                  badge: name == "Inbox" ? store.inboxBadgeCount : nil) {
                store.chooseFolder(name)
              }
            }
            nav("Categories", icon: "square.grid.2x2", selected: store.screen == "categories" || (store.screen == "mail" && store.selectedLabelID != nil)) {
              store.screen = "categories"
            }
            JevFlagsNavigation(store: store)
          } else if store.screen == "calendar" {
            CalendarNavigation(store: store).padding(.top, 18)
          } else if store.screen == "contacts" {
            section("Groups")
            ForEach(["All contacts", "Favorites"] + store.contactGroups, id: \.self) { group in
              nav(group, icon: group == "Favorites" ? "star" : "person.2",
                  selected: store.contactGroup == group) { store.contactGroup = group }
            }
          }
        }
      }
      Spacer(minLength: 0)
      if store.busy || store.syncing {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(store.status).lineLimit(2)
        }.font(.coveMetadata).foregroundStyle(Palette.body)
      } else if let lastSync = store.lastSync {
        Text("Checked \(lastSync.formatted(.relative(presentation: .named)))")
          .font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
      }
      VStack(spacing: 2) {
        // The count of what's left to connect nudges new users here without a separate onboarding screen.
        nav("Connections", icon: "square.stack.3d.up", selected: store.screen == "integrations",
            badge: store.isSample ? nil : Setup.remaining(store).count.nonZero) {
          store.screen = "integrations"
        }
        nav("Settings", icon: "gearshape", selected: false, shortcut: "⌘,") { store.showConnections = true }
      }
    }.padding(.horizontal, 18).padding(.bottom, 16).background(Palette.sidebar)
  }

  private func section(_ title: String) -> some View {
    Text(title).font(.coveMetadata).foregroundStyle(Palette.body)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
      .padding(.top, 16).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
  }

  func nav(_ name: String, icon: String, selected: Bool, shortcut: String? = nil, badge: Int? = nil,
           action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 11) {
        Image(systemName: icon).frame(width: 18)
        Text(name)
        Spacer()
        if let badge, badge > 0 {
          Text("\(badge)").font(.coveSecondary).foregroundStyle(Palette.body)
        }
      }.font(.coveLabel).padding(.horizontal, 10)
        .padding(.vertical, 9).background(
          selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7)
        ).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .help(shortcut.map { "\(name) (\($0))" } ?? name)
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The account at the top of the sidebar. With a real account it opens a menu of the signed-in
/// accounts (⌃1…⌃9), Add account… and Account settings…; the sample mailbox opens settings directly.
struct AccountSwitcher: View {
  @Bindable var store: AppStore

  var body: some View {
    if store.isSample {
      Button { store.showConnections = true } label: { AccountSwitcherLabel(store: store) }
        .buttonStyle(.plain)
        .help("Sample mailbox · account settings")
        .accessibilityLabel("Account: Alex Lee, sample mailbox")
    } else {
      Menu {
        ForEach(store.accounts, id: \.self) { email in
          Toggle(isOn: Binding(
            get: { email.caseInsensitiveCompare(store.accountEmail) == .orderedSame },
            set: { on in if on { Task { await store.switchAccount(to: email) } } }
          )) { Text(email) }
            .disabled(store.switchingAccount)
        }
        if !store.accounts.isEmpty { Divider() }
        Button("Add account…") { Task { await store.addAccount() } }
          .disabled(store.busy || store.switchingAccount)
        Button("Add work account (own Google client)…") { store.showOrgClientSheet = true }
          .disabled(store.busy || store.switchingAccount)
        Button("Account settings…") { store.showConnections = true }
      } label: {
        AccountSwitcherLabel(store: store)
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .fixedSize(horizontal: false, vertical: true)
      .help(store.accounts.count > 1 ? "Switch Gmail account (⌃1–⌃\(min(store.accounts.count, 9)))" : "Gmail accounts")
      .accessibilityLabel("Account: \(store.accountEmail)")
    }
  }
}

struct AccountSwitcherLabel: View {
  @Bindable var store: AppStore
  var body: some View {
    HStack(spacing: 10) {
      CoveAvatar(
        initials: store.isSample ? "AL" : String(store.accountEmail.prefix(2)).uppercased(),
        size: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(store.isSample ? "Alex Lee" : store.accountEmail).font(.coveLabel).lineLimit(1)
        if store.isSample {
          Text("Sample mailbox").font(.coveMetadata).foregroundStyle(Palette.body)
        } else if store.switchingAccount {
          Text("Switching…").font(.coveMetadata).foregroundStyle(Palette.body)
        } else if store.accounts.count > 1 {
          Text("\(store.accounts.count) accounts").font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.up.chevron.down").font(.cove(size: 10))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Captures SwiftUI's window opener so the Dock can open a new window after the last one closed.
private struct MainWindowOpener: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  func body(content: Content) -> some View {
    content
      .background(MainWindowReporter())
      .onAppear {
        let open = openWindow
        CoveAppDelegate.openMainWindow = { open(id: "main") }
      }
  }
}

private struct MainWindowReporter: NSViewRepresentable {
  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { CoveAppDelegate.track(window) }
    }
  }
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {}
}

/// While Cove waits for Google (Add account): the page to finish in any browser, and a way out.
struct SignInWaitingBar: View {
  @Bindable var store: AppStore
  @State private var copied = false
  var body: some View {
    if let url = store.signInURL {
      HStack(spacing: 12) {
        ProgressView().controlSize(.small)
        Text("Finish signing in to Google in your browser").font(.coveSecondary).foregroundStyle(Palette.ink)
        Button(copied ? "Copied" : "Copy link") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
          copied = true
        }.buttonStyle(SecondaryButton(compact: true)).help("Paste it into another browser to sign in there")
        Button("Open again") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButton(compact: true))
        Button("Cancel") { store.cancelSignIn() }.buttonStyle(PrimaryButton(compact: true))
      }
      .padding(.leading, 16).padding(.trailing, 8).frame(height: 46)
      .background(Palette.canvas, in: Capsule())
      .overlay(Capsule().strokeBorder(Palette.line))
      .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
      .accessibilityElement(children: .contain)
    }
  }
}

/// Add a work account with the organization's own Google client (Internal), so it needs no Google
/// verification or tester list. The ID and secret are used for this sign-in and saved with its session.
struct OrgClientSheet: View {
  @Bindable var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var clientID = ""
  @State private var secret = ""
  @State private var showSteps = false
  private var config: GoogleOAuthConfiguration { GoogleOAuthConfiguration(clientID: clientID, clientSecret: secret) }
  private var valid: Bool { config.isConfigured && !config.clientSecret.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline) {
        Text("Add a work account").font(.coveDetailTitle)
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").font(.cove(size: 12)) }
          .buttonStyle(.plain).foregroundStyle(Palette.body).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
      }
      Text("Use your organization’s own Google client. Accounts in your Google Workspace can then sign in without Cove’s tester list. The client is used only for this account.")
        .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 10) {
        TextField("Client ID", text: $clientID, prompt: Text("1234-abc.apps.googleusercontent.com").foregroundStyle(Palette.muted))
          .textFieldStyle(CoveFieldStyle()).accessibilityLabel("Client ID")
        SecureField("Client secret", text: $secret, prompt: Text("Client secret").foregroundStyle(Palette.muted))
          .textFieldStyle(CoveFieldStyle()).accessibilityLabel("Client secret")
        if !clientID.isEmpty && !config.isConfigured {
          Text("A client ID ends in .apps.googleusercontent.com.").font(.coveMetadata).foregroundStyle(Palette.danger)
        }
      }
      DisclosureGroup("How your admin sets this up (about 15 minutes)", isExpanded: $showSteps) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("\(index + 1).").font(.coveSecondary).foregroundStyle(Palette.muted).frame(width: 16, alignment: .trailing)
              Text(step).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
            }
          }
        }.padding(.top, 10)
      }.font(.coveSecondary).foregroundStyle(Palette.body).disclosureGroupStyle(CoveDisclosureStyle())
      HStack(spacing: 16) {
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        Button("Continue in browser") {
          let client = config
          dismiss()
          Task { await store.addAccount(client: client) }
        }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(!valid)
      }
    }
    .padding(30).frame(width: 520).background(Palette.canvas)
  }

  static let steps = [
    "In Google Cloud Console, create a project for your organization.",
    "APIs & Services → Library: enable the Gmail API, Google Calendar API and Google Tasks API.",
    "Google Auth Platform → Branding: app name “Cove”, your support email. Audience: choose Internal.",
    "Data Access → Add scopes: gmail.modify, calendar.events and tasks (add openid and email only if you use Cove cloud sync).",
    "Clients → Create client → Application type: Desktop app. Copy its Client ID and Client secret here.",
  ]
}
