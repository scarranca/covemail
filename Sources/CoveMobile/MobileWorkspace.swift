#if os(iOS)
import CoveCore
import Foundation
import Observation

/// Google Calendar and Google Tasks on iPhone, through the same clients as the Mac
/// (`GoogleCalendarClient`, `GoogleTasksClient`). Nothing is created, moved or answered without an
/// explicit tap; failures stay visible next to the list they belong to.
@MainActor @Observable final class MobileWorkspace {
  private(set) var events: [LocalEvent] = []
  /// The loaded range, so moving between nearby days doesn't refetch.
  private(set) var eventRange: Range<Date>?
  private(set) var loadingEvents = false
  var eventsError: String?
  private(set) var tasks: [GoogleTask] = []
  private(set) var completedRecently: [GoogleTask] = []
  private(set) var loadingTasks = false
  var tasksError: String?
  /// Events with an answer on its way to Google.
  private(set) var responding: Set<String> = []

  let auth: MobileAuth
  private let calendar = GoogleCalendarClient()
  private let tasksClient = GoogleTasksClient()

  init(auth: MobileAuth) { self.auth = auth }

  func reset() {
    events = []
    eventRange = nil
    tasks = []
    completedRecently = []
    eventsError = nil
    tasksError = nil
  }

  // MARK: Calendar

  /// Loads the six weeks around `date` (the Mac's month grid covers 42 days).
  func loadEvents(around date: Date = Date(), force: Bool = false) async {
    let day = Calendar.current.startOfDay(for: date)
    let start = Calendar.current.date(byAdding: .day, value: -14, to: day) ?? day
    let end = Calendar.current.date(byAdding: .day, value: 28, to: day) ?? day
    if !force, let eventRange, eventRange.contains(day), eventRange.contains(end.addingTimeInterval(-1)) { return }
    if auth.isSample { loadSampleEvents(); return }
    guard auth.calendarConnected, !loadingEvents else { return }
    loadingEvents = true
    defer { loadingEvents = false }
    do {
      let token = try await auth.token()
      events = try await calendar.events(token: token, from: start, to: end)
        .sorted { $0.start < $1.start }
      eventRange = start..<end
      eventsError = nil
    } catch is CancellationError {
    } catch {
      eventsError = "Couldn’t load Calendar. " + error.localizedDescription
    }
  }

  func events(on day: Date) -> [LocalEvent] { CalendarAgenda.events(events, on: day) }

  var pendingInvitations: [LocalEvent] {
    events.filter { $0.isPendingInvitation && $0.end > Date() }
  }

  var nextMeeting: LocalEvent? {
    let now = Date()
    return events.filter { $0.end > now && $0.ownResponse != "declined" && $0.allDay != true }.min { $0.start < $1.start }
  }

  /// Answers an invitation. Only an explicit Accept / Maybe / Decline tap calls this.
  func respond(_ event: LocalEvent, _ answer: CalendarRSVP) async {
    guard let id = event.googleID, !responding.contains(event.id) else { return }
    responding.insert(event.id)
    defer { responding.remove(event.id) }
    do {
      let token = try await auth.token()
      let updated = try await calendar.respond(token: token, id: id, response: answer)
      if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = updated }
      eventsError = nil
    } catch {
      eventsError = "Couldn’t answer the invitation. " + error.localizedDescription
    }
  }

  // MARK: Tasks

  var openTasks: [GoogleTask] { tasks.filter { !$0.isCompleted && $0.parent == nil } }
  func steps(of task: GoogleTask) -> [GoogleTask] {
    tasks.filter { $0.parent == task.id }.sorted { ($0.position ?? "") < ($1.position ?? "") }
  }

  func loadTasks() async {
    if auth.isSample { loadSampleTasks(); return }
    guard auth.tasksConnected, !loadingTasks else { return }
    loadingTasks = true
    defer { loadingTasks = false }
    do {
      let token = try await auth.token()
      tasks = try await tasksClient.list(token: token, includeCompleted: true)
      let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
      completedRecently = (try? await tasksClient.completed(token: token, since: since)) ?? []
      tasksError = nil
    } catch is CancellationError {
    } catch {
      tasksError = "Couldn’t load Google Tasks. " + error.localizedDescription
    }
  }

  /// "Call Millet Friday" → a task named "Call Millet", due Friday (the Mac's quick add).
  func addTask(_ text: String) async -> Bool {
    let parsed = TaskQuickAdd.parse(text)
    guard !parsed.title.isEmpty else { return false }
    if auth.isSample {
      tasks.insert(GoogleTask(id: UUID().uuidString, title: parsed.title, due: parsed.due.map(Self.dueString), status: "needsAction"), at: 0)
      return true
    }
    do {
      let token = try await auth.token()
      let task = try await tasksClient.create(title: parsed.title, notes: nil, due: parsed.due, token: token)
      tasks.insert(task, at: 0)
      tasksError = nil
      return true
    } catch {
      tasksError = "Couldn’t add the task. " + error.localizedDescription
      return false
    }
  }

  /// A follow-up task for an email, with a link back to its Gmail thread in the notes (as on the Mac).
  /// Only an explicit "Create task" tap calls this.
  func createTask(from mail: Mail, accountEmail: String) async -> Bool {
    let suggestion = TaskDetection.fallback(for: mail, accountEmail: accountEmail)
    if auth.isSample {
      tasks.insert(GoogleTask(id: UUID().uuidString, title: suggestion.title, status: "needsAction"), at: 0)
      return true
    }
    do {
      let token = try await auth.token()
      let task = try await tasksClient.create(title: suggestion.title, notes: TaskDetection.notes(for: suggestion, mail: mail),
                                              due: nil, token: token)
      tasks.insert(task, at: 0)
      tasksError = nil
      return true
    } catch {
      tasksError = "Couldn’t create the task. " + error.localizedDescription
      return false
    }
  }

  /// Open tasks that came from this email's conversation.
  func tasks(for mail: Mail) -> [GoogleTask] {
    guard !mail.threadID.isEmpty else { return [] }
    return openTasks.filter { TaskDetection.threadID(inNotes: $0.notes) == mail.threadID }
  }

  /// Marks done (or not) on the phone first; Google's answer replaces it, or a failure puts it back.
  func setCompleted(_ task: GoogleTask, _ done: Bool) async {
    guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
    let previous = tasks[index]
    tasks[index].status = done ? "completed" : "needsAction"
    if auth.isSample { return }
    do {
      let token = try await auth.token()
      let updated = try await tasksClient.setCompleted(previous, completed: done, token: token)
      if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = updated }
      if done { completedRecently.insert(updated, at: 0) } else { completedRecently.removeAll { $0.id == task.id } }
    } catch {
      if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = previous }
      tasksError = "Couldn’t update the task. " + error.localizedDescription
    }
  }

  private static func dueString(_ day: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02dT00:00:00.000Z", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
  }

  // MARK: Sample (screenshots and design checks only)

  private func loadSampleEvents() {
    let today = Calendar.current.startOfDay(for: Date())
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
      Calendar.current.date(byAdding: .minute, value: day * 1440 + hour * 60 + minute, to: today) ?? today
    }
    var standup = LocalEvent(title: "Team standup", start: at(0, 9, 30), end: at(0, 9, 45))
    standup.googleID = "sample-1"; standup.meetURL = "https://meet.google.com/sample"
    var review = LocalEvent(title: "Design review · Cove for iPhone", start: at(0, 14), end: at(0, 15))
    review.googleID = "sample-2"; review.location = "Studio"
    var lunch = LocalEvent(title: "Lunch with Millet", start: at(1, 13), end: at(1, 14))
    lunch.googleID = "sample-3"
    var invite = LocalEvent(title: "Quarterly planning", start: at(2, 11), end: at(2, 12))
    invite.googleID = "sample-4"; invite.isOrganizer = false
    invite.attendees = [CalendarAttendee(name: "Alex", email: "alex@example.com", response: "needsAction", isSelf: true)]
    events = [standup, review, lunch, invite]
    eventRange = at(-14, 0)..<at(28, 0)
  }

  private func loadSampleTasks() {
    let today = Calendar.current.startOfDay(for: Date())
    tasks = [
      GoogleTask(id: "t1", title: "Send the signed proposal to Millet", due: Self.dueString(today), status: "needsAction"),
      GoogleTask(id: "t2", title: "Review the iPhone onboarding copy",
                 due: Self.dueString(Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today), status: "needsAction"),
      GoogleTask(id: "t3", title: "Book flights for the offsite", status: "needsAction"),
    ]
  }
}
#endif
