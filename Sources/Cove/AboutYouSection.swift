import CoveCore
import SwiftUI

/// Agent → About you on the Mac: who the user is, what they're working on and how they sign off.
/// Saved with the encrypted mailbox preferences and added to every draft and Ask Cove answer through
/// `Preferences.memoryPrompt`, next to the Memories below (the iPhone keeps the same `PersonalContext`).
struct AboutYouSection: View {
  @Bindable var store: AppStore
  @State private var newProject = ""

  private var context: Binding<PersonalContext> {
    Binding(get: { store.preferences.personal ?? PersonalContext() },
            set: { value in
              var updated = value
              updated.updatedAt = Date()
              store.preferences.personal = updated
              store.persistPreferences()
              store.schedulePersonalSync()
            })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("About you").font(.coveSection)
        Text("Cove uses this when it writes for you and answers your questions, so drafts know who you are and what you’re working on.")
          .font(.coveSecondary).foregroundStyle(Palette.body)
      }
      labeled("Name") { field("Your name", context.name) }
      HStack(spacing: 12) {
        labeled("Role") { field("Founder, designer…", context.role) }
        labeled("Company") { field("Where you work", context.company) }
      }
      labeled("What you do") {
        TextField("What you do", text: context.about, prompt: Text("One or two sentences, in your words").foregroundStyle(Palette.muted), axis: .vertical)
          .lineLimit(2...4).textFieldStyle(CoveFieldStyle(font: .coveBody))
      }
      labeled("What you’re working on") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(context.projects) { $project in
            HStack(spacing: 10) {
              TextField("Project", text: $project.name).textFieldStyle(CoveFieldStyle(font: .coveBody)).frame(maxWidth: 220)
              TextField("A short line about it", text: $project.detail).textFieldStyle(CoveFieldStyle())
              Button { context.wrappedValue.projects.removeAll { $0.id == project.id } } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Remove project").accessibilityLabel("Remove \(project.name)")
            }
          }
          HStack(spacing: 10) {
            TextField("Add a project", text: $newProject).textFieldStyle(CoveFieldStyle(font: .coveBody)).onSubmit(addProject)
            Button("Add", action: addProject).buttonStyle(SecondaryButton())
              .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      }
      labeled("How you sign off") {
        TextField("Sign-off", text: context.signature, prompt: Text("Best,\nYour name").foregroundStyle(Palette.muted), axis: .vertical)
          .lineLimit(2...4).textFieldStyle(CoveFieldStyle(font: .coveBody))
      }
      Toggle("Use About you in writing and Ask Cove", isOn: context.enabled).toggleStyle(CoveToggleStyle())
      Text("Stored encrypted on this Mac with your mailbox preferences. Sent to your chosen AI model only with a request, as your own words.")
        .font(.coveMetadata).foregroundStyle(Palette.muted)
      if store.cloudConfigured && !store.isSample { syncCard }
    }
    .task { await store.syncPersonal() }
  }

  /// Opt-in sync with the iPhone and iPad through Cove's server.
  private var syncCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Sync with your iPhone and iPad", isOn: Binding(get: { store.personalSyncOn },
                                                            set: { on in Task { await store.setPersonalSync(on) } }))
        .toggleStyle(CoveToggleStyle()).disabled(store.personalSyncing)
      Text("When on, About you is kept on Cove’s server, encrypted, so Cove on your iPhone and iPad uses the same. Cove’s server can decrypt it (it isn’t end-to-end encrypted). No email is sent. Turn it on in each device’s About you.")
        .font(.coveMetadata).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      if let status = store.personalSyncStatus {
        HStack(spacing: 6) {
          if store.personalSyncing { ProgressView().controlSize(.small) }
          Text(status).font(.coveSecondary).foregroundStyle(Palette.body)
        }
      }
      if store.personalSyncOn {
        Button("Remove the copy on Cove’s server") { Task { await store.removePersonalCloudCopy() } }
          .buttonStyle(SecondaryButton(compact: true)).disabled(store.personalSyncing)
      }
    }
    .padding(14)
    .background(Palette.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.coveControl).foregroundStyle(Palette.body)
      content()
    }
  }

  private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
    TextField(placeholder, text: text, prompt: Text(placeholder).foregroundStyle(Palette.muted))
      .textFieldStyle(CoveFieldStyle(font: .coveBody))
  }

  private func addProject() {
    let name = newProject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    context.wrappedValue.projects.append(.init(name: name))
    newProject = ""
  }
}
