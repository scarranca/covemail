import CoveCore
import SwiftUI

struct AgentView: View {
  @Bindable var store: AppStore
  @State private var instruction = ""
  @State private var memory = ""
  @State private var memorySearch = ""
  @FocusState private var focusedMemory: Int?
  private var visibleMemoryIndices: [Int] {
    store.preferences.memories.indices.filter {
      $0 == focusedMemory || memorySearch.isEmpty
        || store.preferences.memories[$0].localizedCaseInsensitiveContains(memorySearch)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Your agent").font(.coveTitle)
          Text("Make Cove work like you, and remember what matters.").foregroundStyle(Palette.muted)
        }
        Spacer()
        Label("Saved on this Mac", systemImage: "checkmark").font(.coveMetadata)
          .foregroundStyle(Palette.muted)
      }.padding(32).padding(.top, 22)
      Divider()
      ScrollView {
        HStack(alignment: .top, spacing: 32) {
          VStack(alignment: .leading, spacing: 22) {
            section(
              "A little help with your inbox",
              subtitle: "Jev makes focused decisions. You stay in control.")
            Toggle(
              "Organize new mail with Jev",
              isOn: Binding(
                get: { store.preferences.autoClassify },
                set: { store.setAutoOrganization($0) })
            ).toggleStyle(CoveToggleStyle()).disabled(store.busy || store.isSample)
              .accessibilityLabel("Organize new mail with Jev")
            Text(
              "When enabled, new incoming mail is sent to TypeSafe for categorization, action and urgency scores, and a key passage. Low-confidence categories stay in Other for review. Background Gmail sync is controlled separately in Settings."
            ).font(.coveSecondary).foregroundStyle(Palette.muted).lineSpacing(4)
            if let started = store.preferences.autoClassifySince, store.preferences.autoClassify {
              Text(
                "New mail received since \(started.formatted(date: .abbreviated, time: .shortened))"
              )
              .font(.coveMetadata).foregroundStyle(Palette.muted)
            }
            Button {
              Task { await store.classifyInbox() }
            } label: {
              Label("Organize downloaded mail", systemImage: "sparkles")
            }.buttonStyle(PrimaryButton()).disabled(store.busy)
            Text(
              "Use this to organize older downloaded mail too. Emails already assessed are skipped."
            )
            .font(.coveMetadata).foregroundStyle(Palette.muted)
            Divider().padding(.vertical, 10)
            section("Reply templates", subtitle: "A starting point for replies you write yourself.")
            CoveSegmentedPicker(
              selection: $store.preferences.voice, options: ["Professional", "Warm", "Direct"])
            TextField(
              "Your sign-off", text: $store.preferences.signoff,
              prompt: Text("Your sign-off").foregroundStyle(Palette.muted)
            ).textFieldStyle(CoveFieldStyle())
              .accessibilityLabel("Your sign-off")
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Label("Sounds like you", systemImage: "sparkles")
                Spacer()
                Text("Sample template").foregroundStyle(Palette.muted)
              }.font(.coveMetadata)
              Text(
                ReplyTemplates.reply(
                  to: "Maya", voice: store.preferences.voice, signoff: store.preferences.signoff)
              ).font(.coveBody).lineSpacing(CoveTypography.bodyLineSpacing)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(
              Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            Text(
              "Replies are written by you, with optional starting templates. Jev selects and scores; it does not generate prose."
            ).font(.coveSecondary).foregroundStyle(Palette.muted)
            Divider().padding(.vertical, 10)
            section("Teach your agent", subtitle: "A few clear instructions go a long way.")
            VStack(alignment: .trailing, spacing: 12) {
              TextField(
                "A preference, a rule, or something about you…", text: $instruction, axis: .vertical
              ).lineLimit(3...5).textFieldStyle(.plain).font(.coveBody)
                .accessibilityLabel("New instruction")
              Button("Add instruction") {
                store.preferences.instructions.append(
                  instruction.trimmingCharacters(in: .whitespacesAndNewlines))
                instruction = ""
                store.persistPreferences()
              }.buttonStyle(PrimaryButton()).disabled(
                instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16).overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
            ForEach(Array(store.preferences.instructions.enumerated()), id: \.offset) {
              index, text in
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.muted)
                Text(text).font(.coveBody).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                  store.preferences.instructions.remove(at: index)
                  store.persistPreferences()
                } label: {
                  Image(systemName: "trash")
                }.buttonStyle(.plain).help("Remove instruction")
                  .accessibilityLabel("Remove instruction \(index + 1)")
              }
            }
          }.frame(maxWidth: 660, alignment: .leading)
          Divider()
          VStack(alignment: .leading, spacing: 24) {
            section("Memories", subtitle: "What Cove knows about you. Edit or forget anything.")
            Toggle("Use my saved memories", isOn: $store.preferences.useMemories).toggleStyle(
              CoveToggleStyle())
            Divider()
            TextField(
              "Search memories", text: $memorySearch,
              prompt: Text("Search memories").foregroundStyle(Palette.muted)
            ).textFieldStyle(CoveFieldStyle())
              .accessibilityLabel("Search memories")
            if store.preferences.memories.isEmpty {
              Text(
                "A little context helps. Add your role, your priorities, or the people you work with."
              ).font(.coveText).foregroundStyle(Palette.muted).lineSpacing(5).padding(
                .vertical, 20)
            }
            if !store.preferences.memories.isEmpty && visibleMemoryIndices.isEmpty {
              Text("No matching memories.").font(.coveText).foregroundStyle(Palette.muted)
            }
            ForEach(visibleMemoryIndices, id: \.self) { index in
              HStack(alignment: .top) {
                TextField(
                  "Memory",
                  text: Binding(
                    get: {
                      store.preferences.memories.indices.contains(index)
                        ? store.preferences.memories[index] : ""
                    },
                    set: {
                      if store.preferences.memories.indices.contains(index) {
                        store.preferences.memories[index] = $0
                        store.persistPreferences()
                      }
                    }), axis: .vertical
                ).textFieldStyle(.plain)
                  .focused($focusedMemory, equals: index)
                  .accessibilityLabel("Memory \(index + 1)")
                Button {
                  focusedMemory = nil
                  store.forgetMemory(at: index)
                } label: {
                  Image(systemName: "trash")
                }.buttonStyle(.plain).help("Forget memory")
                  .accessibilityLabel("Forget memory \(index + 1)")
              }.font(.coveBody)
              Divider()
            }
            TextField(
              "Add something to remember…", text: $memory,
              prompt: Text("Add something to remember…").foregroundStyle(Palette.muted),
              axis: .vertical
            ).lineLimit(2...4)
              .textFieldStyle(CoveFieldStyle(font: .coveBody))
              .accessibilityLabel("New memory")
            Button {
              store.preferences.memories.append(
                memory.trimmingCharacters(in: .whitespacesAndNewlines))
              memory = ""
              store.persistPreferences()
            } label: {
              Label("Add a memory", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(SecondaryButton()).disabled(
              memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(
              "Stored locally. Enabled memories are shared with TypeSafe only when you run your agent."
            ).font(.coveMetadata).foregroundStyle(Palette.muted).lineSpacing(4)
          }.frame(maxWidth: 660, alignment: .leading)
        }.padding(32)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if store.removedMemory != nil {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle").foregroundStyle(Palette.muted)
          Text("Memory removed").font(.coveText).foregroundStyle(Palette.body)
          Button("Undo") { store.undoForgetMemory() }.buttonStyle(.plain).font(.coveControl)
            .accessibilityLabel("Undo forgetting memory")
          Button {
            store.removedMemory = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss memory undo")
        }.padding(16).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line)).padding(24)
      }
    }
    .onChange(of: store.preferences.voice) { _, _ in store.persistPreferences() }.onChange(
      of: store.preferences.signoff
    ) { _, _ in
      store.persistPreferences()
    }.onChange(of: store.preferences.useMemories) { _, _ in store.persistPreferences() }
  }
  func section(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.coveSection)
      Text(subtitle).font(.coveSecondary).foregroundStyle(Palette.muted)
    }
  }
}
