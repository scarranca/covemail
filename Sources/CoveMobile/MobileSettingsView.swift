#if os(iOS)
import CoveCore
import SwiftUI

struct MobileSettingsView: View {
  let auth: MobileAuth
  @Bindable var mailbox: MobileMailbox
  let ai: MobileAI
  @State private var confirmSignOut = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Account") {
          LabeledContent("Gmail", value: auth.email ?? "")
          Button("Sign out", role: .destructive) { confirmSignOut = true }
        }
        Section {
          NavigationLink {
            MobileAIModelsView(ai: ai)
          } label: {
            LabeledContent("AI models") {
              Text(ai.ready ? ai.modelLabel(ai.model(ai.provider), provider: ai.provider) : "Not set up")
                .foregroundStyle(MobilePalette.muted)
            }
          }
        } header: { Text("Writing and Ask Cove") } footer: {
          Text("Apple Intelligence runs on this iPhone with no account. API keys are billed separately by their provider.")
        }
        Section {
          Toggle("Split inbox", isOn: $mailbox.splitInbox)
        } header: { Text("Reading") } footer: {
          Text("Important and Other tabs, decided on this iPhone from the same rules as Cove on the Mac.")
        }
        Section {
          LabeledContent("Version", value: Self.version)
        } footer: {
          Text("Mail is stored encrypted on this iPhone. Signing out keeps that copy; your sign-in is removed.")
        }
        if let error {
          Section { Text(error).foregroundStyle(MobilePalette.danger) }
        }
      }
      .font(.mobileBody)
      .navigationTitle("Settings")
      .confirmationDialog("Sign out of \(auth.email ?? "Gmail")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
        Button("Sign out", role: .destructive) {
          do {
            mailbox.close()
            try auth.signOut()
          } catch { self.error = error.localizedDescription }
        }
      }
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
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(MobileAI.providers) { provider in card(provider) }
        Text("Your instructions, draft and the relevant emails go to the provider you choose. Apple Intelligence keeps them on this iPhone and reads fewer emails at once.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).padding(.horizontal, 4)
        Text("ChatGPT and Claude subscriptions connect through Cove on the Mac.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).padding(.horizontal, 4)
      }.padding(16)
    }
    .background(MobilePalette.canvas)
    .navigationTitle("AI models")
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
            .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 12))
          Button("Save") { saveKey(provider) }.buttonStyle(MobileSecondaryButton())
            .disabled((keys[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      if ai.isConnected(provider) {
        let options = models[provider] ?? []
        if !options.isEmpty && !provider.isAppleIntelligence {
          Picker("Model", selection: Binding(get: { selection[provider] ?? "" }, set: { selection[provider] = $0 })) {
            Text("Choose a model").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.menu)
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
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 24))
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
      } catch { errors[provider] = error.localizedDescription }
    }
  }
}
#endif
