import CoveCore
import SwiftUI

/// After a send: the thinking wave while Jev looks for promises, then a one-click way to keep them.
struct PostSendTaskToast: View {
  @Bindable var store: AppStore
  var body: some View {
    if let check = store.postSend {
      HStack(spacing: 12) {
        Image(systemName: "paperplane.fill").font(.cove(size: 13)).foregroundStyle(Palette.body)
          .accessibilityHidden(true)
        switch check.phase {
        case .checking:
          Text("Sent").font(.coveControl)
          WritingThinkingBar(stage: "Checking for tasks…").frame(width: 260)
        case .found:
          Text("Sent · you made a promise").font(.coveControl)
          Button {
            store.taskSuggestionMail = store.mails.first { $0.id == check.mailID }
            store.postSend = nil
          } label: { Label("Create task", systemImage: "checklist") }
            .buttonStyle(PrimaryButton(compact: true))
          Button { store.postSend = nil } label: { Image(systemName: "xmark").font(.cove(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Dismiss").accessibilityLabel("Dismiss")
        case .none:
          Text("Sent").font(.coveControl)
          Image(systemName: "checkmark").font(.cove(size: 12)).foregroundStyle(Palette.body)
        }
      }
      .padding(.horizontal, 16).frame(height: 48)
      .background(Palette.canvas, in: Capsule())
      .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
      .padding(.bottom, 24)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityElement(children: .contain)
    }
  }
}

/// Suggestions from the connected writing model, reviewed and added to Google Tasks by the user.
struct TaskSuggestionsView: View {
  @Bindable var store: AppStore
  let mail: Mail
  @Environment(\.dismiss) private var dismiss
  @State private var suggestions: [TaskSuggestion] = []
  @State private var chosen: Set<UUID> = []
  @State private var working = true
  @State private var adding = false
  @State private var message: String?
  @State private var added: [GoogleTask] = []
  private var sent: Bool { mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(store.accountEmail) == .orderedSame }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(added.isEmpty ? "Tasks from this email" : "Added to Google Tasks").font(.coveSection)
          Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(1)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").font(.cove(size: 12)).frame(width: 28, height: 28) }
          .buttonStyle(.plain).foregroundStyle(Palette.body).accessibilityLabel("Close")
      }
      if working {
        WritingThinkingBar(stage: sent ? "Finding what you promised…" : "Finding what’s asked of you…")
      } else if !added.isEmpty {
        ForEach(added) { task in
          Label(task.title, systemImage: "checkmark.circle.fill").font(.coveBody)
        }
      } else if suggestions.isEmpty {
        Text(message ?? "No follow-up tasks in this email.").font(.coveBody).foregroundStyle(Palette.body)
      } else {
        VStack(spacing: 0) {
          ForEach($suggestions) { $suggestion in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Toggle("", isOn: Binding(get: { chosen.contains(suggestion.id) },
                                       set: { if $0 { chosen.insert(suggestion.id) } else { chosen.remove(suggestion.id) } }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Include \(suggestion.title)")
              VStack(alignment: .leading, spacing: 4) {
                TextField("Task", text: $suggestion.title).textFieldStyle(.plain).font(.coveBody)
                HStack(spacing: 8) {
                  if let due = suggestion.due {
                    Label(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
                    Button("Remove date") { suggestion.due = nil }.buttonStyle(.plain)
                  } else {
                    Button("Add due date") { suggestion.due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
                      .buttonStyle(.plain)
                  }
                  if !suggestion.notes.isEmpty { Text(suggestion.notes).lineLimit(1) }
                }.font(.coveMetadata).foregroundStyle(Palette.body)
              }
            }.padding(.vertical, 10)
            Divider()
          }
        }
        if let message { Text(message).font(.coveMetadata).foregroundStyle(Palette.danger) }
      }
      HStack(spacing: 12) {
        if !added.isEmpty {
          Button("View tasks") { store.screen = "tasks"; dismiss() }.buttonStyle(PrimaryButton(compact: true))
        } else if !working && !suggestions.isEmpty {
          if store.tasksConnected {
            Button(chosen.count == 1 ? "Add task" : "Add \(chosen.count) tasks") { add() }
              .buttonStyle(PrimaryButton(compact: true)).disabled(chosen.isEmpty || adding)
          } else {
            Button("Connect Google Tasks") { Task { await store.connectTasks() } }
              .buttonStyle(PrimaryButton(compact: true)).disabled(store.busy)
          }
          Button("Not now") { dismiss() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        }
        if adding { ProgressView().controlSize(.small) }
        Spacer(minLength: 0)
      }
      if let error = store.tasksConnectError, !store.tasksConnected {
        Text(error).font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(24).frame(width: 480).background(Palette.canvas)
    .task { await load() }
  }

  private func load() async {
    working = true
    defer { working = false }
    guard AIProviderSettings.shared.writingProvider() != nil else {
      message = "Connect a writing model in Integrations to turn emails into tasks."
      return
    }
    do {
      suggestions = try await store.suggestTasks(for: mail) { try await AIProviderSettings.shared.complete($0) }
      chosen = Set(suggestions.map(\.id))
    } catch is CancellationError {} catch { message = error.localizedDescription }
  }
  private func add() {
    let picked = suggestions.filter { chosen.contains($0.id) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    adding = true
    message = nil
    Task {
      let result = await store.addTasks(picked, from: mail)
      adding = false
      added = result.created
      if !result.failed.isEmpty {
        message = "Couldn’t add: " + result.failed.joined(separator: ", ")
        suggestions.removeAll { suggestion in result.created.contains { $0.title == suggestion.title } }
      }
    }
  }
}

/// Google Tasks, open first; selecting one shows its details and the email it came from.
struct TasksView: View {
  @Bindable var store: AppStore
  @State private var selectedID: String?
  private var selected: GoogleTask? { store.googleTasks.first { $0.id == selectedID } }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Tasks").font(.coveTitle)
        if store.tasksConnected && !store.googleTasks.isEmpty {
          Text("\(store.googleTasks.filter { !$0.isCompleted }.count) open").font(.coveSecondary).foregroundStyle(Palette.body)
        }
        Spacer()
        if store.tasksConnected {
          Button { Task { await store.refreshTasks() } } label: {
            Group { if store.tasksLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }
              .frame(width: 24, height: 32)
          }.buttonStyle(.plain).disabled(store.tasksLoading).help("Refresh from Google Tasks")
            .accessibilityLabel("Refresh tasks")
        }
      }.padding(.horizontal, 32).padding(.vertical, 24)
      Divider()
      if store.isSample {
        empty("Tasks sync with Google Tasks once you connect Gmail.")
      } else if !store.tasksConnected {
        VStack(alignment: .leading, spacing: 14) {
          Text("Keep the promises in your email.").font(.coveSection)
          Text("Cove finds commitments and requests in your mail and adds them to Google Tasks when you approve, so they’re on your phone too.")
            .font(.coveBody).foregroundStyle(Palette.body).frame(maxWidth: 520, alignment: .leading)
          Button("Connect Google Tasks") { Task { await store.connectTasks() } }
            .buttonStyle(PrimaryButton()).disabled(store.busy)
          if let error = store.tasksConnectError { Text(error).font(.coveMetadata).foregroundStyle(Palette.body) }
        }.padding(32)
        Spacer()
      } else if store.googleTasks.isEmpty && !store.tasksLoading {
        empty("No open tasks. Cove suggests them after you send or read an email with a promise.")
      } else {
        HStack(spacing: 0) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(store.googleTasks) { task in
                row(task)
                Divider()
              }
            }.padding(.horizontal, 20)
          }.frame(minWidth: 320, maxWidth: selected == nil ? .infinity : 460)
          if let selected {
            Divider()
            TaskDetailView(store: store, task: selected) { selectedID = nil }
              .id(selected.id)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Palette.canvas)
    .task { await store.refreshTasks() }
    .onChange(of: store.googleTasks) { _, tasks in
      if let selectedID, !tasks.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
  }
  private func row(_ task: GoogleTask) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Button { Task { await store.setTask(task, completed: !task.isCompleted) } } label: {
        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.cove(size: 17))
      }.buttonStyle(.plain).foregroundStyle(task.isCompleted ? Palette.muted : Palette.ink)
        .accessibilityLabel(task.isCompleted ? "Mark \(task.title) not done" : "Mark \(task.title) done")
      VStack(alignment: .leading, spacing: 4) {
        Text(task.title).font(.coveBody).strikethrough(task.isCompleted).lineLimit(2)
          .foregroundStyle(task.isCompleted ? Palette.muted : Palette.ink)
        HStack(spacing: 10) {
          if let due = task.dueDay {
            Label(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
              .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) && !task.isCompleted ? Palette.danger : Palette.body)
          }
          if let mail = store.sourceMail(for: task) {
            Label(mail.sender.isEmpty ? mail.senderEmail : mail.sender, systemImage: "envelope").lineLimit(1)
          }
        }.font(.coveMetadata).foregroundStyle(Palette.body)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.cove(size: 11)).foregroundStyle(Palette.muted).accessibilityHidden(true)
    }
    .padding(.vertical, 14).padding(.horizontal, 12)
    .background(selectedID == task.id ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onTapGesture { selectedID = task.id }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Show details") { selectedID = task.id }
  }
  private func empty(_ text: String) -> some View {
    VStack { Text(text).font(.coveBody).foregroundStyle(Palette.body).frame(maxWidth: 460) }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// One task: edit its title, notes and due date, see the email it came from, or finish it.
struct TaskDetailView: View {
  @Bindable var store: AppStore
  let task: GoogleTask
  let close: () -> Void
  @State private var title = ""
  @State private var notes = ""
  @State private var due: Date?
  @State private var saving = false
  private var source: Mail? { store.sourceMail(for: task) }
  /// Cove's source line and Gmail link are kept out of the editable notes and shown as the email card.
  private static func editableNotes(_ notes: String?) -> String {
    (notes ?? "").split(separator: "\n", omittingEmptySubsequences: false).filter {
      !$0.hasPrefix("https://mail.google.com/") && !$0.hasPrefix("From: ")
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var changed: Bool {
    title != task.title || notes != Self.editableNotes(task.notes) || due != task.dueDay
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Button { Task { await store.setTask(task, completed: !task.isCompleted) } } label: {
            Label(task.isCompleted ? "Done" : "Mark done", systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle")
          }.buttonStyle(ReaderActionStyle()).font(.coveControl)
          Spacer()
          if let link = task.webViewLink, let url = URL(string: link), url.scheme == "https" {
            Link(destination: url) { Image(systemName: "arrow.up.right.square").frame(width: 32, height: 40) }
              .buttonStyle(ReaderActionStyle()).help("Open in Google Tasks").accessibilityLabel("Open in Google Tasks")
          }
          Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 40) }
            .buttonStyle(ReaderActionStyle()).help("Close").accessibilityLabel("Close details")
        }
        TextField("Task", text: $title, axis: .vertical).font(.coveDetailTitle).textFieldStyle(.plain)
          .lineLimit(1...4).accessibilityLabel("Task title")
        HStack(spacing: 10) {
          Image(systemName: "calendar").foregroundStyle(Palette.body)
          if let current = due {
            DatePicker("Due", selection: Binding(get: { current }, set: { due = $0 }), displayedComponents: .date)
              .labelsHidden()
            Button("Remove") { due = nil }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
          } else {
            Button("Add due date") { due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
              .buttonStyle(.plain).font(.coveControl)
          }
          Spacer()
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Notes").font(.coveLabel)
          TextField("Add notes", text: $notes, axis: .vertical).textFieldStyle(CoveFieldStyle(font: .coveBody))
            .lineLimit(3...10).accessibilityLabel("Task notes")
        }
        if changed {
          HStack(spacing: 12) {
            Button("Save changes") {
              saving = true
              let fullNotes = [notes] + (task.notes ?? "").split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("From: ") || $0.hasPrefix("https://mail.google.com/") }
              Task {
                await store.updateTask(task, title: title, notes: fullNotes.filter { !$0.isEmpty }.joined(separator: "\n"), due: due)
                saving = false
              }
            }.buttonStyle(PrimaryButton(compact: true)).disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Discard") { reset() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
            if saving { ProgressView().controlSize(.small) }
          }
        }
        if let mail = source {
          VStack(alignment: .leading, spacing: 10) {
            Text("From this email").font(.coveLabel)
            VStack(alignment: .leading, spacing: 6) {
              Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveSubheading).lineLimit(2)
              Text("\(mail.sender.isEmpty ? mail.senderEmail : mail.sender) · \(mail.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.coveMetadata).foregroundStyle(Palette.body)
              Text(String(mail.body.prefix(280))).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(5)
              Button {
                store.chooseFolder(mail.labels.contains("SENT") ? "Sent" : "Inbox")
                store.selectedID = mail.id
                store.screen = "mail"
              } label: { Label("Open email", systemImage: "envelope") }
                .buttonStyle(SecondaryButton(compact: true)).padding(.top, 4)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
              .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
          }
        } else if TaskDetection.threadID(inNotes: task.notes) != nil {
          Text("The email isn’t downloaded on this Mac.").font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }.padding(28).frame(maxWidth: 560, alignment: .leading)
    }
    .onAppear { reset() }
    .onChange(of: task) { _, _ in if !saving { reset() } }
  }
  private func reset() {
    title = task.title
    notes = Self.editableNotes(task.notes)
    due = task.dueDay
  }
}
