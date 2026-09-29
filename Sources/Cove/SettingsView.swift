import CoveCore
import SwiftUI

/// Settings is a main-window destination, including before Gmail sign-in.
struct SettingsView: View {
  @Bindable var store: AppStore
  @State private var clientID = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
  @State private var secret = ""
  @State private var key = ""
  @State private var showAdvancedGoogle = false
  @State private var saved = false
  @State private var confirmErasure = false
  var readSecret: (String) throws -> String? = { try Vault.read($0) }

  var selectedSection: String {
    switch store.settingsSection {
    case "Jev · Mail agent", "Reading", "Privacy", "App updates": return store.settingsSection
    case "Cloud sync" where store.cloudConfigured: return "Cloud sync"
    default: return "Gmail"
    }
  }

  private var sectionDescription: String {
    switch selectedSection {
    case "Jev · Mail agent": return "Organization, writing voice, and instructions."
    case "Reading": return "Choose how emails look when you open them."
    case "Cloud sync": return "Manage your optional cloud copy."
    case "Privacy": return "Manage the data stored on this Mac."
    case "App updates": return "Keep Cove up to date."
    default: return "Manage your inbox and Google connection."
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebar(store: store, section: selectedSection) { destination in
        store.settingsSection = destination
      }.frame(width: 224)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          Text(selectedSection == "Privacy" ? "Privacy & local data" : selectedSection)
            .font(.coveTitle)
          Text(sectionDescription).font(.coveSecondary).foregroundStyle(Palette.body)
        }.padding(.horizontal, 32).padding(.vertical, 24)
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
        key = try readSecret("typesafeKey") ?? ""
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
    case "Reading": ReadingSettingsView(showsHeading: false)
    case "Cloud sync": CloudSyncSettings(store: store, showsHeading: false)
    case "Privacy": privacySection
    case "App updates": AppUpdateSettings(showsHeading: false)
    default: gmailSection
    }
  }

  private var calendarDescription: String {
    if store.isSample { return "Sample events stay on this Mac." }
    if store.calendarConnected { return "Connected · uses your Google sign-in for your primary calendar." }
    if store.auth.isConnected {
      return store.calendarConnectError ?? "Adds Calendar to your Google sign-in. Your mail stays as it is."
    }
    return "Available after you connect Gmail."
  }
  private var gmailSection: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 16) {
        copy(store.entered ? (store.isSample ? "Sample mailbox" : store.accountEmail) : "Connect your Gmail account",
             store.auth.isConnected ? "Connected · \(syncDescription)" : "Secure sign-in with Google. No separate Cove password.")
        Spacer(minLength: 0)
        if store.auth.isConnected {
          Menu("Manage account") {
            Button("Sync now") { Task { await store.sync() } }
            Button("Reconnect Gmail") { connect() }
            Button("Disconnect") { store.disconnect() }
          }.menuStyle(.borderlessButton).font(.coveControl).fixedSize().disabled(store.busy)
        } else {
          Button("Connect Gmail") { connect() }.buttonStyle(PrimaryButton())
            .disabled(store.busy || !selectedGoogleConfiguration.isConfigured)
        }
      }
      Toggle(isOn: $store.backgroundSyncEnabled) {
        copy("Sync mail in the background", "Check for new mail about every two minutes while Cove is open.")
      }.toggleStyle(CoveToggleStyle()).accessibilityLabel("Sync mail in the background")
      HStack(spacing: 16) {
        copy("Google Calendar", calendarDescription)
        Spacer(minLength: 0)
        if store.auth.isConnected && !store.isSample && !store.calendarConnected {
          Button("Connect Calendar") { Task { await store.connectCalendar() } }
            .buttonStyle(SecondaryButton()).disabled(store.busy)
        }
      }

      DisclosureGroup("Google connection settings", isExpanded: $showAdvancedGoogle) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Optional: use your own Desktop OAuth client. Leave the client ID blank to use Cove’s included configuration. Disconnect before changing the client for an existing connection.")
            .font(.coveSecondary).foregroundStyle(Palette.body)
          TextField("Custom Google OAuth client ID", text: $clientID).textFieldStyle(CoveFieldStyle())
          SecureField("Custom desktop client secret", text: $secret).textFieldStyle(CoveFieldStyle())
          HStack {
            Button("Save credentials") { save() }.buttonStyle(SecondaryButton()).disabled(store.busy)
            Button(store.auth.isConnected ? "Reconnect Gmail" : "Connect Gmail") { connect() }
              .buttonStyle(PrimaryButton()).disabled(store.busy || !selectedGoogleConfiguration.isConfigured)
          }
        }.padding(.top, 16)
      }.font(.coveLabel).disclosureGroupStyle(CoveDisclosureStyle())
      if store.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text(store.status).font(.coveSecondary)
          if store.status.contains("Connecting") { Button("Cancel sign-in") { store.auth.cancel() }.buttonStyle(SecondaryButton(compact: true)) }
        }
      }
    }
  }

  private var jevSection: some View {
    VStack(alignment: .leading, spacing: 20) {
      Toggle(isOn: Binding(get: { store.preferences.autoClassify }, set: { store.setAutoOrganization($0) })) {
        copy("Organize new mail with Jev", "Categorize new emails, score urgency, and select a key passage.")
      }.toggleStyle(CoveToggleStyle()).disabled(!store.entered || store.isSample || store.busy)
        .accessibilityLabel("Organize new mail with Jev")
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
        copy("Writing voice", "The tone of your reply templates.")
        Spacer()
        CoveMenuPicker("Writing voice", selection: Binding(get: { store.preferences.voice }, set: {
          store.preferences.voice = $0; store.persistPreferences()
        }), options: [("Professional", "Professional"), ("Warm", "Warm"), ("Direct", "Direct")])
          .disabled(!store.entered)
      }
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
      Label("Credentials and mailbox keys stay in macOS Keychain. Real-account mail is encrypted on this Mac. Disconnect keeps the local cache.", systemImage: "lock.shield")
        .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      if store.entered {
        Button("Remove local data and disconnect…", role: .destructive) { confirmErasure = true }
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
      Text(help).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 580, alignment: .leading)
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
      try Vault.save(key.trimmingCharacters(in: .whitespacesAndNewlines), name: "typesafeKey")
      UserDefaults.standard.set(clean, forKey: "googleClientID")
      saved = true
      return true
    } catch {
      store.error = error.localizedDescription
      return false
    }
  }
}
