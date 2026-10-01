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
              .buttonStyle(PrimaryButton(compact: true)).disabled(store.connectingStep != nil)
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
    guard AIProviderSettings.shared.hasWorkingDefault else {
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

/// Google Tasks grouped by when they're due, with instant quick-add and an AI plan for today.
struct TasksView: View {
  @Bindable var store: AppStore
  @State private var selectedID: String?
  @State private var quickAdd = ""
  @State private var adding = false
  @State private var planning = false
  @State private var plan: [TaskQuickAdd.DayPick]?
  @State private var planError: String?
  @State private var showDone = false
  @FocusState private var quickAddFocused: Bool
  private var selected: GoogleTask? { store.googleTasks.first { $0.id == selectedID } }
  private var topLevel: [GoogleTask] { store.googleTasks.filter { $0.parent == nil } }
  private func children(of task: GoogleTask) -> [GoogleTask] { store.googleTasks.filter { $0.parent == task.id } }

  private enum Group: String, CaseIterable { case overdue = "Overdue", today = "Today", tomorrow = "Tomorrow", upcoming = "Upcoming", someday = "No date" }
  private func group(_ task: GoogleTask) -> Group {
    guard let due = task.dueDay else { return .someday }
    let today = Calendar.current.startOfDay(for: Date())
    if due < today { return .overdue }
    if Calendar.current.isDateInToday(due) { return .today }
    if Calendar.current.isDateInTomorrow(due) { return .tomorrow }
    return .upcoming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if store.isSample {
        empty("Tasks sync with Google Tasks once you connect Gmail.")
      } else if !store.tasksConnected {
        connect
      } else {
        GeometryReader { geometry in
        HStack(spacing: 0) {
          ScrollView {
            let wide = selected == nil && geometry.size.width >= 1080
            VStack(alignment: .leading, spacing: 18) {
              overview
              if wide {
                HStack(alignment: .top, spacing: 28) {
                  taskList(wide: true).frame(maxWidth: .infinity, alignment: .topLeading)
                  VStack(alignment: .leading, spacing: 24) { waitingInMail; todayOnCalendar }.frame(width: 380)
                }
              } else {
                taskList(wide: false)
              }
            }.padding(20).frame(maxWidth: wide ? 1320 : 720, alignment: .leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(minWidth: 340, maxWidth: selected == nil ? .infinity : 480)
          if let selected {
            Divider()
            TaskDetailView(store: store, task: selected, subtasks: children(of: selected)) { selectedID = nil }
              .id(selected.id).frame(maxWidth: .infinity)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }.animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedID)
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

  private var header: some View {
    HStack(spacing: 12) {
      Text("Tasks").font(.coveTitle)
      if store.tasksConnected {
        Text("\(topLevel.filter { !$0.isCompleted }.count) open").font(.coveSecondary).foregroundStyle(Palette.body)
      }
      Spacer()
      if store.tasksConnected && !store.isSample {
        Button { Task { await store.refreshTasks() } } label: {
          SwiftUI.Group { if store.tasksLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }
            .frame(width: 24, height: 32)
        }.buttonStyle(.plain).disabled(store.tasksLoading).help("Refresh from Google Tasks").accessibilityLabel("Refresh tasks")
      }
    }.padding(.horizontal, 32).padding(.vertical, 22)
  }

  /// Quick add, the plan, open tasks by when they're due, then Done. Narrow windows also list email finds here.
  @ViewBuilder private func taskList(wide: Bool) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      quickAddBar
      if planning || plan != nil || planError != nil { planCard }
      if !wide { waitingInMail }
      ForEach(Group.allCases, id: \.self) { section in
        let tasks = topLevel.filter { !$0.isCompleted && group($0) == section }
        if !tasks.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            Text(section.rawValue).font(.coveLabel).foregroundStyle(section == .overdue ? Palette.danger : Palette.body)
              .padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(tasks) { task in
              row(task)
              ForEach(children(of: task)) { child in row(child).padding(.leading, 30) }
            }
          }
        }
      }
      let done = topLevel.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
      if !done.isEmpty {
        DisclosureGroup("Done · \(done.count) in the last 30 days", isExpanded: $showDone) {
          VStack(spacing: 2) { ForEach(done) { row($0) } }.padding(.top, 6)
        }.font(.coveLabel).disclosureGroupStyle(CoveDisclosureStyle()).padding(.horizontal, 12)
      }
    }
  }

  /// What's left on today's calendar, to see where tasks can fit.
  @ViewBuilder private var todayOnCalendar: some View {
    if store.calendarConnected || store.isSample {
      let now = Date()
      let events = store.events.filter { Calendar.current.isDateInToday($0.start) && $0.allDay != true && $0.end > now }
        .sorted { $0.start < $1.start }
      VStack(alignment: .leading, spacing: 8) {
        Label("Today on your calendar", systemImage: "calendar").font(.coveLabel).foregroundStyle(Palette.body).padding(.horizontal, 12)
        VStack(alignment: .leading, spacing: 0) {
          if events.isEmpty {
            Text("Nothing else today. A good stretch for your tasks.").font(.coveSecondary).foregroundStyle(Palette.body)
              .padding(14)
          } else {
            ForEach(Array(events.prefix(6).enumerated()), id: \.element.id) { index, event in
              if index > 0 { Divider() }
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(event.start, format: .dateTime.hour().minute()).font(.coveMetadata).foregroundStyle(Palette.body)
                  .frame(width: 62, alignment: .leading)
                Text(event.title.isEmpty ? "Busy" : event.title).font(.coveSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                .onTapGesture { store.selectCalendarDay(event.start); store.calendarEventID = event.id; store.screen = "calendar" }
            }
          }
        }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
      }
    }
  }

  /// The day at a glance, like Home: what's due, what got done, and two weeks of finished tasks as dots.
  private var overview: some View {
    let open = topLevel.filter { !$0.isCompleted }
    let overdue = open.filter { group($0) == .overdue }.count
    let dueToday = open.filter { group($0) == .today }.count
    let done = topLevel.filter(\.isCompleted).count
    let counts = TaskMomentum.daily(topLevel)
    let headline = overdue > 0 ? "\(overdue) overdue" : dueToday > 0 ? "\(dueToday) due today"
      : open.isEmpty ? "All clear" : "Nothing due today"
    let detail = open.isEmpty
      ? (done > 0 ? "You finished \(done) in the last 30 days." : "Add one below, or let Cove find them in your email.")
      : "\(open.count) open · \(done) done in the last 30 days"
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 28) { overviewText(headline, detail, open: open.count).frame(width: 300, alignment: .leading); momentum(counts) }
      VStack(alignment: .leading, spacing: 18) { overviewText(headline, detail, open: open.count); momentum(counts) }
    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(red: 0.114, green: 0.125, blue: 0.165), in: RoundedRectangle(cornerRadius: 10))
  }
  private func overviewText(_ headline: String, _ detail: String, open: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(headline).font(.coveTitle).foregroundStyle(Color(white: 0.96))
      Text(detail).font(.coveSecondary).foregroundStyle(Color(white: 0.8)).fixedSize(horizontal: false, vertical: true)
      if AIProviderSettings.shared.hasWorkingDefault && open > 0 {
        Button { runPlan() } label: { Label("Plan my day", systemImage: "sparkles") }
          .buttonStyle(SecondaryButton(compact: true)).disabled(planning).padding(.top, 4)
          .help("Cove picks what to do today and finds time for it")
      }
    }
  }
  private func momentum(_ counts: [Int]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TaskMomentumView(counts: counts).frame(height: 96)
      HStack {
        Text("2 weeks ago"); Spacer()
        Text("\(counts.reduce(0, +)) done"); Spacer()
        Text("Today")
      }.font(.coveMetadata).foregroundStyle(Color(white: 0.7))
    }.frame(maxWidth: .infinity)
  }

  /// Emails where Jev found a promise or a request that isn't a task yet.
  @ViewBuilder private var waitingInMail: some View {
    let waiting = Array(TaskMomentum.waitingInMail(store.mails).prefix(5))
    if !waiting.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("Found in your email", systemImage: "envelope.badge").font(.coveLabel).foregroundStyle(Palette.body)
          .padding(.horizontal, 12)
        VStack(spacing: 0) {
          ForEach(Array(waiting.enumerated()), id: \.element.id) { index, mail in
            if index > 0 { Divider() }
            HStack(alignment: .center, spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(waitingTitle(mail)).font(.coveLabel).lineLimit(1)
                Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(1)
                Text(mail.date, format: .dateTime.month(.abbreviated).day()).font(.coveMetadata).foregroundStyle(Palette.muted)
              }
              Spacer(minLength: 6)
              Button { store.taskSuggestionMail = mail } label: {
                Label("Task", systemImage: "plus").font(.coveControl).padding(.horizontal, 10).frame(height: 30)
                  .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                  .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
              }.buttonStyle(.plain).fixedSize().help("Create a task from this email")
                .accessibilityLabel("Create a task from \(mail.subject)")
              Button { withAnimation(.easeOut(duration: 0.2)) { store.dismissTaskSuggestion(mail) } } label: {
                Image(systemName: "xmark").font(.cove(size: 11)).frame(width: 26, height: 26)
              }.buttonStyle(.plain).foregroundStyle(Palette.body)
                .help("No task needed").accessibilityLabel("Ignore: no task needed for \(mail.subject)")
            }.padding(.horizontal, 14).padding(.vertical, 10)
          }
        }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
      }
    }
  }

  /// Who the promise involves: the sender, or for mail the user sent, who it went to.
  private func waitingTitle(_ mail: Mail) -> String {
    let fromMe = mail.labels.contains("SENT") || mail.senderEmail.caseInsensitiveCompare(store.accountEmail) == .orderedSame
    guard fromMe else { return mail.sender.isEmpty ? mail.senderEmail : mail.sender }
    let first = mail.to.split(separator: ",").first.map(String.init) ?? ""
    let name = first.split(separator: "<").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? ""
    let address = first.split(separator: "<").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " >")) } ?? ""
    let who = name.isEmpty || name.contains("@") ? address : name
    return who.isEmpty ? "You promised" : "You → \(who)"
  }

  private var connect: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Keep the promises in your email.").font(.coveSection)
      Text("Cove finds commitments and requests in your mail and adds them to Google Tasks when you approve, so they’re on your phone too.")
        .font(.coveBody).foregroundStyle(Palette.body).frame(maxWidth: 520, alignment: .leading)
      Button("Connect Google Tasks") { Task { await store.connectTasks() } }.buttonStyle(PrimaryButton()).disabled(store.connectingStep != nil)
      if let error = store.tasksConnectError { Text(error).font(.coveMetadata).foregroundStyle(Palette.body) }
      Spacer()
    }.padding(32)
  }

  private var quickAddBar: some View {
    let parsed = TaskQuickAdd.parse(quickAdd)
    return HStack(spacing: 10) {
      Image(systemName: adding ? "hourglass" : "plus").font(.cove(size: 14)).foregroundStyle(Palette.body).frame(width: 20)
      TextField("Add a task… try “Call Millet Friday”", text: $quickAdd)
        .textFieldStyle(.plain).font(.coveBody).focused($quickAddFocused)
        .onSubmit { submitQuickAdd() }.disabled(adding).accessibilityLabel("Add a task")
      if let due = parsed.due, !parsed.title.isEmpty {
        Label(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
          .font(.coveMetadata).foregroundStyle(Palette.ink).padding(.horizontal, 8).padding(.vertical, 4)
          .background(Palette.sidebar, in: Capsule()).transition(.scale.combined(with: .opacity))
      }
    }
    .padding(.horizontal, 14).frame(height: 46)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(quickAddFocused ? Palette.inputBorder : Color.clear))
    .animation(.easeOut(duration: 0.15), value: parsed.due)
  }
  private func submitQuickAdd() {
    let text = quickAdd
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    adding = true
    Task {
      if await store.addQuickTask(text) != nil { quickAdd = "" }
      adding = false
      quickAddFocused = true
    }
  }

  private var planCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Your day", systemImage: "sparkles").font(.coveSubheading)
        Spacer()
        Button { plan = nil; planError = nil } label: { Image(systemName: "xmark").font(.cove(size: 11)) }
          .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Close plan")
      }
      if planning {
        WritingThinkingBar(stage: "Choosing what matters today…")
      } else if let planError {
        Text(planError).font(.coveSecondary).foregroundStyle(Palette.body)
      } else if let plan, plan.isEmpty {
        Text("Nothing stands out for today.").font(.coveSecondary).foregroundStyle(Palette.body)
      } else if let plan {
        ForEach(Array(plan.enumerated()), id: \.element.id) { index, pick in
          if let task = store.googleTasks.first(where: { $0.id == pick.id }) {
            PlanRow(store: store, number: index + 1, task: task, pick: pick) { selectedID = task.id }
          }
        }
      }
    }
    .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
  }
  private func runPlan() {
    planning = true; planError = nil; plan = nil
    Task {
      do { plan = try await store.planDay { try await AIProviderSettings.shared.complete($0) } }
      catch { planError = error.localizedDescription }
      planning = false
    }
  }

  private func row(_ task: GoogleTask) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      TaskCheckbox(done: task.isCompleted) { Task { await store.setTask(task, completed: !task.isCompleted) } }
        .accessibilityLabel(task.isCompleted ? "Mark \(task.title) not done" : "Mark \(task.title) done")
      VStack(alignment: .leading, spacing: 4) {
        Text(task.title).font(.coveBody).strikethrough(task.isCompleted).lineLimit(2)
          .foregroundStyle(task.isCompleted ? Palette.muted : Palette.ink)
        let meta = rowMeta(task)
        if !meta.isEmpty { Text(meta).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1) }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10).padding(.horizontal, 12)
    .background(selectedID == task.id ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onTapGesture { selectedID = task.id }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Show details") { selectedID = task.id }
  }
  private func rowMeta(_ task: GoogleTask) -> String {
    var parts: [String] = []
    if let due = task.dueDay, group(task) == .upcoming || group(task) == .overdue {
      parts.append(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
    }
    if let mail = store.sourceMail(for: task) { parts.append(mail.sender.isEmpty ? mail.senderEmail : mail.sender) }
    else if let person = TaskContext.people(for: task.title, contacts: store.contacts, limit: 1).first { parts.append(person.name) }
    let steps = children(of: task)
    if !steps.isEmpty { parts.append("\(steps.filter(\.isCompleted).count)/\(steps.count) steps") }
    return parts.joined(separator: " · ")
  }
  private func empty(_ text: String) -> some View {
    VStack { Text(text).font(.coveBody).foregroundStyle(Palette.body).frame(maxWidth: 460) }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension TaskQuickAdd.DayPick: Identifiable {}

/// A round checkbox that fills with a small spring when a task is completed.
struct TaskCheckbox: View {
  let done: Bool
  var size: CGFloat = 18
  let toggle: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button(action: toggle) {
      ZStack {
        Circle().strokeBorder(done ? Palette.ink : Palette.inputBorder, lineWidth: 1.5)
        Circle().fill(Palette.ink).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
        Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
          .opacity(done ? 1 : 0).scaleEffect(done ? 1 : 0.5)
      }.frame(width: size, height: size).contentShape(Circle())
    }.buttonStyle(.plain)
      .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: done)
  }
}

/// One of today's picks: why it matters, then a free slot on the calendar with one click.
private struct PlanRow: View {
  @Bindable var store: AppStore
  let number: Int
  let task: GoogleTask
  let pick: TaskQuickAdd.DayPick
  let open: () -> Void
  @State private var finding = false
  @State private var slot: DateInterval?
  @State private var added = false
  @State private var note: String?
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)").font(.coveMetadata).frame(width: 22, height: 22).background(Palette.canvas, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Button(action: open) { Text(task.title).font(.coveBody).multilineTextAlignment(.leading) }.buttonStyle(.plain)
        Text("\(pick.why) · \(pick.minutes) min").font(.coveMetadata).foregroundStyle(Palette.body)
        if let note { Text(note).font(.coveMetadata).foregroundStyle(Palette.body) }
      }
      Spacer(minLength: 8)
      if added {
        Label("On your calendar", systemImage: "checkmark").font(.coveMetadata).foregroundStyle(Palette.body)
      } else if let slot {
        Button("Add \(slot.start.formatted(date: .omitted, time: .shortened))") {
          Task {
            added = await store.createEvent(title: task.title, start: slot.start, end: slot.end,
                                            onGoogle: store.calendarConnected && !store.isSample)
            if !added { note = store.error ?? "Couldn’t add it." }
          }
        }.buttonStyle(PrimaryButton(compact: true))
      } else {
        Button(finding ? "Finding…" : "Find time") {
          finding = true
          Task {
            do {
              slot = try await store.firstFreeSlot(minutes: pick.minutes)
              if slot == nil { note = store.calendarConnected ? "No free \(pick.minutes) min today or tomorrow." : "Connect Google Calendar to find time." }
            } catch { note = error.localizedDescription }
            finding = false
          }
        }.buttonStyle(SecondaryButton(compact: true)).disabled(finding)
      }
    }
  }
}

/// One task, edited in place (saved automatically), with AI help to get it done.
struct TaskDetailView: View {
  @Bindable var store: AppStore
  let task: GoogleTask
  var subtasks: [GoogleTask] = []
  let close: () -> Void
  @State private var title = ""
  @State private var notes = ""
  @State private var due: Date?
  @State private var saveState: String?
  @State private var pickingDate = false
  @State private var loaded = false
  // AI actions
  @State private var working: String?
  @State private var steps: [String] = []
  @State private var chosenSteps: Set<String> = []
  @State private var slot: DateInterval?
  @State private var scheduled = false
  @State private var aiNote: String?
  @FocusState private var titleFocused: Bool
  private var source: Mail? { store.sourceMail(for: task) }
  private var hasModel: Bool { AIProviderSettings.shared.hasWorkingDefault }
  private var changed: Bool { title != task.title || notes != TaskDetailText.userNotes(task.notes) || due != task.dueDay }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 6) {
          Spacer()
          if let saveState { Text(saveState).font(.coveMetadata).foregroundStyle(Palette.muted).transition(.opacity) }
          if let link = task.webViewLink, let url = URL(string: link), url.scheme == "https" {
            Link(destination: url) { Image(systemName: "arrow.up.right.square").frame(width: 32, height: 36) }
              .buttonStyle(ReaderActionStyle()).help("Open in Google Tasks").accessibilityLabel("Open in Google Tasks")
          }
          Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 36) }
            .buttonStyle(ReaderActionStyle()).help("Close").accessibilityLabel("Close details")
        }
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          TaskCheckbox(done: task.isCompleted, size: 24) { Task { await store.setTask(task, completed: !task.isCompleted) } }
            .accessibilityLabel(task.isCompleted ? "Mark not done" : "Mark done")
          TextField("Task", text: $title, axis: .vertical).font(.coveTitle).textFieldStyle(.plain)
            .lineLimit(1...4).focused($titleFocused).onSubmit { save() }
            .strikethrough(task.isCompleted).accessibilityLabel("Task title")
        }
        dueChips
        TextField("Add notes…", text: $notes, axis: .vertical).font(.coveBody).textFieldStyle(.plain)
          .lineLimit(2...12).foregroundStyle(Palette.ink).accessibilityLabel("Task notes")
          .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        if !subtasks.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Steps").font(.coveLabel).foregroundStyle(Palette.body)
            ForEach(subtasks) { step in
              HStack(spacing: 10) {
                TaskCheckbox(done: step.isCompleted, size: 16) { Task { await store.setTask(step, completed: !step.isCompleted) } }
                Text(step.title).font(.coveSecondary).strikethrough(step.isCompleted)
                  .foregroundStyle(step.isCompleted ? Palette.muted : Palette.ink)
              }
            }
          }
        }
        if hasModel || store.calendarConnected { aiSection }
        if let mail = source { sourceCard(mail) }
        relatedSection
      }.padding(28).frame(maxWidth: 600, alignment: .leading)
    }
    .onAppear { reset(); loaded = true }
    .onChange(of: task) { _, _ in if saveState != "Saving…" { reset() } }
    // Autosave shortly after typing stops; the date saves at once.
    .task(id: "\(title)|\(notes)") {
      guard loaded, changed else { return }
      try? await Task.sleep(for: .milliseconds(900))
      if !Task.isCancelled { save() }
    }
    .onChange(of: due) { _, _ in if loaded && changed { save() } }
  }

  private var dueChips: some View {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let nextWeek = calendar.nextDate(after: today, matching: DateComponents(weekday: calendar.firstWeekday == 1 ? 2 : calendar.firstWeekday),
                                     matchingPolicy: .nextTime) ?? calendar.date(byAdding: .day, value: 7, to: today)!
    let presets: [(String, Date)] = [("Today", today), ("Tomorrow", tomorrow), ("Next week", nextWeek)]
    let custom = due.map { value in !presets.contains { calendar.isDate($0.1, inSameDayAs: value) } } ?? false
    return HStack(spacing: 8) {
      Image(systemName: "calendar").foregroundStyle(Palette.body).accessibilityHidden(true)
      ForEach(presets, id: \.0) { name, day in
        chip(name, selected: due.map { calendar.isDate($0, inSameDayAs: day) } ?? false) {
          due = due.map { calendar.isDate($0, inSameDayAs: day) } == true ? nil : day
        }
      }
      chip(custom ? due!.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : "Pick date", selected: custom,
           icon: custom ? nil : "chevron.down") { pickingDate = true }
        .popover(isPresented: $pickingDate) {
          DatePicker("Due date", selection: Binding(get: { due ?? tomorrow }, set: { due = calendar.startOfDay(for: $0); pickingDate = false }),
                     displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden().padding(12)
        }
      if due != nil {
        Button { due = nil } label: { Image(systemName: "xmark").font(.cove(size: 10)) }
          .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Remove due date").accessibilityLabel("Remove due date")
      }
    }
  }
  private func chip(_ title: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if let icon { Image(systemName: icon).font(.cove(size: 9)) }
      }.font(.coveControl).padding(.horizontal, 12).frame(height: 30)
        .foregroundStyle(selected ? Color.white : Palette.ink)
        .background(selected ? Palette.ink : Palette.sidebar, in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(.plain).animation(.easeOut(duration: 0.15), value: selected)
  }

  @ViewBuilder private var aiSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Get it done", systemImage: "sparkles").font(.coveLabel).foregroundStyle(Palette.body)
      if let working { WritingThinkingBar(stage: working) }
      if !steps.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(steps, id: \.self) { step in
            Toggle(step, isOn: Binding(get: { chosenSteps.contains(step) },
                                       set: { if $0 { chosenSteps.insert(step) } else { chosenSteps.remove(step) } }))
              .toggleStyle(.checkbox).font(.coveSecondary)
          }
          HStack(spacing: 12) {
            Button(chosenSteps.count == 1 ? "Add step" : "Add \(chosenSteps.count) steps") {
              let picked = steps.filter { chosenSteps.contains($0) }
              working = "Adding steps…"
              Task { _ = await store.addSubtasks(picked, under: task); steps = []; working = nil }
            }.buttonStyle(PrimaryButton(compact: true)).disabled(chosenSteps.isEmpty || working != nil)
            Button("Not now") { steps = [] }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
          }
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
      }
      if let slot, !scheduled {
        HStack(spacing: 12) {
          Image(systemName: "calendar.badge.clock").foregroundStyle(Palette.body)
          Text(slotText(slot)).font(.coveSecondary)
          Spacer(minLength: 8)
          Button("Add to calendar") {
            Task {
              scheduled = await store.createEvent(title: task.title, start: slot.start, end: slot.end,
                                                  onGoogle: store.calendarConnected && !store.isSample)
              if !scheduled { aiNote = store.error ?? "Couldn’t add it to your calendar." }
            }
          }.buttonStyle(PrimaryButton(compact: true))
          Button("Not now") { self.slot = nil }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
      }
      if scheduled, let slot { Label("Blocked \(slotText(slot))", systemImage: "checkmark").font(.coveSecondary).foregroundStyle(Palette.body) }
      if let aiNote { Text(aiNote).font(.coveMetadata).foregroundStyle(Palette.body) }
      if working == nil && steps.isEmpty && (slot == nil || scheduled) {
        HStack(spacing: 8) {
          if hasModel, let mail = source {
            aiButton(task.isCompleted ? "Tell \(firstName(mail)) it’s done" : "Draft a reply", "arrowshape.turn.up.left") { draftReply() }
          }
          if hasModel && subtasks.isEmpty { aiButton("Break into steps", "list.bullet.indent") { suggestSteps() } }
          if store.calendarConnected && !task.isCompleted && !scheduled { aiButton("Find time", "calendar.badge.clock") { findTime() } }
        }
      }
    }
  }
  private func aiButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon).font(.coveControl).lineLimit(1).padding(.horizontal, 12).frame(height: 34)
        .background(Palette.surface, in: Capsule()).contentShape(Capsule())
    }.buttonStyle(.plain).foregroundStyle(Palette.ink)
  }
  private func firstName(_ mail: Mail) -> String {
    String((mail.sender.isEmpty ? mail.senderEmail : mail.sender).split(separator: " ").first ?? "them")
  }
  private func slotText(_ slot: DateInterval) -> String {
    let day = Calendar.current.isDateInToday(slot.start) ? "Today" : "Tomorrow"
    return "\(day) \(slot.start.formatted(date: .omitted, time: .shortened))–\(slot.end.formatted(date: .omitted, time: .shortened))"
  }
  private func draftReply() {
    working = "Writing your reply…"; aiNote = nil
    Task {
      do {
        let mail = try await store.draftReply(for: task) { try await AIProviderSettings.shared.complete($0) }
        store.chooseFolder(mail.labels.contains("SENT") ? "Sent" : "Inbox")
        store.selectedID = mail.id
        store.screen = "mail"
      } catch { aiNote = error.localizedDescription }
      working = nil
    }
  }
  private func suggestSteps() {
    working = "Breaking it into steps…"; aiNote = nil
    Task {
      do {
        steps = try await store.suggestSteps(for: task) { try await AIProviderSettings.shared.complete($0) }
        chosenSteps = Set(steps)
        if steps.isEmpty { aiNote = "No clear steps for this one." }
      } catch { aiNote = error.localizedDescription }
      working = nil
    }
  }
  private func findTime() {
    working = "Looking at your calendar…"; aiNote = nil
    Task {
      do {
        slot = try await store.firstFreeSlot(minutes: 30)
        if slot == nil { aiNote = "No free 30 minutes today or tomorrow." }
      } catch { aiNote = error.localizedDescription }
      working = nil
    }
  }

  /// People, latest emails and meetings the task is about, found locally from its title.
  @ViewBuilder private var relatedSection: some View {
    let related = store.relatedContext(for: task)
    if !related.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text(source == nil ? "Related" : "More context").font(.coveLabel).foregroundStyle(Palette.body)
        ForEach(related.people) { person in
          HStack(spacing: 12) {
            CoveAvatar(initials: person.initials.isEmpty ? String(person.email.prefix(1)).uppercased() : person.initials, size: 32)
            VStack(alignment: .leading, spacing: 2) {
              Text(person.name).font(.coveLabel)
              Text([person.email, person.record?.phone ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.coveMetadata).foregroundStyle(Palette.body).textSelection(.enabled).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let phone = person.record?.phone, !phone.isEmpty,
              let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
              Link(destination: url) { Image(systemName: "phone").frame(width: 32, height: 32) }
                .buttonStyle(ReaderActionStyle()).help("Call \(phone)").accessibilityLabel("Call \(person.name)")
            }
            Button { store.composeEmail(to: person, about: task) } label: {
              Image(systemName: "square.and.pencil").frame(width: 32, height: 32)
            }.buttonStyle(ReaderActionStyle()).help("Email \(person.name)").accessibilityLabel("Email \(person.name)")
          }
        }
        ForEach(related.events) { event in
          Label("\(event.title) · \(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))",
                systemImage: "calendar").font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(1)
        }
        if !related.mails.isEmpty {
          VStack(spacing: 0) {
            ForEach(Array(related.mails.enumerated()), id: \.element.id) { index, mail in
              if index > 0 { Divider() }
              HStack(spacing: 10) {
                Button { open(mail) } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveSecondary).lineLimit(1)
                    Text("\(mail.labels.contains("SENT") ? "You" : (mail.sender.isEmpty ? mail.senderEmail : mail.sender)) · \(mail.date.formatted(.dateTime.month(.abbreviated).day()))")
                      .font(.coveMetadata).foregroundStyle(Palette.body)
                  }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open email")
                if source == nil {
                  Button("Link") { Task { await store.linkTask(task, to: mail) } }
                    .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
                    .help("Make this the task’s email; the link syncs to Google Tasks")
                }
              }.padding(.horizontal, 12).padding(.vertical, 9)
            }
          }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
      }
    }
  }
  private func open(_ mail: Mail) {
    store.chooseFolder(mail.labels.contains("SENT") ? "Sent" : "Inbox")
    store.selectedID = mail.id
    store.screen = "mail"
  }

  private func sourceCard(_ mail: Mail) -> some View {
    Button {
      store.chooseFolder(mail.labels.contains("SENT") ? "Sent" : "Inbox")
      store.selectedID = mail.id
      store.screen = "mail"
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: mail.labels.contains("SENT") ? "paperplane" : "envelope").foregroundStyle(Palette.body).padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveLabel).lineLimit(1)
          Text("\(mail.sender.isEmpty ? mail.senderEmail : mail.sender) · \(mail.date.formatted(date: .abbreviated, time: .omitted))")
            .font(.coveMetadata).foregroundStyle(Palette.body)
          Text(String(mail.body.prefix(220))).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(3)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.right").font(.cove(size: 11)).foregroundStyle(Palette.muted)
      }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }.buttonStyle(.plain).help("Open email").accessibilityLabel("Open the email: \(mail.subject)")
  }

  private func save() {
    guard changed, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    saveState = "Saving…"
    let fullNotes = ([notes] + TaskDetailText.cove(task.notes)).filter { !$0.isEmpty }.joined(separator: "\n")
    Task {
      let ok = await store.updateTask(task, title: title, notes: fullNotes, due: due)
      withAnimation { saveState = ok ? "Saved" : "Not saved" }
      try? await Task.sleep(for: .seconds(1.5))
      withAnimation { if saveState == "Saved" { saveState = nil } }
    }
  }
  private func reset() {
    title = task.title
    notes = TaskDetailText.userNotes(task.notes)
    due = task.dueDay
  }
}


/// Finished tasks per day as the Home tide's point cloud: busier days rise higher.
struct TaskMomentumView: View {
  let counts: [Int]
  var previewTime: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  private static let colors: [Color] = [
    Color(red: 0.47, green: 0.85, blue: 0.79), Color(red: 0.54, green: 0.73, blue: 0.94),
    Color(red: 0.73, green: 0.63, blue: 0.93), Color(red: 0.95, green: 0.74, blue: 0.55),
  ]
  private var animated: Bool { previewTime == nil && !reduceMotion && scenePhase == .active && counts.contains { $0 > 0 } }
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animated)) { timeline in
      let time = previewTime ?? (animated ? timeline.date.timeIntervalSinceReferenceDate : 0)
      Canvas { context, size in
        for layer in MailTideGeometry.dots(counts: counts, width: size.width, height: size.height, time: time) {
          var path = Path()
          for dot in layer {
            path.addEllipse(in: CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2))
          }
          context.opacity = layer.first?.opacity ?? 1
          context.fill(path, with: .linearGradient(Gradient(colors: Self.colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
      }
    }.accessibilityElement().accessibilityLabel("\(counts.reduce(0, +)) tasks finished in the last two weeks")
  }
}
