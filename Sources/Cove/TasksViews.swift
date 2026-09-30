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

/// Google Tasks, open first, with the email each came from.
struct TasksView: View {
  @Bindable var store: AppStore
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Tasks").font(.coveTitle)
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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.googleTasks) { task in
              row(task)
              Divider()
            }
          }.padding(.horizontal, 32)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Palette.canvas)
    .task { await store.refreshTasks() }
  }
  private func row(_ task: GoogleTask) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Button { Task { await store.setTask(task, completed: !task.isCompleted) } } label: {
        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.cove(size: 17))
      }.buttonStyle(.plain).foregroundStyle(task.isCompleted ? Palette.muted : Palette.ink)
        .accessibilityLabel(task.isCompleted ? "Mark \(task.title) not done" : "Mark \(task.title) done")
      VStack(alignment: .leading, spacing: 4) {
        Text(task.title).font(.coveBody).strikethrough(task.isCompleted)
          .foregroundStyle(task.isCompleted ? Palette.muted : Palette.ink)
        HStack(spacing: 10) {
          if let due = task.dueDay {
            Label(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
              .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) && !task.isCompleted ? Palette.danger : Palette.body)
          }
          if let mail = store.sourceMail(for: task) {
            Button {
              store.chooseFolder("Inbox")
              store.selectedID = mail.id
              store.screen = "mail"
            } label: { Label(mail.subject.isEmpty ? "Open email" : mail.subject, systemImage: "envelope").lineLimit(1) }
              .buttonStyle(.plain)
          }
        }.font(.coveMetadata).foregroundStyle(Palette.body)
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 14)
  }
  private func empty(_ text: String) -> some View {
    VStack { Text(text).font(.coveBody).foregroundStyle(Palette.body).frame(maxWidth: 460) }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
