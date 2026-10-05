#if os(iOS)
import CoveCore
import SwiftUI

/// Google Tasks, as the Mac's Tasks screen: the night overview with recent completions, a quick-add
/// line ("Call Millet Friday"), and open tasks grouped by when they're due.
struct MobileTasksView: View {
  let auth: MobileAuth
  let workspace: MobileWorkspace
  let mailbox: MobileMailbox
  let ai: MobileAI
  @State private var newTask = ""
  @State private var adding = false
  @State private var path: [String] = []
  @FocusState private var addFocused: Bool

  private var groups: [(String, [GoogleTask])] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
    let week = calendar.date(byAdding: .day, value: 7, to: today) ?? today
    var buckets: [String: [GoogleTask]] = [:]
    for task in workspace.openTasks {
      let key: String
      if let due = task.dueDay {
        key = due < today ? "Overdue" : due < tomorrow ? "Today" : due < calendar.date(byAdding: .day, value: 1, to: tomorrow)! ? "Tomorrow"
          : due < week ? "This week" : "Later"
      } else {
        key = "No date"
      }
      buckets[key, default: []].append(task)
    }
    return ["Overdue", "Today", "Tomorrow", "This week", "Later", "No date"].compactMap { key in
      buckets[key].map { (key, $0.sorted { ($0.dueDay ?? .distantFuture) < ($1.dueDay ?? .distantFuture) }) }
    }
  }

  private var dueToday: Int {
    let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
    return workspace.openTasks.filter { ($0.dueDay ?? .distantFuture) < end }.count
  }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          MobileScreenHeader(title: "Tasks", detail: auth.tasksConnected ? "\(workspace.openTasks.count) open" : nil) {
            Button { Task { await workspace.loadTasks() } } label: {
              if workspace.loadingTasks { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(MobileIconButton()).accessibilityLabel("Refresh tasks")
          }
          if !auth.tasksConnected && !auth.isSample {
            MobileConnectCard(auth: auth, title: "Connect Google Tasks",
                              detail: "Keep the promises in your mail. Cove adds tasks only when you ask, and links each one back to its email.")
          } else {
            overview
            addField
            if let error = workspace.tasksError {
              Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger)
            }
            if workspace.openTasks.isEmpty && !workspace.loadingTasks {
              MobileEmptyState(title: "Nothing open", detail: "Add a task above, or create one from an email’s More menu.",
                               systemImage: "checklist")
            }
            ForEach(groups, id: \.0) { title, tasks in
              VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.mobileSection).foregroundStyle(title == "Overdue" ? MobilePalette.danger : MobilePalette.ink)
                  .padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                ForEach(tasks) { task in
                  MobileTaskRow(task: task, workspace: workspace) { threadID in
                    if let mail = mailbox.allLoaded.first(where: { $0.threadID == threadID }) { path.append(mail.id) }
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        // A readable column on iPad, as the Mac keeps task pages to a reading width.
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
      }
      .background(MobilePalette.canvas)
      .refreshable { await workspace.loadTasks() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: String.self) { id in
        MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
      }
    }
  }

  private var overview: some View {
    let done = workspace.completedRecently.count
    let daily = TaskMomentum.daily(workspace.completedRecently, days: 14)
    return VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(dueToday == 0 ? "Nothing due today" : "\(dueToday) due today").font(.mobileTitle)
        Text("\(workspace.openTasks.count) open · \(done) done in the last 30 days").font(.mobileSecondary)
          .foregroundStyle(MobilePalette.nightSecondary)
      }
      VStack(spacing: 8) {
        GeometryReader { geometry in
          let maximum = Double(max(daily.max() ?? 0, 1))
          HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(daily.enumerated()), id: \.offset) { index, count in
              VStack(spacing: 3) {
                Spacer(minLength: 0)
                ForEach(0..<max(1, Int((Double(count) / maximum * 6).rounded(.up))), id: \.self) { _ in
                  Circle().fill(MobilePalette.tide[index * MobilePalette.tide.count / max(daily.count, 1)])
                    .frame(width: 3, height: 3).opacity(count == 0 ? 0.35 : 1)
                }
              }.frame(maxWidth: .infinity, maxHeight: geometry.size.height)
            }
          }
        }.frame(height: 34).accessibilityHidden(true)
        HStack {
          Text("2 weeks ago"); Spacer(); Text("\(daily.reduce(0, +)) done"); Spacer(); Text("Today")
        }.font(.mobileMetadata).foregroundStyle(MobilePalette.nightSecondary)
      }
    }
    .foregroundStyle(MobilePalette.nightText)
    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
    .background(MobilePalette.night, in: RoundedRectangle(cornerRadius: 10))
  }

  private var addField: some View {
    HStack(spacing: 12) {
      Image(systemName: "plus").foregroundStyle(MobilePalette.body)
      TextField("Add a task… try “Call Millet Friday”", text: $newTask)
        .font(.mobileText).focused($addFocused).submitLabel(.done)
        .onSubmit(add).disabled(adding)
      if adding { ProgressView() } else if !newTask.isEmpty {
        Button("Add", action: add).buttonStyle(MobilePrimaryButton(compact: true))
      }
    }
    .padding(.horizontal, 16).frame(minHeight: 50)
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(addFocused ? MobilePalette.ink : .clear))
  }

  private func add() {
    let text = newTask
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !adding else { return }
    adding = true
    Task {
      if await workspace.addTask(text) { newTask = "" }
      adding = false
    }
  }
}

/// One task: the Mac's open circle, title, due day and steps; done tasks are struck through.
struct MobileTaskRow: View {
  let task: GoogleTask
  let workspace: MobileWorkspace
  var openEmail: ((String) -> Void)?
  @State private var expanded = false

  var body: some View {
    let steps = workspace.steps(of: task)
    let thread = TaskDetection.threadID(inNotes: task.notes)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        Button { Task { await workspace.setCompleted(task, !task.isCompleted) } } label: {
          Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
            .foregroundStyle(task.isCompleted ? MobilePalette.ink : MobilePalette.inputBorder)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isCompleted ? "Mark \(task.title) not done" : "Mark \(task.title) done")
        Button { expanded.toggle() } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(.mobileBody).foregroundStyle(task.isCompleted ? MobilePalette.muted : MobilePalette.ink)
              .strikethrough(task.isCompleted).multilineTextAlignment(.leading)
            let meta = [task.dueDay.map { MobileDates.section($0) }, steps.isEmpty ? nil : "\(steps.filter(\.isCompleted).count)/\(steps.count) steps",
                        thread == nil ? nil : "From email"].compactMap { $0 }
            if !meta.isEmpty {
              Text(meta.joined(separator: " · ")).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          if let notes = task.notes, !notes.isEmpty {
            Text(notes).font(.mobileSecondary).foregroundStyle(MobilePalette.body).textSelection(.enabled)
          }
          ForEach(steps) { step in
            HStack(spacing: 10) {
              Button { Task { await workspace.setCompleted(step, !step.isCompleted) } } label: {
                Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                  .foregroundStyle(step.isCompleted ? MobilePalette.ink : MobilePalette.inputBorder)
              }.buttonStyle(.plain)
              Text(step.title).font(.mobileText).strikethrough(step.isCompleted)
                .foregroundStyle(step.isCompleted ? MobilePalette.muted : MobilePalette.ink)
            }
          }
          HStack(spacing: 10) {
            if let thread, let openEmail {
              Button { openEmail(thread) } label: { Label("Open email", systemImage: "envelope") }
                .buttonStyle(MobileSecondaryButton(compact: true))
            }
            if let link = task.webViewLink, let url = URL(string: link) {
              Link(destination: url) { Label("Google Tasks", systemImage: "arrow.up.right.square") }
                .buttonStyle(MobileSecondaryButton(compact: true))
            }
          }
        }.padding(.leading, 34)
      }
    }
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) { Divider().overlay(MobilePalette.line).padding(.leading, 34) }
  }
}
#endif
