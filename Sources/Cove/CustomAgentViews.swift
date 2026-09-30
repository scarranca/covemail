import CoveCore
import SwiftUI

struct CustomAgentsView: View {
  @Bindable var store: AppStore
  @State private var filter = "All agents"
  @State private var search = ""
  @State private var deleting: CustomAgent?
  @State private var showHelp = false
  private var agents: [CustomAgent] {
    store.customAgents.agents.filter {
      (filter == "All agents" || $0.status.title == (filter == "Drafts" ? "Draft" : filter))
        && (search.isEmpty || ($0.name + " " + $0.instructions).localizedCaseInsensitiveContains(search))
    }.sorted { $0.createdAt < $1.createdAt }
  }
  var body: some View {
    if let agent = store.agentEditor {
      CustomAgentEditor(store: store, agent: agent).id(agent.id + agent.revision)
    } else if let id = store.agentActivityID,
              let agent = store.customAgents.agents.first(where: { $0.id == id }) {
      CustomAgentActivity(store: store, agent: agent)
    } else {
      GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("Agents").font(.coveControl).foregroundStyle(Palette.body)
            Spacer()
            Button("How agents work") { showHelp.toggle() }.buttonStyle(.plain).font(.coveControl)
          }.padding(.horizontal, 32).padding(.vertical, 18)
          Divider()
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              AgentsHeader(store: store, compact: geometry.size.width < 820)
              if showHelp {
                Text("Jev checks new inbox mail against your rules, in order. The first confident match can apply a Gmail label, prepare a reply, or both. Your writing model prepares replies for review in Activity; nothing sends automatically. Uncertain results stay in Activity for your review, without changing Gmail labels. Agents run during Gmail sync while Cove is open. They cannot send, delete, or make purchases. Tests send the chosen content to TypeSafe but never change Gmail.")
                  .font(.coveBody).foregroundStyle(Palette.body).lineSpacing(5).padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
              }
              if !store.isSample {
                JevRequiredBanner(reason: "Agents use Jev to check each new email against your rules. Add your TypeSafe key to create and run them.")
              }
              notices
              // Filters only help once there are several agents to sift through.
              if store.customAgents.agents.count > 5 {
                ViewThatFits(in: .horizontal) {
                  HStack { filters; Spacer(minLength: 20); searchField.frame(width: 210) }
                  VStack(alignment: .leading, spacing: 14) { filters; searchField }
                }
              }
              if store.customAgents.agents.isEmpty {
                AgentTemplateGallery(store: store)
              } else if agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  Text("No agents found").font(.coveSection)
                  Text("Try another search or status filter.").font(.coveBody).foregroundStyle(Palette.body)
                }.padding(.vertical, 24)
              } else {
                Text("Your agents").font(.coveSection).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                  if geometry.size.width > 760 {
                    HStack(spacing: 16) {
                      Color.clear.frame(width: 40, height: 1)
                      Text("Agent").frame(maxWidth: .infinity, alignment: .leading)
                      Text("Status").frame(width: 85, alignment: .leading)
                      Text("Last activity").frame(width: 190, alignment: .leading)
                      Color.clear.frame(width: 44, height: 1)
                    }.font(.coveMetadata).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.bottom, 12)
                  }
                  ForEach(agents) { agent in
                    agentRow(agent, compact: geometry.size.width <= 760)
                    Divider()
                  }
                }
              }
              if !store.customAgents.agents.isEmpty {
                AgentTemplateGallery(store: store, title: "More ideas").padding(.top, 12)
              }
              Button("Built-in organizer & writing preferences") { store.screen = "agent" }
                .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body).padding(.top, 12)
            }.padding(32)
          }
        }.background(Palette.canvas)
      }
      .confirmationDialog("Delete \(deleting?.name ?? "agent")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        Button("Delete agent", role: .destructive) { if let deleting { store.deleteCustomAgent(deleting) }; deleting = nil }
        Button("Cancel", role: .cancel) { deleting = nil }
      } message: { Text("Its instructions and activity will be removed from this Mac. Existing Gmail labels and emails will stay as they are.") }
    }
  }
  private var searchField: some View {
    TextField("Search agents…", text: $search).textFieldStyle(CoveFieldStyle()).accessibilityLabel("Search agents")
  }
  private var filters: some View {
    HStack(spacing: 5) {
      ForEach(["All agents", "Active", "Paused", "Drafts"], id: \.self) { value in
        let count = store.customAgents.agents.filter { value == "All agents" || $0.status.title == (value == "Drafts" ? "Draft" : value) }.count
        Button { filter = value } label: {
          HStack(spacing: 6) { Text(value); Text("\(count)").foregroundStyle(Palette.body) }
            .font(.coveControl).padding(.horizontal, 10).padding(.vertical, 9)
            .background(filter == value ? Palette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
      }
    }
  }
  @ViewBuilder private var notices: some View {
    if let message = store.agentFailure {
      Text(message).font(.coveText).foregroundStyle(Palette.danger).textSelection(.enabled)
    }
    if let message = store.agentNotice { Text(message).font(.coveText).foregroundStyle(Palette.body) }
  }
  private func agentRow(_ agent: CustomAgent, compact: Bool) -> some View {
    let last = store.customAgents.runs.filter { $0.agentID == agent.id }.max { $0.date < $1.date }
    return HStack(alignment: .center, spacing: 16) {
      Image(systemName: "sparkles").font(.system(size: 18)).frame(width: 40, height: 42).background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 7) {
        Button(agent.name) { store.agentEditor = agent }.buttonStyle(.plain).font(.coveSubheading)
        Text(agent.instructions).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(2)
        if compact { Text(agent.status.title + " · " + activityTitle(last)).font(.coveMetadata).foregroundStyle(last?.error == nil ? Palette.muted : Palette.danger) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if !compact {
        Text(agent.status.title).font(.coveControl).frame(width: 85, alignment: .leading)
        VStack(alignment: .leading, spacing: 6) {
          Button(activityTitle(last)) { store.agentActivityID = agent.id }.buttonStyle(.plain).font(.coveSecondary).foregroundStyle(last?.error == nil ? Palette.body : Palette.danger).lineLimit(2)
          if let last { Text(last.date, style: .relative).font(.coveMetadata).foregroundStyle(Palette.muted) }
        }.frame(width: 190, alignment: .leading)
      }
      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Menu {
          Button("Edit agent") { store.agentEditor = agent }
          Button(agent.status == .active ? "Pause agent" : "Turn on agent") { store.setCustomAgentStatus(agent, agent.status == .active ? .paused : .active) }
          Button("View activity") { store.agentActivityID = agent.id }
          Button("Duplicate agent") { store.duplicateCustomAgent(agent) }
          Divider()
          Button("Delete agent…", role: .destructive) { deleting = agent }
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 30) }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(agent.name)")
      }.frame(width: 44)
    }.padding(.vertical, 20).contentShape(Rectangle())
      .onTapGesture { store.agentEditor = agent }
  }
  private func activityTitle(_ run: CustomAgentRun?) -> String {
    guard let run else { return "Not run yet" }
    if run.error != nil { return "Needs attention · retry pending" }
    if run.replySuggestion != nil { return run.replyApplied == true ? "Reply added to draft" : "Reply ready for review" }
    if let label = run.appliedLabel { return "Labeled · " + label }
    return run.completed ? run.decision?.outcome.title ?? "Checked" : "Action pending"
  }
}

struct CustomAgentEditor: View {
  @Bindable var store: AppStore
  @State var agent: CustomAgent
  @State private var source = TestSource.sample
  @State private var notifyPermission: AgentNotificationPermission?
  private enum TestSource: Hashable { case sample, inbox, recent }
  private var sample: Bool { source == .sample }
  /// The agent as it was opened; leaving without changes needs no confirmation.
  private var original: CustomAgent? { store.agentEditor }
  @State private var sampleText = CustomAgentEditor.example.body
  @State private var mailID = ""
  @State private var mailSearch = ""
  @State private var result: CustomAgentDecision?
  @State private var testError: String?
  @State private var testing = false
  @State private var testTask: Task<Void, Never>?
  @State private var testID = UUID()
  @State private var discard = false
  /// Describe first: a blank agent starts as one sentence; Cove proposes the rules.
  @State private var describing: Bool?
  @State private var brief = ""
  @State private var building = false
  @State private var buildTask: Task<Void, Never>?
  @State private var buildNote: String?
  @State private var buildError: String?
  @State private var editingRule: String?
  @State private var showsLooksFor = false
  private var isNew: Bool { !store.customAgents.agents.contains { $0.id == agent.id } }
  private var inbox: [Mail] { store.mails.filter { $0.labels.contains("INBOX") && $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]) && (mailSearch.isEmpty || ($0.subject + $0.senderEmail).localizedCaseInsensitiveContains(mailSearch)) }.sorted { $0.date > $1.date } }
  private var selected: Mail? {
    if source == .recent { return nil }
    if sample { var mail = Self.example; mail.body = sampleText; return mail }
    return store.mails.first { $0.id == mailID }
  }
  private var ruleBinding: Binding<[CustomAgentRule]> {
    Binding(get: { agent.rules ?? [] }, set: { agent.rules = $0 })
  }
  static var example: Mail {
    Mail(id: "sample-agent-invoice", sender: "Acme Studio", senderEmail: "billing@acmestudio.example", subject: "Invoice for June services", body: "Hi Alex,\n\nInvoice #INV-2048 for $1,250.00 is due July 15. Supplier: Acme Studio. Thanks for working with us!\n\nThe Acme team")
  }
  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Button { leave() } label: { Label("All agents", systemImage: "chevron.left") }.buttonStyle(.plain)
            .accessibilityLabel("Back to all agents")
          Spacer()
        }.font(.coveControl).padding(.horizontal, 32).padding(.vertical, 18)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            if isDescribing {
              Text(isNew ? "Create an agent" : "Describe it again").font(.coveTitle)
            } else {
              TextField("Name your agent", text: $agent.name).textFieldStyle(.plain).font(.coveTitle)
                .accessibilityLabel("Agent name")
            }
            if isDescribing {
              form.frame(maxWidth: 640, alignment: .leading)
            } else if geometry.size.width >= 920 {
              HStack(alignment: .top, spacing: 32) { form.frame(maxWidth: .infinity); Divider(); preview.frame(width: 320) }
            } else { form; Divider(); preview }
          }.padding(32)
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
          if let message = store.agentFailure { Text(message).font(.coveSecondary).foregroundStyle(Palette.danger) }
          ViewThatFits(in: .horizontal) {
            HStack { footerText; Spacer(minLength: 24); if !isDescribing { saveButtons } }
            VStack(alignment: .leading, spacing: 12) { footerText; if !isDescribing { saveButtons } }
          }
        }.padding(.horizontal, 32).padding(.vertical, 18).background(Palette.canvas)
      }
    }.background(Palette.canvas)
      .onChange(of: agent) { old, new in
        cancelTest()
        // A preview belongs to the instructions it was made with. Applying is left to finish.
        var before = old; before.notifyOnMatch = new.notifyOnMatch
        if before != new, store.agentBackfill?.phase != .applying { store.cancelAgentBackfill() }
      }
      .onChange(of: sampleText) { _, _ in cancelTest() }
      .onChange(of: source) { _, _ in cancelTest() }
      .onChange(of: mailID) { _, _ in cancelTest() }
      .onDisappear {
        cancelTest()
        if store.agentEditor?.id != agent.id { store.cancelAgentBackfill() }
      }
      .onAppear { if store.agentBackfill?.agentID == agent.id { source = .recent } }
      .task { if agent.notifies { notifyPermission = await store.agentNotificationPermission(request: false) } }
      .confirmationDialog("Leave this agent?", isPresented: $discard, titleVisibility: .visible) {
        Button("Discard unsaved changes", role: .destructive) { store.agentEditor = nil; store.agentFailure = nil }
        Button("Keep editing", role: .cancel) {}
      } message: { Text("Save your changes before leaving if you want to keep them.") }
  }
  private var isDescribing: Bool {
    describing ?? !(agent.rules?.contains { !$0.condition.trimmingCharacters(in: .whitespaces).isEmpty } ?? !agent.labelName.isEmpty)
  }
  private var hasModel: Bool { AIProviderSettings.shared.writingProvider() != nil }
  @ViewBuilder private var form: some View {
    if isDescribing { describeForm } else { planForm }
  }

  /// One question. The agent's job in the user's words; the writing model turns it into rules to review.
  private var describeForm: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("What should this agent do?").font(.coveSection)
        Text("Describe the job like you’d ask an assistant. Cove turns it into steps you can check before anything runs.")
          .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
      TextField("e.g. When a supplier sends an invoice, file it under Finance. If it’s overdue, draft a polite reply saying I’ll check it this week.",
                text: $brief, axis: .vertical)
        .lineLimit(4...10).textFieldStyle(CoveFieldStyle(font: .coveBody)).accessibilityLabel("What the agent should do")
        .disabled(building)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { examples }
        VStack(alignment: .leading, spacing: 8) { examples }
      }
      if hasModel {
        HStack(spacing: 12) {
          Button { build() } label: {
            HStack(spacing: 8) {
              if building { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
              Text(building ? "Building your agent…" : "Build agent")
            }
          }.buttonStyle(PrimaryButton()).disabled(building || brief.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
            .keyboardShortcut(.return, modifiers: .command)
          if building { Button("Cancel") { buildTask?.cancel(); building = false }.buttonStyle(.plain).font(.coveControl) }
        }
      } else {
        HStack(spacing: 10) {
          Image(systemName: "sparkles").foregroundStyle(Palette.body)
          Text("Connect an AI account to build agents from a description.").font(.coveSecondary).foregroundStyle(Palette.body)
          Spacer(minLength: 8)
          Button("Connect AI") { store.integrationsFocus = .ai; store.screen = "integrations" }.buttonStyle(SecondaryButton(compact: true))
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      if let buildError { Label(buildError, systemImage: "exclamationmark.circle").font(.coveSecondary).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
      Button(isNew ? "Or set it up step by step" : "Keep the current setup") {
        if (agent.rules ?? []).isEmpty { agent.rules = [CustomAgentRule()] }
        describing = false; editingRule = agent.rules?.first?.id
      }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body).disabled(building)
    }
  }
  @ViewBuilder private var examples: some View {
    ForEach(["File receipts under Finance / Receipts", "Draft replies to client questions", "Tell me when a candidate applies"], id: \.self) { example in
      Button { brief = example } label: {
        Text(example).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(Palette.surface, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line))
      }.buttonStyle(.plain).disabled(building)
    }
  }
  private func build() {
    buildError = nil; buildNote = nil; building = true
    let base = agent
    buildTask = Task { @MainActor in
      defer { building = false }
      do {
        let result = try await store.buildCustomAgent(from: brief, base: base) { try await AIProviderSettings.shared.complete($0) }
        try Task.checkCancellation()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
          agent = result.agent; buildNote = result.note; describing = false; editingRule = nil
        }
      } catch is CancellationError {
      } catch { buildError = error.localizedDescription }
    }
  }

  /// The agent as plain steps: when this happens, it does that. Each step opens in place to edit.
  private var planForm: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 6) {
        Text("How it works").font(.coveSection)
        Text("For each new email in your Inbox, the first step that fits runs.").font(.coveSecondary).foregroundStyle(Palette.body)
      }
      if let buildNote {
        Label(buildNote, systemImage: "info.circle").font(.coveSecondary).foregroundStyle(Palette.body)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      VStack(spacing: 10) {
        if agent.rules == nil {
          ForEach(Array(agent.plan.enumerated()), id: \.offset) { index, step in
            planCard(index: index, when: step.when, does: step.does, editing: false, edit: {
              agent.rules = [CustomAgentRule(condition: step.when, labelName: agent.labelName)]
              editingRule = agent.rules?.first?.id
            }, remove: nil)
          }
        } else {
          ForEach(ruleBinding) { $rule in
            let index = agent.rules?.firstIndex(where: { $0.id == rule.id }) ?? 0
            let step = agent.plan.indices.contains(index) ? agent.plan[index] : (rule.condition, "")
            if editingRule == rule.id {
              VStack(alignment: .leading, spacing: 10) {
                CustomAgentRuleEditor(rule: $rule, position: index + 1, count: agent.rules?.count ?? 0,
                  move: { offset in
                    guard let count = agent.rules?.count, (0..<count).contains(index + offset) else { return }
                    agent.rules?.swapAt(index, index + offset)
                  }, remove: { agent.rules?.removeAll { $0.id == rule.id }; editingRule = nil })
                Button("Done") { withAnimation(.easeOut(duration: 0.2)) { editingRule = nil } }
                  .buttonStyle(SecondaryButton(compact: true))
              }
            } else {
              planCard(index: index, when: step.0, does: step.1, editing: false,
                       edit: { withAnimation(.easeOut(duration: 0.2)) { editingRule = rule.id } },
                       remove: (agent.rules?.count ?? 0) > 1 ? { agent.rules?.removeAll { $0.id == rule.id } } : nil)
            }
          }
        }
      }
      HStack(spacing: 18) {
        Button {
          if agent.rules == nil { agent.rules = [CustomAgentRule(condition: agent.instructions, labelName: agent.labelName)] }
          let rule = CustomAgentRule(); agent.rules?.append(rule); editingRule = rule.id
        } label: { Label("Add a step", systemImage: "plus") }
          .disabled((agent.rules?.count ?? 0) >= 8)
        Button { brief = brief.isEmpty ? agent.instructions : brief; describing = true } label: {
          Label("Describe it again", systemImage: "sparkles")
        }
      }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
      Toggle("Notify me when it matches", isOn: Binding(get: { agent.notifies }, set: { setNotify($0) }))
        .toggleStyle(CoveToggleStyle()).font(.coveControl)
      if let note = notifyNote {
        HStack(spacing: 8) {
          Text(note).font(.coveMetadata).foregroundStyle(Palette.danger)
          if notifyPermission == .denied {
            Button("Open Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.plain).font(.coveMetadata)
          }
        }
      }
      Label("Unclear emails wait in Activity for you. Agents never send, delete or pay.", systemImage: "checkmark.shield")
        .font(.coveMetadata).foregroundStyle(Palette.muted)
      DisclosureGroup(isExpanded: $showsLooksFor) {
        VStack(alignment: .leading, spacing: 12) {
          TextField("What kinds of email is this agent about? What should it ignore?", text: $agent.instructions, axis: .vertical)
            .lineLimit(3...8).textFieldStyle(CoveFieldStyle(font: .coveBody)).accessibilityLabel("What the agent looks for")
          Label("Runs when a new email arrives in \(store.accountEmail)’s Inbox, while Cove is open.", systemImage: "tray")
            .font(.coveSecondary).foregroundStyle(Palette.body)
          Toggle("Read PDF and text attachments", isOn: $agent.includeAttachments).toggleStyle(CoveToggleStyle()).font(.coveSecondary)
          Text("Up to 5 files, 5 MB each. Scans and unsupported files go to review.").font(.coveMetadata).foregroundStyle(Palette.muted)
        }.padding(.top, 12)
      } label: {
        Text("What it looks for and options").font(.coveControl).foregroundStyle(Palette.body)
      }.disclosureGroupStyle(CoveDisclosureStyle())
    }
  }
  private func replyGist(_ index: Int) -> String? {
    guard let rules = agent.rules, rules.indices.contains(index), rules[index].action.drafts else { return nil }
    let text = rules[index].replyInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
  private func planCard(index: Int, when: String, does: String, editing: Bool, edit: @escaping () -> Void, remove: (() -> Void)?) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(index + 1)").font(.coveMetadata).foregroundStyle(Palette.body)
        .frame(width: 22, height: 22).background(Palette.sidebar, in: Circle()).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("When").font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
          Text(when.isEmpty ? "Describe when this step applies" : when).font(.coveBody)
            .foregroundStyle(when.isEmpty ? Palette.muted : Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("Then").font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
          Text(does).font(.coveLabel).fixedSize(horizontal: false, vertical: true)
        }
        if let reply = replyGist(index) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Says").font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
            Text(reply).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(2)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 10) {
        Button(action: edit) { Image(systemName: "pencil") }.help("Edit this step").accessibilityLabel("Edit step \(index + 1)")
        if let remove { Button(action: remove) { Image(systemName: "trash") }.help("Remove this step").accessibilityLabel("Remove step \(index + 1)") }
      }.buttonStyle(.plain).font(.cove(size: 12)).foregroundStyle(Palette.body)
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
      .contentShape(RoundedRectangle(cornerRadius: 10)).onTapGesture(perform: edit)
  }
  private var preview: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Try it").font(.coveSection)
      Picker("Test source", selection: $source) {
        Text("Sample").tag(TestSource.sample); Text("Inbox email").tag(TestSource.inbox); Text("Recent mail").tag(TestSource.recent)
      }.pickerStyle(.segmented).labelsHidden()
      if source == .recent {
        CustomAgentBackfillPanel(store: store, agent: agent)
      } else { singleTest }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private var singleTest: some View {
      if source == .inbox {
        TextField("Find an inbox email", text: $mailSearch).textFieldStyle(CoveFieldStyle()).accessibilityLabel("Find a test email")
        Picker("Email", selection: $mailID) {
          Text("Choose an email…").tag("")
          ForEach(inbox.prefix(50)) { Text($0.subject.isEmpty ? "(No subject)" : $0.subject).tag($0.id) }
        }.labelsHidden().accessibilityLabel("Email to test")
        if inbox.isEmpty { Text("No matching downloaded inbox emails.").font(.coveSecondary).foregroundStyle(Palette.muted) }
      }
      if let selected {
        VStack(alignment: .leading, spacing: 10) {
          Text(selected.subject).font(.coveSubheading)
          Text(selected.senderEmail).font(.coveSecondary).foregroundStyle(Palette.body)
          if sample {
            TextField("Sample email text", text: $sampleText, axis: .vertical).lineLimit(5...14)
              .textFieldStyle(CoveFieldStyle(font: .coveBody)).accessibilityLabel("Sample email text")
          } else { Text(String(selected.body.prefix(1800))).font(.coveBody).lineSpacing(CoveTypography.bodyLineSpacing).textSelection(.enabled) }
          ForEach(selected.availableAttachments) { Label($0.filename, systemImage: "paperclip").font(.coveMetadata) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      if testing {
        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Jev is checking the evidence…").font(.coveSecondary); Spacer(); Button("Cancel") { cancelTest() }.buttonStyle(.plain) }
      } else {
        Button(result == nil ? "Run test" : "Run test again") { runTest() }.buttonStyle(SecondaryButton()).disabled(selected == nil)
      }
      if let testError { Text(testError).font(.coveSecondary).foregroundStyle(Palette.danger).textSelection(.enabled) }
      if let result {
        Divider()
        Label(result.outcome.title, systemImage: result.outcome == .review ? "questionmark.circle" : "checkmark.circle").font(.coveSection)
        Text("Confidence · \(Int(result.confidence * 100))%").font(.coveMetadata).foregroundStyle(Palette.body)
        if let excerpt = result.excerpt { Text(excerpt).font(.coveBody).lineSpacing(CoveTypography.bodyLineSpacing).textSelection(.enabled) }
        ForEach(result.warnings, id: \.self) { Text($0).font(.coveSecondary).foregroundStyle(Palette.body) }
        if let rule = result.rule(for: agent) {
          Text("Matched: " + rule.condition).font(.coveControl)
          if rule.action.drafts { Label("Would prepare a reply for review", systemImage: "square.and.pencil").font(.coveControl) }
        }
        if let label = result.label(for: agent) { Text("Would apply label: " + label).font(.coveControl) }
        else if result.outcome != .match { Text("Would leave the email unchanged.").font(.coveControl) }
        Text("Routing preview only. No labels or replies have been created.").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
      Text("Tests never change your inbox. They send your instructions and this email (with enabled attachment text) to TypeSafe; reply rules also use your writing provider. Provider charges apply.")
        .font(.coveMetadata).foregroundStyle(Palette.muted).lineSpacing(3)
  }
  private var footerText: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(isNew ? "Draft · not running" : agent.status.title).font(.coveControl)
      Text("Runs on new emails only. Pause it anytime.").font(.coveMetadata).foregroundStyle(Palette.body)
    }
  }
  private var saveButtons: some View {
    HStack(spacing: 12) {
      Button(isNew || agent.status == .draft ? "Save draft" : "Save changes") {
        _ = store.saveCustomAgent(agent, status: agent.status)
      }.buttonStyle(SecondaryButton())
      if agent.status != .active {
        // While a recent-mail preview waits for Apply, that is the view's one primary action.
        if store.agentBackfill?.agentID == agent.id && store.agentBackfill?.phase == .ready {
          Button(isNew ? "Create & turn on" : "Save & turn on") { _ = store.saveCustomAgent(agent, status: .active) }.buttonStyle(SecondaryButton())
        } else {
          Button(isNew ? "Create & turn on" : "Save & turn on") { _ = store.saveCustomAgent(agent, status: .active) }.buttonStyle(PrimaryButton())
        }
      }
    }
  }
  private var notifyNote: String? {
    switch notifyPermission {
    case .denied?: return "Notifications are off for Cove."
    case .unavailable?: return "Notifications aren’t available in this build."
    default: return nil
    }
  }
  private func setNotify(_ on: Bool) {
    agent.notifyOnMatch = on
    guard on else { notifyPermission = nil; return }
    Task { @MainActor in
      let permission = await store.agentNotificationPermission(request: true)
      notifyPermission = permission
      // Honest state: stay off when macOS won't show them.
      if permission == .denied || permission == .unavailable { agent.notifyOnMatch = false }
    }
  }
  private func leave() {
    if let original, original == agent { store.agentEditor = nil; store.agentFailure = nil } else { discard = true }
  }
  private func cancelTest() {
    testTask?.cancel(); testTask = nil; testID = UUID(); testing = false; result = nil; testError = nil
  }
  private func runTest() {
    guard let selected else { return }
    cancelTest(); testing = true
    let id = testID; let draft = agent; let synthetic = sample
    testTask = Task { @MainActor in
      do {
        let answer = try await store.previewCustomAgent(draft, mail: selected, synthetic: synthetic)
        guard id == testID else { return }
        result = answer
      } catch is CancellationError {} catch { if id == testID { testError = error.localizedDescription } }
      if id == testID { testing = false }
    }
  }
}

struct CustomAgentActivity: View {
  @Bindable var store: AppStore
  let agent: CustomAgent
  @State private var reviewOnly = false
  private var allRuns: [CustomAgentRun] {
    store.customAgents.runs.filter { $0.agentID == agent.id }.sorted { $0.date > $1.date }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Button { store.agentActivityID = nil } label: { Label("All agents", systemImage: "chevron.left") }.buttonStyle(.plain).font(.coveControl)
        .accessibilityLabel("Back to all agents")
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text(agent.name).font(.coveTitle)
          Text("Activity · " + agent.status.title).font(.coveBody).foregroundStyle(Palette.body)
        }
        Spacer()
        Button("Retry unfinished checks") { Task { await store.runCustomAgents(ignoreCooldown: true, agentID: agent.id) } }.buttonStyle(SecondaryButton()).disabled(store.busy || agent.status != .active)
      }
      if let failure = store.agentFailure { Text(failure).foregroundStyle(Palette.danger).font(.coveSecondary) }
      HStack(spacing: 16) {
        Button("All checks \(allRuns.count)") { reviewOnly = false }.fontWeight(reviewOnly ? .regular : .semibold)
        Button("Needs review \(allRuns.filter { $0.decision?.outcome == .review }.count)") { reviewOnly = true }.fontWeight(reviewOnly ? .semibold : .regular)
      }.buttonStyle(.plain).font(.coveControl)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          let runs = allRuns.filter { !reviewOnly || $0.decision?.outcome == .review }
          if runs.isEmpty { Text(reviewOnly ? "No checks need review." : "No checks yet. Active agents check inbox mail received after you turn them on, during Gmail sync.").font(.coveBody).foregroundStyle(Palette.body) }
          ForEach(runs) { run in
            VStack(alignment: .leading, spacing: 9) {
              HStack {
                Text(run.subject.isEmpty ? "(No subject)" : run.subject).font(.coveSubheading)
                Spacer()
                Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.coveMetadata).foregroundStyle(Palette.muted)
              }
              if let error = run.error { Text(error).font(.coveSecondary).foregroundStyle(Palette.danger).textSelection(.enabled) }
              Text(run.appliedLabel.map { "Applied label: " + $0 } ?? (run.completed ? run.decision?.outcome.title ?? "Checked" : "Awaiting retry")).font(.coveControl)
              if run.decision?.outcome == .review {
                Text(run.decision?.warnings.isEmpty == false ? "Some relevant content could not be fully checked." : "Jev wasn’t confident enough to apply this rule.")
                  .font(.coveSecondary).foregroundStyle(Palette.body)
              }
              if let condition = run.matchedCondition { Text("Matched: " + condition).font(.coveSecondary).foregroundStyle(Palette.body) }
              if let reply = run.replySuggestion {
                Text(run.replyApplied == true ? "Reply added to your draft" : "Reply ready for review").font(.coveSubheading)
                Text(reply).font(.coveBody).lineSpacing(4).textSelection(.enabled)
                  .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                if run.replyApplied != true {
                  Button("Use reply as draft") { store.applyCustomAgentReply(run) }.buttonStyle(PrimaryButton(compact: true))
                  Text("Opens the reply in its original conversation. You review and send it yourself.").font(.coveMetadata).foregroundStyle(Palette.muted)
                }
              }
              if let excerpt = run.decision?.excerpt { Text(excerpt).font(.coveText).foregroundStyle(Palette.body).lineLimit(5).textSelection(.enabled) }
              ForEach(run.decision?.warnings ?? [], id: \.self) { Text($0).font(.coveSecondary).foregroundStyle(Palette.body) }
              if store.mails.contains(where: { $0.id == run.mailID }) {
                Button("Open email") { store.chooseFolder("All mail"); store.selectedID = run.mailID }.buttonStyle(.plain).font(.coveControl)
              }
            }
            Divider()
          }
        }
      }
    }.padding(32).background(Palette.canvas)
  }
}

private struct CustomAgentRuleEditor: View {
  @Binding var rule: CustomAgentRule
  let position: Int
  let count: Int
  let move: (Int) -> Void
  let remove: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Step \(position)").font(.coveSubheading)
        Spacer()
        Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(position == 1).accessibilityLabel("Move step up")
        Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(position == count).accessibilityLabel("Move step down")
        Button(action: remove) { Image(systemName: "trash") }.disabled(count <= 1).accessibilityLabel("Remove rule \(position)").help("Remove rule")
      }.buttonStyle(.plain).font(.coveSecondary).foregroundStyle(Palette.body)
      Text("When").font(.coveControl)
      TextField("e.g. A supplier says a payment is overdue", text: $rule.condition, axis: .vertical)
        .lineLimit(2...5).textFieldStyle(CoveFieldStyle(font: .coveBody)).accessibilityLabel("Rule \(position) condition")
      Picker("Then", selection: $rule.action) {
        ForEach(CustomAgentAction.allCases, id: \.self) { Text($0.title).tag($0) }
      }.font(.coveControl)
      if rule.action.labels {
        TextField("Gmail label, e.g. US EXPENSE", text: $rule.labelName).textFieldStyle(CoveFieldStyle()).accessibilityLabel("Rule \(position) Gmail label")
      }
      if rule.action.drafts {
        TextField("What should the reply say? e.g. Acknowledge the invoice and ask for the missing purchase order.", text: $rule.replyInstructions, axis: .vertical)
          .lineLimit(3...8).textFieldStyle(CoveFieldStyle(font: .coveBody)).accessibilityLabel("Rule \(position) reply instructions")
      }
    }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
  }
}
