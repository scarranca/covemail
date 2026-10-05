#if os(iOS)
import CoveCore
import Observation
import SwiftUI

/// "About you" on this device: kept in the Keychain (encrypted, this device only) and added to every
/// draft and Ask Cove answer as the user's own words (`PersonalContext.promptText`).
@MainActor @Observable final class MobileMe {
  static let shared = MobileMe()
  private static let key = "personalContext"
  private(set) var context: PersonalContext

  private init() {
    if let text = try? MobileKeychain.read(Self.key), let saved = try? Self.decoder.decode(PersonalContext.self, from: Data(text.utf8)) {
      context = saved
    } else {
      context = PersonalContext()
    }
  }

  var prompt: String? { context.promptText }

  func save(_ updated: PersonalContext) throws {
    var value = updated
    value.updatedAt = Date()
    try store(value)
    Task { await sync() }
  }

  private func store(_ value: PersonalContext) throws {
    try MobileKeychain.save(String(decoding: try Self.encoder.encode(value), as: UTF8.self), name: Self.key)
    context = value
  }

  // MARK: Sync with the Mac and iPad (opt-in, `/v1/personal`)

  private static let syncKey = "personalSync"
  @ObservationIgnored weak var auth: MobileAuth?
  private(set) var syncState: PersonalSyncState = {
    guard let data = UserDefaults.standard.data(forKey: MobileMe.syncKey),
          let state = try? MobileMe.decoder.decode(PersonalSyncState.self, from: data) else { return PersonalSyncState() }
    return state
  }()
  private(set) var syncing = false
  private(set) var syncStatus: String?

  /// Sync is on for the signed-in account.
  var syncEnabled: Bool { syncState.enabled && syncState.account == auth?.email && auth?.email != nil }

  private func saveSyncState(_ state: PersonalSyncState) {
    syncState = state
    if let data = try? Self.encoder.encode(state) { UserDefaults.standard.set(data, forKey: Self.syncKey) }
  }

  func setSync(_ enabled: Bool) async {
    var state = PersonalSyncState()
    state.enabled = enabled
    state.account = enabled ? auth?.email : nil
    saveSyncState(state)
    syncStatus = enabled ? nil : "Sync is off. Your other devices keep their copy."
    if enabled { await sync() }
  }

  /// Reads the server copy, then sends this device's edit or takes the newer one.
  func sync() async {
    guard syncEnabled, !syncing, let auth, !auth.isSample else { return }
    syncing = true
    defer { syncing = false }
    do {
      guard let identity = try await auth.identityToken() else { return }
      let client = try CloudMailClient(baseURL: MobilePush.server)
      let outcome = try await CloudPersonalSync.sync(local: context, state: syncState, client: client, token: { identity })
      guard syncEnabled else { return }
      if let remote = outcome.apply { try store(remote) }
      saveSyncState(outcome.state)
      syncStatus = "Up to date with your other devices"
    } catch let failure as CloudSyncFailure where failure.code == "authentication_required" {
      syncStatus = "Cove’s server didn’t accept this sign-in. This account must be in the private beta."
    } catch {
      syncStatus = "Couldn’t sync just now. Cove will try again when it’s open."
    }
  }

  /// Deletes the copy on Cove's server and turns sync off here. Devices keep their own copy.
  func removeCloudCopy() async {
    guard let auth, !auth.isSample else { return }
    do {
      guard let identity = try await auth.identityToken() else { return }
      try await CloudMailClient(baseURL: MobilePush.server).removePersonal(token: identity)
      saveSyncState(PersonalSyncState())
      syncStatus = "Removed from Cove’s server. This iPhone keeps its copy; turn sync off on your other devices too."
    } catch {
      syncStatus = "Couldn’t remove the server copy. Try again."
    }
  }

  /// "Remember …" / "Forget …" from Ask Cove. Returns the confirmation to show.
  func handle(_ command: PersonalContext.Command) -> String {
    var updated = context
    let changed = updated.apply(command)
    try? save(updated)
    switch command {
    case .remember(let note): return changed.isEmpty ? "I already had that: “\(note)”." : "Got it. I’ll keep in mind: “\(note)”."
    case .forget(let phrase):
      return changed.isEmpty ? "I didn’t have anything about “\(phrase)”." : "Forgotten: " + changed.map { "“\($0)”" }.joined(separator: ", ") + "."
    }
  }

  private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
  private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Settings → About you: who you are, what you're working on, notes for Cove and your sign-off.
struct MobileAboutYouView: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  @State private var draft = MobileMe.shared.context
  @State private var newProject = ""
  @State private var newProjectDetail = ""
  @State private var newNote = ""
  @State private var suggesting = false
  @State private var notice: String?
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  private var changed: Bool { draft != MobileMe.shared.context }
  private var me: MobileMe { MobileMe.shared }
  private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

  var body: some View {
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Cove uses this when it writes for you and answers your questions, so drafts know who you are and what you’re working on.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
        Button {
          suggest()
        } label: {
          HStack(spacing: 8) {
            if suggesting { ProgressView() } else { Image(systemName: "sparkles") }
            Text(suggesting ? "Reading your sent mail…" : "Fill in from my sent mail")
          }
        }
        .buttonStyle(MobileSecondaryButton(compact: true)).disabled(suggesting || !ai.ready)
        if let notice { Label(notice, systemImage: "checkmark.circle").font(.mobileSecondary).foregroundStyle(MobilePalette.body) }
        if let error { Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger) }

        section("Who you are") {
          field("Name", text: $draft.name, prompt: mailbox.accountName ?? "Your name")
          field("Role", text: $draft.role, prompt: "Founder, designer, account manager…")
          field("Company", text: $draft.company, prompt: "Where you work")
          VStack(alignment: .leading, spacing: 6) {
            Text("What you do").font(.mobileControl).foregroundStyle(MobilePalette.body)
            TextField("One or two sentences, in your words", text: $draft.about, axis: .vertical)
              .lineLimit(2...5).textFieldStyle(MobileFieldStyle(font: .mobileText))
          }
        }

        section("What you’re working on") {
          ForEach($draft.projects) { $project in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 6) {
                TextField("Project", text: $project.name).font(.mobileLabel)
                TextField("A short line about it", text: $project.detail).font(.mobileSecondary).foregroundStyle(MobilePalette.body)
              }
              Button { draft.projects.removeAll { $0.id == project.id } } label: { Image(systemName: "minus.circle") }
                .foregroundStyle(MobilePalette.muted).accessibilityLabel("Remove \(project.name)")
            }
            .padding(12).background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 8))
          }
          HStack(spacing: 8) {
            TextField("Add a project", text: $newProject).textFieldStyle(MobileFieldStyle(font: .mobileText)).onSubmit(addProject)
            Button("Add", action: addProject).buttonStyle(MobilePrimaryButton(compact: true))
              .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }

        section("Notes for Cove") {
          Text("Anything Cove should keep in mind: time zone, who’s who, how you like replies. You can also tell Ask Cove “remember …” or “forget …”.")
            .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
          ForEach(Array(draft.notes.enumerated()), id: \.offset) { index, note in
            HStack(alignment: .top, spacing: 10) {
              Text(note).font(.mobileText).foregroundStyle(MobilePalette.ink).frame(maxWidth: .infinity, alignment: .leading)
              Button { draft.notes.remove(at: index) } label: { Image(systemName: "minus.circle") }
                .foregroundStyle(MobilePalette.muted).accessibilityLabel("Remove note")
            }
            .padding(12).background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 8))
          }
          HStack(spacing: 8) {
            TextField("Add a note", text: $newNote).textFieldStyle(MobileFieldStyle(font: .mobileText)).onSubmit(addNote)
            Button("Add", action: addNote).buttonStyle(MobilePrimaryButton(compact: true))
              .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }

        section("How you sign off") {
          TextField("Best,\nSantiago", text: $draft.signature, axis: .vertical)
            .lineLimit(2...4).textFieldStyle(MobileFieldStyle(font: .mobileText))
        }

        Toggle("Use in writing and Ask Cove", isOn: $draft.enabled).toggleStyle(MobileToggleStyle())
        Text("Encrypted in this \(device)’s Keychain. It goes to your chosen AI model only with a request, as your own words — never as facts from email.")
          .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)

        section("Your other devices") {
          Toggle("Sync with your Mac and iPad", isOn: Binding(get: { me.syncEnabled }, set: { on in Task { await me.setSync(on) } }))
            .toggleStyle(MobileToggleStyle()).disabled(me.syncing)
          Text("When on, About you is kept on Cove’s server, encrypted, so the Cove on your Mac and iPad uses the same. Cove’s server can decrypt it (it isn’t end-to-end encrypted). No email is sent. Turn it on in each device’s About you.")
            .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
          if let status = me.syncStatus {
            HStack(spacing: 6) {
              if me.syncing { ProgressView().controlSize(.small) }
              Text(status)
            }.font(.mobileSecondary).foregroundStyle(MobilePalette.body)
          }
          if me.syncEnabled {
            Button("Remove the copy on Cove’s server") { Task { await me.removeCloudCopy() } }
              .buttonStyle(MobileSecondaryButton(compact: true)).disabled(me.syncing)
          }
        }
        .id("sync")
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(20)
      .frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .onAppear {
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-CoveAboutSync") { proxy.scrollTo("sync", anchor: .bottom) }
      #endif
    }
    }
    .background(MobilePalette.surface)
    .task { await me.sync() }
    .onChange(of: me.context) { old, new in if draft == old { draft = new } }
    .navigationTitle("About you")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          do { try MobileMe.shared.save(draft); dismiss() } catch { self.error = error.localizedDescription }
        }.disabled(!changed)
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.mobileSection)
      MobileCard { content() }
    }
  }

  private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.mobileControl).foregroundStyle(MobilePalette.body)
      TextField(prompt, text: text).textFieldStyle(MobileFieldStyle(font: .mobileText))
    }
  }

  private func addProject() {
    let name = newProject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    draft.projects.append(.init(name: name, detail: newProjectDetail))
    newProject = ""
    newProjectDetail = ""
  }

  private func addNote() {
    let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return }
    draft.notes.append(String(note.prefix(200)))
    newNote = ""
  }

  /// Suggests empty fields from the user's own sent mail; nothing is saved until Save.
  private func suggest() {
    suggesting = true
    error = nil
    notice = nil
    Task {
      defer { suggesting = false }
      do {
        let samples = try await mailbox.sentSamples()
        guard samples.count >= 2 else { throw CoveError.message("Cove needs a few emails you wrote in Sent to suggest this.") }
        let prompt = try AIPrompt(intent: .answer, instruction: PersonalContext.suggestionInstruction, mails: samples,
                                  limits: ai.provider.isAppleIntelligence ? .onDevice : .standard)
        let merged = try draft.merging(suggestion: try await ai.complete(prompt))
        if merged == draft { notice = "Nothing new to suggest from your sent mail." } else {
          draft = merged
          notice = "Suggested from your sent mail. Review it, then Save."
        }
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
#endif
