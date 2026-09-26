import CoveCore
import SwiftUI

struct AgentMailCategory: Identifiable {
  let id: String
  let name: String
  let label: GmailLabel?
  let agents: [String]
}

extension AppStore {
  /// Only user-configured agent labels and labels actually applied by agents belong here.
  var agentMailCategories: [AgentMailCategory] {
    var names: [String: String] = [:]
    var sources: [String: Set<String>] = [:]
    func record(_ name: String, agent: String) {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      let key = trimmed.lowercased()
      names[key] = names[key] ?? trimmed
      sources[key, default: []].insert(agent)
    }
    for agent in customAgents.agents {
      if let rules = agent.rules {
        for rule in rules where rule.action.labels { record(rule.labelName, agent: agent.name) }
      } else { record(agent.labelName, agent: agent.name) }
    }
    for run in customAgents.runs where run.decision?.outcome != .review {
      if let label = run.appliedLabel {
        record(label, agent: customAgents.agents.first { $0.id == run.agentID }?.name ?? "Previous agent")
      }
    }
    return names.map { key, name in
      let label = customMailLabels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
      return AgentMailCategory(id: key, name: label?.name ?? name, label: label,
                               agents: (sources[key] ?? []).sorted())
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  func agentLabels(on mail: Mail) -> [GmailLabel] {
    agentMailCategories.compactMap(\.label).filter { mail.labels.contains($0.id) }
  }
}

struct MailCategoriesView: View {
  @Bindable var store: AppStore
  @State private var query = ""
  @FocusState private var searching: Bool
  private var categories: [AgentMailCategory] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.agentMailCategories.filter {
      needle.isEmpty || ($0.name + " " + $0.agents.joined(separator: " ")).localizedCaseInsensitiveContains(needle)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Categories").font(.coveTitle)
          Text("The labels your agents organize mail into.")
            .font(.coveBody).foregroundStyle(Palette.body)
        }
        Spacer()
        Button("Your agents") { store.screen = "agents" }.buttonStyle(SecondaryButton(compact: true))
      }.padding(32)
      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
          TextField("Find a category or agent", text: $query).textFieldStyle(.plain).focused($searching)
          if !query.isEmpty {
            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain).accessibilityLabel("Clear category search")
          }
        }.font(.coveControl).foregroundStyle(Palette.body).padding(12)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(searching ? Palette.ink : Palette.line))
          .frame(maxWidth: 420)
        Spacer()
        if store.labelsRefreshing { ProgressView().controlSize(.small) }
        Button { Task { await store.refreshLabels() } } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }.buttonStyle(.plain).font(.coveControl).disabled(store.labelsRefreshing || store.isSample)
      }.padding(.horizontal, 32).padding(.bottom, 24)
      Divider()
      if let error = store.labelsError {
        Text(error).font(.coveControl).foregroundStyle(Palette.danger).padding(.horizontal, 32).padding(.top, 16)
      }
      if categories.isEmpty {
        ContentUnavailableView(query.isEmpty ? "Your categories start with your agents" : "No matching categories",
          systemImage: query.isEmpty ? "tag" : "magnifyingglass",
          description: Text(query.isEmpty ? "Give an agent a label to apply. Its category will appear here, ready for matching emails." : "Try another category or agent name."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(categories) { category in
              if let label = category.label {
                Button { store.chooseLabel(label) } label: { row(category) }.buttonStyle(.plain)
                  .help("Open " + category.name)
              } else { row(category) }
              Divider()
            }
          }.padding(.horizontal, 32)
        }
      }
      Divider()
      Text("Counts reflect downloaded mail. Open a category to load more from Gmail.")
        .font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 32).padding(.vertical, 16)
    }.background(Palette.canvas)
      .background(Button("") { searching = true }.keyboardShortcut("k").hidden())
      .task { await store.refreshLabels(force: false) }
  }
  private func row(_ category: AgentMailCategory) -> some View {
    let mails = category.label.map { store.mailsWithLabel($0.id) } ?? []
    let unread = mails.filter(\.isUnread).count
    return HStack(spacing: 16) {
      Image(systemName: "tag").font(.cove(size: 19)).foregroundStyle(Palette.body).frame(width: 28)
      VStack(alignment: .leading, spacing: 6) {
        Text(category.name).font(.coveSubheading).lineLimit(2)
        Text(category.agents.joined(separator: " · ")).font(.coveControl).foregroundStyle(Palette.body).lineLimit(2)
        if category.label == nil {
          Text("Waiting for this label to appear in Gmail").font(.coveMetadata).foregroundStyle(Palette.muted)
        }
      }
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 6) {
        Text("\(mails.count) downloaded").font(.coveControl)
        if unread > 0 { Text("\(unread) unread").font(.coveMetadata).foregroundStyle(Palette.body) }
      }
      Image(systemName: "chevron.right").font(.coveMetadata).foregroundStyle(Palette.muted)
        .opacity(category.label == nil ? 0 : 1)
    }.padding(.vertical, 22).contentShape(Rectangle())
  }
}
