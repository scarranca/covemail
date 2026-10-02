import CoveCore
import SwiftUI

/// Settings is a main-window destination, including before Gmail sign-in.
struct SettingsView: View {
  @Bindable var store: AppStore
  @State private var clientID = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
  @State private var secret = ""
  @State private var key = ""
  @State private var keyLoaded = false
  @State private var showAdvancedGoogle = false
  @State private var saved = false
  @State private var confirmErasure = false
  @AppStorage(MeetingMenuBarModel.enabledKey) private var meetingsInMenuBar = false
  var readSecret: (String) throws -> String? = { try Vault.read($0) }

  var selectedSection: String {
    switch store.settingsSection {
    case "Jev · Mail agent", "Reading", "Menu bar", "Privacy", "App updates": return store.settingsSection
    case "Cloud sync" where store.cloudConfigured: return "Cloud sync"
    default: return "Gmail"
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebar(store: store, section: selectedSection) { destination in
        store.settingsSection = destination
      }.frame(width: 224)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        Text(selectedSection).font(.coveTitle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 32).padding(.vertical, 24).accessibilityAddTraits(.isHeader)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            sectionContent
            if saved && (selectedSection == "Gmail" || selectedSection == "Jev · Mail agent") {
              Label("Credentials saved", systemImage: "checkmark.circle")
                .font(.coveSecondary).foregroundStyle(Palette.body)
            }
          }.frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading).padding(32)
        }.id(selectedSection)
      }.background(Palette.canvas)
    }
    .disclosureGroupStyle(CoveDisclosureStyle())
    .onAppear {
      showAdvancedGoogle = !BundledGoogleOAuth.configuration.isConfigured
      do {
        secret = try readSecret("googleClientSecret") ?? ""
        // With Touch ID on, opening Settings shouldn't ask for it; the saved key stays untouched.
        if !Vault.aiKeysRequireTouchID { key = try readSecret("typesafeKey") ?? ""; keyLoaded = true }
      } catch { store.error = error.localizedDescription }
    }
    .onChange(of: clientID) { _, _ in saved = false }
    .onChange(of: secret) { _, _ in saved = false }
    .onChange(of: key) { _, _ in saved = false }
    .alert("Remove this account’s local data?", isPresented: $confirmErasure) {
      Button("Cancel", role: .cancel) {}
      Button("Remove local data", role: .destructive) { store.eraseLocalMailbox() }
    } message: {
      Text("This permanently removes downloaded mail, unsent drafts, local contacts, local calendar events, preferences and Jev results from Cove on this Mac. Gmail and Google Calendar stay unchanged. Existing backups are not erased.")
    }
  }

  @ViewBuilder private var sectionContent: some View {
    switch selectedSection {
    case "Jev · Mail agent": jevSection
    case "Reading": ReadingSettingsView(showsHeading: false, store: store)
    case "Menu bar": menuBarSection
    case "Cloud sync": CloudSyncSettings(store: store, showsHeading: false)
    case "Privacy": privacySection
    case "App updates": AppUpdateSettings(showsHeading: false)
    default: gmailSection
    }
  }

  private var calendarDescription: String {
    if store.isSample { return "Sample events stay on this Mac." }
    if store.calendarConnected { return "Connected" }
    if store.auth.isConnected { return store.calendarConnectError ?? "Not connected" }
    return "Connect Gmail first"
  }
  private var gmailSection: some View {
    VStack(alignment: .leading, spacing: 28) {
      // Account
      SettingsCard {
        HStack(spacing: 14) {
          CoveAvatar(initials: String((store.entered ? store.accountEmail : "G").prefix(2)).uppercased(), size: 40)
          VStack(alignment: .leading, spacing: 3) {
            Text(store.entered ? (store.isSample ? "Sample mailbox" : store.accountEmail) : "Connect your Gmail account")
              .font(.coveSubheading)
            HStack(spacing: 6) {
              if store.auth.isConnected { Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6) }
              Text(store.auth.isConnected ? (store.syncing ? "Syncing…" : "Connected · \(syncDescription)")
                                          : store.isSample ? "Explore with sample mail, or connect Gmail" : "Not connected")
            }.font(.coveSecondary).foregroundStyle(Palette.body)
          }
          Spacer(minLength: 12)
          if store.auth.isConnected {
            Button("Sync now") { Task { await store.sync() } }
              .buttonStyle(SecondaryButton(compact: true)).disabled(store.syncing)
            Menu {
              Button("Reconnect Gmail") { connect() }
              Divider()
              Button(store.syncing ? "Disconnect (after sync)" : "Disconnect", role: .destructive) { store.disconnect() }
                .disabled(store.syncing)
            } label: { Image(systemName: "ellipsis").font(.cove(size: 13)).frame(width: 30, height: 30) }
              .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(store.busy)
              .accessibilityLabel("Manage account")
          } else {
            Button("Connect Gmail") { connect() }.buttonStyle(PrimaryButton(compact: true))
              .disabled(store.busy || !selectedGoogleConfiguration.isConfigured)
          }
        }
        if store.busy && store.status.contains("Connecting") {
          SettingsDivider()
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.status).font(.coveSecondary).foregroundStyle(Palette.body)
            Spacer()
            Button("Cancel sign-in") { store.auth.cancel() }.buttonStyle(SecondaryButton(compact: true))
          }
        }
      }

      // Sending
      SettingsGroup("Sending") {
        SettingsCard {
          SettingsRow("Default From address",
                      detail: store.sendingAliases.count > 1
                        ? "New emails come from this address. Replies come from the address the email was sent to."
                        : "Your Gmail has one sending address. Add more in Gmail → Settings → Accounts → Send mail as.") {
            if store.sendingAliases.count > 1 {
              CoveMenuPicker("Default From address", selection: Binding(get: { store.defaultSender }, set: { store.setDefaultSender($0) }),
                             options: store.sendingAliases.map { ($0, $0) })
            } else {
              Text(store.entered ? store.accountEmail : "—").font(.coveSecondary).foregroundStyle(Palette.body)
            }
          }
        }
      }

      // Sync
      SettingsGroup("Sync") {
        SettingsCard {
          SettingsRow("Sync mail in the background", detail: "Checks for new mail about every two minutes while Cove is open.") {
            Toggle("", isOn: $store.backgroundSyncEnabled).toggleStyle(CoveToggleStyle()).labelsHidden()
              .accessibilityLabel("Sync mail in the background")
          }
        }
      }

      // Google services
      SettingsGroup("Google services") {
        SettingsCard {
          SettingsRow("Google Calendar", icon: "calendar", detail: calendarDescription) {
            if store.calendarConnected || store.isSample { SettingsStatusPill(text: store.isSample ? "Sample" : "Connected") }
            else if store.auth.isConnected {
              Button("Connect") { Task { await store.connectCalendar() } }
                .buttonStyle(SecondaryButton(compact: true)).disabled(store.connectingStep != nil)
                .help("Adds Calendar to your Google sign-in. Your mail stays as it is.")
            }
          }
          SettingsDivider()
          SettingsRow("Google Tasks", icon: "checklist", detail: tasksDescription) {
            if store.tasksConnected { SettingsStatusPill(text: "Connected") }
            else if store.auth.isConnected && !store.isSample {
              Button("Connect") { Task { await store.connectTasks() } }
                .buttonStyle(SecondaryButton(compact: true)).disabled(store.connectingStep != nil)
            }
          }
        }
      }

      // Advanced: only for people bringing their own Google client.
      DisclosureGroup("Advanced · custom Google client", isExpanded: $showAdvancedGoogle) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Optional. Leave blank to use Cove’s built-in Google client. Disconnect before changing the client of an existing connection.")
            .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          TextField("Custom Google OAuth client ID", text: $clientID).textFieldStyle(CoveFieldStyle())
          SecureField("Custom desktop client secret", text: $secret).textFieldStyle(CoveFieldStyle())
          Button("Save credentials") { save() }.buttonStyle(SecondaryButton(compact: true)).disabled(store.busy)
        }.padding(.top, 14)
      }.font(.coveSecondary).foregroundStyle(Palette.body).disclosureGroupStyle(CoveDisclosureStyle())
    }
    .task { if store.entered && !store.isSample { await store.loadSendingAliasesIfNeeded() } }
  }
  /// Cove in the macOS menu bar. Meetings are the first thing it shows; more can join this section.
  private var menuBarSection: some View {
    VStack(alignment: .leading, spacing: 28) {
      SettingsCard {
        SettingsRow("Show Cove in the menu bar", icon: "menubar.rectangle",
                    detail: "A small icon at the top of your screen, so Cove is one click away even when its window is closed.") {
          Toggle("", isOn: $meetingsInMenuBar).toggleStyle(CoveToggleStyle()).labelsHidden()
            .accessibilityLabel("Show Cove in the menu bar")
        }
      }
      SettingsGroup("What it shows") {
        SettingsCard {
          SettingsRow("Your next meeting", icon: "video",
                      detail: store.calendarConnected || store.isSample
                        ? "“Standup in 8m” when a meeting is close, then “Join Standup”. A call with other people pulses as it starts, and Join is one click away (Google Meet, Zoom, Teams, Webex)."
                        : "Connect Google Calendar in Settings → Gmail to see your meetings here.") {
            if meetingsInMenuBar { SettingsStatusPill(text: "On") }
            else { Text("Off").font(.coveMetadata).foregroundStyle(Palette.muted) }
          }
        }
      }
    }
  }
  private var tasksDescription: String {
    if store.isSample { return "Connect Gmail to use Google Tasks." }
    if store.tasksConnected { return "Create tasks from emails and see them in Tasks." }
    if store.auth.isConnected { return store.tasksConnectError ?? "Turn emails into tasks you can check off." }
    return "Connect Gmail first"
  }

  private var jevSection: some View {
    VStack(alignment: .leading, spacing: 20) {
      if !Setup.jevKeySaved && !store.isSample {
        JevRequiredBanner(reason: "Jev organizes new mail, runs your agents and finds tasks. It needs a TypeSafe key.")
      }
      Toggle(isOn: Binding(get: { store.preferences.autoClassify }, set: { store.setAutoOrganization($0) })) {
        copy("Organize new mail with Jev", "")
      }.toggleStyle(CoveToggleStyle()).disabled(!store.entered || store.isSample || store.busy || !Setup.jevKeySaved)
        .accessibilityLabel("Organize new mail with Jev")
        .help("Categorize new emails, score urgency, and select a key passage")
      DisclosureGroup(key.isEmpty ? "TypeSafe connection · Add a key" : "TypeSafe connection · Manage key") {
        VStack(alignment: .leading, spacing: 14) {
          SecureField("TypeSafe API key", text: $key).textFieldStyle(CoveFieldStyle())
          Text("Running Jev sends email content and enabled preferences to TypeSafe. TypeSafe states it does not train on inputs; zero data retention is not established.")
            .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Save credentials") { save() }.buttonStyle(SecondaryButton()).disabled(store.busy)
            if saved { Label("Credentials saved", systemImage: "checkmark").font(.coveSecondary) }
            Spacer()
            Link("Get a key ↗", destination: URL(string: "https://console.typesafe.ai")!)
          }
          Link("TypeSafe privacy ↗", destination: URL(string: "https://typesafe.ai/legal/privacy-policy")!)
        }.padding(.top, 16)
      }.font(.coveLabel).disclosureGroupStyle(CoveDisclosureStyle())
      Divider()
      HStack(spacing: 16) {
        copy("Writing voice", "").help("The tone of your reply templates")
        Spacer()
        CoveMenuPicker("Writing voice", selection: Binding(get: { store.preferences.voice }, set: {
          store.preferences.voice = $0; store.persistPreferences()
        }), options: [("Professional", "Professional"), ("Warm", "Warm"), ("Direct", "Direct")])
          .disabled(!store.entered)
      }
      VoiceProfileSettings(store: store)
      VStack(alignment: .leading, spacing: 10) {
        Text("Instructions for Jev").font(.coveLabel)
        TextField("One instruction per line", text: Binding(
          get: { store.preferences.instructions.joined(separator: "\n") },
          set: { store.preferences.instructions = $0.components(separatedBy: "\n"); store.persistPreferences() }
        ), axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).font(.coveBody).disabled(!store.entered)
          .accessibilityLabel("Instructions for Jev")
      }.padding(14).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
      Button { store.screen = "integrations" } label: {
        Label("Set up AI writing & chat in Integrations", systemImage: "arrow.up.right")
      }.buttonStyle(SecondaryButton()).disabled(!store.entered || store.busy)
    }
  }

  private var privacySection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Keys stay in macOS Keychain. Mail is encrypted on this Mac.", systemImage: "lock.shield")
        .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      AIKeyProtectionSettings()
      if store.entered {
        Button("Remove local data and disconnect…", role: .destructive) { confirmErasure = true }
          .help("Disconnect alone keeps the encrypted local cache")
          .buttonStyle(SecondaryButton()).disabled(store.busy)
      }
    }
  }

  private var syncDescription: String {
    store.lastSync.map { "Last synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Ready to sync"
  }
  private func copy(_ title: String, _ help: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.coveLabel)
      if !help.isEmpty {
        Text(help).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 580, alignment: .leading)
      }
    }
  }
  private func connect() {
    // Reconnecting keeps Calendar if it was connected; Calendar is otherwise added separately.
    if save() { Task { await store.connect(includeCalendar: store.calendarConnected) } }
  }
  private var selectedGoogleConfiguration: GoogleOAuthConfiguration {
    GoogleOAuthConfiguration.selected(
      customClientID: clientID, customSecret: secret,
      bundled: BundledGoogleOAuth.configuration)
  }
  @discardableResult func save() -> Bool {
    do {
      let clean = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
      if store.auth.isConnected && selectedGoogleConfiguration.clientID != store.auth.clientID {
        throw CoveError.message("Disconnect Gmail before changing its OAuth client ID.")
      }
      try Vault.save(
        secret.trimmingCharacters(in: .whitespacesAndNewlines), name: "googleClientSecret")
      let typesafe = key.trimmingCharacters(in: .whitespacesAndNewlines)
      if keyLoaded || !typesafe.isEmpty {
        try Vault.save(typesafe, name: "typesafeKey")
        Setup.recordJevKey(saved: !typesafe.isEmpty)
        // Never report success unless the key can actually be read back from the Keychain.
        if !typesafe.isEmpty, !Vault.aiKeysRequireTouchID, try readSecret("typesafeKey") != typesafe {
          throw CoveError.message("Your TypeSafe key couldn’t be saved to the Keychain. Try again, or quit and reopen Cove.")
        }
        keyLoaded = true
      }
      UserDefaults.standard.set(clean, forKey: "googleClientID")
      saved = true
      return true
    } catch {
      store.error = error.localizedDescription
      return false
    }
  }
}

/// Learns the user's voice from their sent mail; the result is kept in encrypted local preferences.
private struct VoiceProfileSettings: View {
  @Bindable var store: AppStore
  @State private var learning = false
  @State private var failure: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Your voice").font(.coveLabel)
          Text(store.preferences.voiceProfile == nil
            ? "Make AI drafts sound like you."
            : "Learned from \(store.preferences.voiceProfile!.sampleCount) sent emails on \(store.preferences.voiceProfile!.learnedAt.formatted(date: .abbreviated, time: .omitted)).")
            .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if learning { ProgressView().controlSize(.small) }
        Button(store.preferences.voiceProfile == nil ? "Learn from my sent mail" : "Learn again") {
          learning = true; failure = nil
          Task {
            do { try await store.learnVoice() } catch is CancellationError {} catch { failure = error.localizedDescription }
            learning = false
          }
        }.buttonStyle(SecondaryButton()).fixedSize().disabled(learning || !store.entered || store.isSample)
      }
      if let profile = store.preferences.voiceProfile {
        VStack(alignment: .leading, spacing: 8) {
          Text(profile.summary).font(.coveBody).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          if !profile.traits.isEmpty {
            Text(profile.traits.joined(separator: " · ")).font(.coveSecondary).foregroundStyle(Palette.body)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !(profile.greetings + profile.signoffs).isEmpty {
            Text("Greetings: \(profile.greetings.joined(separator: ", "))  ·  Sign-offs: \(profile.signoffs.joined(separator: ", "))")
              .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          }
          HStack {
            Text("Model: \(profile.model)").font(.coveMetadata).foregroundStyle(Palette.body)
            Spacer()
            Button("Forget my voice") { store.forgetVoice() }.buttonStyle(.plain).font(.coveControl)
              .foregroundStyle(Palette.body)
          }
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      if let failure {
        Text(failure).font(.coveSecondary).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup("What’s sent and saved") {
        Text("Learning sends short, quote-free excerpts of up to 25 recent sent emails to your connected writing model. Only the style description is saved: encrypted with this mailbox and in Cove’s Keychain entry on this Mac, so every Gmail account you connect here uses it and it stays after you sign out and back in.")
          .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
      }.font(.coveSecondary)
    }
  }
}

/// AI provider and TypeSafe keys: data-protection keychain on hardened builds, optional Touch ID.
private struct AIKeyProtectionSettings: View {
  @State private var hardened = false
  @State private var touchID = false
  @State private var working = false
  @State private var failure: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: Binding(get: { touchID }, set: { enabled in
        working = true; failure = nil
        // Re-saving may show Touch ID; run it after this layout pass.
        Task {
          do { try Vault.setAIKeysRequireTouchID(enabled); touchID = enabled }
          catch { failure = error.localizedDescription }
          working = false
        }
      })) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Require Touch ID for AI keys").font(.coveLabel)
          Text(hardened
            ? "Asks at most every 5 minutes and pauses automatic agent checks."
            : "Available in the signed Cove build.")
            .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 580, alignment: .leading)
            .help(hardened
              ? "AI and TypeSafe keys are stored only on this Mac and readable only while it’s unlocked."
              : "AI and TypeSafe keys are in your login Keychain, encrypted and readable only by Cove.")
        }
      }.toggleStyle(CoveToggleStyle()).disabled(!hardened || working)
      if let failure {
        Text(failure).font(.coveSecondary).foregroundStyle(Palette.danger)
      }
    }.task {
      hardened = Vault.aiKeysHardened
      touchID = Vault.aiKeysRequireTouchID
    }
  }
}

/// Settings building blocks: a quiet group title, a bordered card, and rows that read left to right.
struct SettingsGroup<Content: View>: View {
  let title: String
  let content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.coveLabel).foregroundStyle(Palette.body)
      content
    }
  }
}
struct SettingsCard<Content: View>: View {
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(.horizontal, 18).padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
  }
}
struct SettingsDivider: View {
  var body: some View { Divider().padding(.vertical, 14) }
}
struct SettingsRow<Accessory: View>: View {
  let title: String
  var icon: String? = nil
  let detail: String
  let accessory: Accessory
  init(_ title: String, icon: String? = nil, detail: String, @ViewBuilder accessory: () -> Accessory) {
    self.title = title; self.icon = icon; self.detail = detail; self.accessory = accessory()
  }
  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      if let icon {
        Image(systemName: icon).font(.cove(size: 14)).foregroundStyle(Palette.body)
          .frame(width: 32, height: 32).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.coveLabel)
        if !detail.isEmpty {
          Text(detail).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      accessory
    }
  }
}
struct SettingsStatusPill: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "checkmark").font(.coveMetadata).foregroundStyle(Palette.body)
      .padding(.horizontal, 10).frame(height: 24).background(Palette.surface, in: Capsule())
  }
}
