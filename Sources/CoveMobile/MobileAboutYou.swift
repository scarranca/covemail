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
    try MobileKeychain.save(String(decoding: try Self.encoder.encode(value), as: UTF8.self), name: Self.key)
    context = value
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

  var body: some View {
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
        Text("Stays on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"), encrypted in the Keychain. It goes to your chosen AI model only with a request, as your own words — never as facts from email.")
          .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(20)
      .frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .background(MobilePalette.surface)
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
