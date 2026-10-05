#if os(iOS)
import CoveCore
import SwiftUI

struct MobileSettingsView: View {
  let auth: MobileAuth
  @Bindable var mailbox: MobileMailbox
  let workspace: MobileWorkspace
  let ai: MobileAI
  @State private var confirmSignOut = false
  @State private var connecting = false
  @State private var error: String?
  @State private var voice = MobileVoice.load()
  @State private var me = MobileMe.shared
  @State private var showAbout = false
  @State private var learning = false
  @State private var voiceError: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          group("Account") {
            HStack(spacing: 12) {
              MobileAvatar(name: auth.email ?? "", size: 40)
              VStack(alignment: .leading, spacing: 2) {
                Text(auth.email ?? "").font(.mobileLabel)
                Text(auth.isSample ? "Sample mailbox · nothing reaches Google" : "Google account · private beta")
                  .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
              }
            }
            Button("Sign out", role: .destructive) { confirmSignOut = true }
              .buttonStyle(MobileSecondaryButton(compact: true, destructive: true))
          }
          group("Connections") {
            connection("Gmail", icon: "envelope", status: "Connected", connected: true)
            Divider().overlay(MobilePalette.line)
            connection("Google Calendar", icon: "calendar", status: auth.calendarConnected ? "Connected" : "Not connected",
                       connected: auth.calendarConnected)
            Divider().overlay(MobilePalette.line)
            connection("Google Tasks", icon: "checklist", status: auth.tasksConnected ? "Connected" : "Not connected",
                       connected: auth.tasksConnected)
            if !(auth.calendarConnected && auth.tasksConnected) && !auth.isSample {
              Button(connecting ? "Connecting…" : "Connect Calendar & Tasks") {
                connecting = true
                error = nil
                Task {
                  do { try await auth.signIn(hint: auth.email) } catch { self.error = error.localizedDescription }
                  connecting = false
                }
              }.buttonStyle(MobilePrimaryButton(compact: true)).disabled(connecting)
            }
            Divider().overlay(MobilePalette.line)
            NavigationLink { MobileAIModelsView(ai: ai) } label: {
              HStack(spacing: 12) {
                Image(systemName: "sparkles").frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Writing and Ask Cove").font(.mobileLabel)
                  Text(ai.ready ? ai.modelLabel(ai.model(ai.provider), provider: ai.provider) : "Not set up")
                    .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MobilePalette.muted)
              }.foregroundStyle(MobilePalette.ink).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
          group("About you") {
            NavigationLink { MobileAboutYouView(mailbox: mailbox, ai: ai) } label: {
              HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle").frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                  Text(me.context.isEmpty ? "Tell Cove who you are" : [me.context.name, me.context.role, me.context.company]
                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.mobileLabel).lineLimit(1)
                  Text(me.context.isEmpty ? "Your role, what you’re working on, notes and sign-off"
                       : "\(me.context.projects.count) projects · \(me.context.notes.count) notes\(me.context.enabled ? "" : " · off")")
                    .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MobilePalette.muted)
              }.foregroundStyle(MobilePalette.ink).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
          group("Notifications") { MobileNotificationSettings(auth: auth) }
          group("Your voice") {
            if let voice {
              Text(voice.summary).font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
              Text("Learned from \(voice.sampleCount) emails you sent · \(voice.learnedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            } else {
              Text("Cove reads short excerpts of emails you wrote in Sent (never replies you quoted) and learns your greetings, sign-offs and tone. Drafts then sound like you.")
                .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
              Button(learning ? "Learning…" : voice == nil ? "Learn my voice" : "Relearn") {
                learning = true
                voiceError = nil
                Task {
                  do { voice = try await MobileVoice.learn(mailbox: mailbox, ai: ai) } catch { voiceError = error.localizedDescription }
                  learning = false
                }
              }.buttonStyle(MobilePrimaryButton(compact: true)).disabled(learning || !ai.ready)
              if voice != nil {
                Button("Forget") { try? MobileVoice.forget(); voice = nil }
                  .buttonStyle(MobileSecondaryButton(compact: true, destructive: true)).disabled(learning)
              }
            }
            if !ai.ready { Text("Set up Writing and Ask Cove first.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted) }
            if let voiceError { Text(voiceError).font(.mobileMetadata).foregroundStyle(MobilePalette.danger) }
            Text("Kept in this iPhone’s Keychain. Your Mac’s voice syncs through Cove’s cloud, which iPhone can’t read yet.")
              .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
          }
          group("Reading") {
            Toggle("Split inbox", isOn: $mailbox.splitInbox).toggleStyle(MobileToggleStyle())
            Text("Important and Other tabs, decided on this iPhone from the same rules as Cove on the Mac.")
              .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
          }
          group("Privacy") {
            Text("Mail is stored encrypted on this iPhone. Signing out keeps that copy and removes your sign-in. Apple Intelligence keeps your text on this iPhone; API keys send it to the provider you choose.")
              .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
          }
          if let error { Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger) }
          HStack {
            MobileWordmark(size: 16)
            Spacer()
            Text("Cove for iPhone · " + Self.version).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
        }
        .foregroundStyle(MobilePalette.ink)
        .padding(20)
      }
      .background(MobilePalette.surface)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $showAbout) { MobileAboutYouView(mailbox: mailbox, ai: ai) }
      #if DEBUG
      .onAppear { if ProcessInfo.processInfo.arguments.contains("-CoveAboutYou") { showAbout = true } }
      #endif
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .confirmationDialog("Sign out of \(auth.email ?? "Gmail")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
        Button("Sign out", role: .destructive) {
          Task {
            // A Send or Trash still in its Undo window goes to Gmail before the sign-in is removed.
            await mailbox.finishPending()
            do {
              mailbox.close()
              workspace.reset()
              try auth.signOut()
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }
      } message: {
        Text("The encrypted mail on this iPhone stays until you delete the app.")
      }
    }
  }

  private func group<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.mobileSection).accessibilityAddTraits(.isHeader)
      MobileCard { content() }
    }
  }

  private func connection(_ title: String, icon: String, status: String, connected: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).frame(width: 22)
      Text(title).font(.mobileLabel)
      Spacer()
      Label(status, systemImage: connected ? "checkmark.circle.fill" : "circle")
        .font(.mobileMetadata).foregroundStyle(connected ? MobilePalette.ink : MobilePalette.muted)
    }
  }

  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let short = info["CFBundleShortVersionString"] as? String ?? "–"
    let build = info["CFBundleVersion"] as? String ?? "–"
    return "\(short) (\(build))"
  }
}

/// Providers as cards: Apple Intelligence first, then API keys. A model becomes the default only after a
/// short test succeeds (as on the Mac).
struct MobileAIModelsView: View {
  let ai: MobileAI
  @State private var keys: [AIProvider: String] = [:]
  @State private var models: [AIProvider: [String]] = [:]
  @State private var selection: [AIProvider: String] = [:]
  @State private var busy: AIProvider?
  @State private var notice: [AIProvider: String] = [:]
  @State private var errors: [AIProvider: String] = [:]

  var body: some View {
    ZStack {
    // The gray fills the whole screen, not only the scrolled content.
    MobilePalette.surface.ignoresSafeArea()
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(MobileAI.providers) { provider in card(provider) }
        Text("Your instructions, draft and the relevant emails go to the provider you choose. Apple Intelligence keeps them on this iPhone and reads fewer emails at once.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).padding(.horizontal, 4)
        Text("ChatGPT and Claude subscriptions connect through Cove on the Mac.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).padding(.horizontal, 4)
      }.padding(16)
    }
    }
    .foregroundStyle(MobilePalette.ink)
    .navigationTitle("Writing and Ask Cove")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      ai.refreshStatus()
      for provider in MobileAI.providers where !ai.model(provider).isEmpty {
        selection[provider] = ai.model(provider)
      }
    }
  }

  private func card(_ provider: AIProvider) -> some View {
    let isDefault = ai.provider == provider && ai.ready
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(provider.isAppleIntelligence ? "Apple Intelligence" : provider.title).font(.mobileSection)
          Text(subtitle(provider)).font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        if isDefault {
          Label("Default", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
            .font(.mobileMetadata).foregroundStyle(MobilePalette.badgeText)
        }
      }
      if provider.usesAPIKey {
        HStack(spacing: 10) {
          SecureField(ai.hasKey(provider) ? "Replace saved key" : "Paste API key", text: binding(provider))
            .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MobilePalette.inputBorder))
          Button("Save") { saveKey(provider) }.buttonStyle(MobileSecondaryButton())
            .disabled((keys[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      if ai.isConnected(provider) {
        let options = models[provider] ?? []
        if !options.isEmpty && !provider.isAppleIntelligence {
          MobileModelField(provider: provider, models: options,
                           selection: Binding(get: { selection[provider] ?? "" }, set: { selection[provider] = $0; errors[provider] = nil }))
        }
        HStack(spacing: 10) {
          Button(busy == provider ? "Testing…" : isDefault ? "Test again" : "Test & use") { testAndUse(provider) }
            .buttonStyle(MobilePrimaryButton())
            .disabled(busy != nil || (!provider.isAppleIntelligence && (selection[provider] ?? "").isEmpty))
          if !provider.isAppleIntelligence {
            Button { loadModels(provider) } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(MobileSecondaryButton()).disabled(busy != nil).accessibilityLabel("Refresh models")
            Spacer()
            Button("Remove", role: .destructive) { removeKey(provider) }
              .buttonStyle(MobileSecondaryButton(destructive: true)).disabled(busy != nil)
          }
        }
      }
      if let message = errors[provider] {
        Text(message).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
      } else if let message = notice[provider] {
        Text(message).font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
    .task(id: ai.hasKey(provider)) {
      if provider.usesAPIKey, ai.hasKey(provider), models[provider] == nil { loadModels(provider) }
    }
  }

  private func subtitle(_ provider: AIProvider) -> String {
    if provider.isAppleIntelligence { return ai.apple.message }
    return ai.hasKey(provider) ? "Key saved. Billed separately by the provider." : "Use your own API key."
  }

  private func binding(_ provider: AIProvider) -> Binding<String> {
    Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 })
  }

  private func saveKey(_ provider: AIProvider) {
    errors[provider] = nil
    do {
      try ai.saveKey(keys[provider] ?? "", provider: provider)
      keys[provider] = ""
      loadModels(provider)
    } catch { errors[provider] = error.localizedDescription }
  }

  private func removeKey(_ provider: AIProvider) {
    do {
      try ai.removeKey(provider)
      models[provider] = nil
      selection[provider] = nil
      notice[provider] = "Key removed."
    } catch { errors[provider] = error.localizedDescription }
  }

  private func loadModels(_ provider: AIProvider) {
    guard busy == nil else { return }
    busy = provider
    errors[provider] = nil
    Task {
      defer { busy = nil }
      do {
        let list = try await ai.models(provider)
        models[provider] = list
        if (selection[provider] ?? "").isEmpty, list.count == 1 { selection[provider] = list[0] }
        notice[provider] = list.isEmpty ? "No models returned for this key." : nil
      } catch { errors[provider] = error.localizedDescription }
    }
  }

  private func testAndUse(_ provider: AIProvider) {
    guard busy == nil else { return }
    let model = provider.isAppleIntelligence ? AppleIntelligence.modelID : selection[provider] ?? ""
    busy = provider
    errors[provider] = nil
    notice[provider] = nil
    Task {
      defer { busy = nil }
      do {
        try await ai.testAndUse(model, provider: provider)
        notice[provider] = "Ready. \(ai.modelLabel(model, provider: provider)) is now your default for writing and Ask Cove."
      } catch let failure as HTTPFailure where failure.statusCode == 403 || failure.statusCode == 404 {
        // The catalog lists models a key may not be allowed to use. Say which one, and what to do.
        errors[provider] = "\(provider.title) didn’t allow \(model) for this key (\(failure.statusCode)). Some listed models need extra access or credits. Choose another model; your previous default is unchanged."
      } catch { errors[provider] = error.localizedDescription + " Your previous default is unchanged." }
    }
  }
}
#endif

#if os(iOS)
/// The chosen model as a Cove field; tapping opens a searchable list. Provider catalogs (OpenRouter
/// lists hundreds) are too long for a menu, and IDs are shown as name with the vendor beneath.
struct MobileModelField: View {
  let provider: AIProvider
  let models: [String]
  @Binding var selection: String
  @State private var choosing = false

  var body: some View {
    Button { choosing = true } label: {
      HStack(spacing: 10) {
        if selection.isEmpty {
          Text("Choose a model").font(.mobileText).foregroundStyle(MobilePalette.muted)
        } else {
          VStack(alignment: .leading, spacing: 1) {
            Text(MobileModelName.name(selection)).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
            if let vendor = MobileModelName.vendor(selection) {
              Text(vendor).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
            }
          }
        }
        Spacer(minLength: 8)
        Text("\(models.count)").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .medium)).foregroundStyle(MobilePalette.body)
      }
      .padding(.horizontal, 12).frame(minHeight: 50)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(MobilePalette.inputBorder))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Model").accessibilityValue(selection.isEmpty ? "None chosen" : selection)
    .sheet(isPresented: $choosing) {
      MobileModelList(title: provider.title, models: models, selection: $selection)
    }
  }
}

enum MobileModelName {
  /// "anthropic/claude-sonnet-4.5" → "claude-sonnet-4.5"; IDs without a vendor are unchanged.
  static func name(_ id: String) -> String { id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id }
  static func vendor(_ id: String) -> String? {
    let parts = id.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[0]) : nil
  }
}

struct MobileModelList: View {
  let title: String
  let models: [String]
  @Binding var selection: String
  @State private var query = ""
  @Environment(\.dismiss) private var dismiss

  private var groups: [(String, [String])] {
    let terms = MailSearchIndex.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    let matching = models.filter { model in
      let folded = MailSearchIndex.fold(model)
      return terms.allSatisfy { folded.contains($0) }
    }
    let grouped = Dictionary(grouping: matching) { MobileModelName.vendor($0) ?? "Models" }
    return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted()) }
  }

  var body: some View {
    NavigationStack {
      List {
        if !selection.isEmpty && query.isEmpty {
          Section("Selected") { row(selection) }
        }
        ForEach(groups, id: \.0) { vendor, ids in
          Section(vendor) { ForEach(ids, id: \.self) { row($0) } }
        }
        if groups.isEmpty {
          Text("No model matches “\(query)”.").font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(MobilePalette.surface)
      .font(.mobileText)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(models.count) models")
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }

  private func row(_ id: String) -> some View {
    Button {
      selection = id
      dismiss()
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(MobileModelName.name(id)).font(.mobileLabel).foregroundStyle(MobilePalette.ink)
          Text(id).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        if id == selection { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(MobilePalette.ink) }
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(MobilePalette.canvas)
    .accessibilityAddTraits(id == selection ? .isSelected : [])
  }
}
#endif

#if os(iOS)
/// New-mail notifications: on/off, which mail, what the notification shows, and how it works.
struct MobileNotificationSettings: View {
  let auth: MobileAuth
  @State private var push = MobilePush.shared
  @State private var scope = PushSettings.shared.scope
  @State private var preview = PushSettings.shared.showPreview
  @State private var signingIn = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("New mail", isOn: Binding(get: { push.enabled }, set: { on in
        Task { if on { await push.turnOn() } else { await push.turnOff() } }
      })).toggleStyle(MobileToggleStyle()).disabled(push.working)
      if push.enabled {
        Text("Notify me about").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        MobileSegmented(selection: Binding(get: { scope }, set: { scope = $0; push.scope = $0 }),
                        options: [(.important, "Important"), (.inbox, "All Inbox")])
        Toggle("Show sender and subject", isOn: Binding(get: { preview }, set: { preview = $0; push.showPreview = $0 }))
          .toggleStyle(MobileToggleStyle())
      }
      if push.working { HStack(spacing: 8) { ProgressView(); Text(push.status ?? "Working…") }.font(.mobileSecondary).foregroundStyle(MobilePalette.body) }
      else if let status = push.status { Text(status).font(.mobileSecondary).foregroundStyle(MobilePalette.body) }
      if !push.working, let watch = push.watchSummary {
        Text(watch).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
      if let error = push.error {
        Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
        if push.needsSignIn {
          Button(signingIn ? "Signing in…" : "Sign in again") {
            signingIn = true
            Task {
              do { try await auth.signIn(hint: auth.email); await push.turnOn() } catch { push.error = error.localizedDescription }
              signingIn = false
            }
          }.buttonStyle(MobilePrimaryButton(compact: true)).disabled(signingIn)
        }
      }
      if push.authorization == .denied {
        Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
          .buttonStyle(MobileSecondaryButton(compact: true))
      }
      Text("Gmail tells Cove’s server only that new mail arrived. This \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") reads the email itself and shows the sender and subject — never the text. Mute or always allow a sender from an email’s More menu.")
        .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
    }
    .task { await push.refreshAuthorization() }
  }
}
#endif
