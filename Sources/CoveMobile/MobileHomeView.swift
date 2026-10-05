#if os(iOS)
import CoveCore
import SwiftUI

/// Home, as the Mac's Agent Hub in its compact order: the night-blue briefing with the mail tide, then
/// what needs a decision, today's agenda and invitations, possible follow-ups and tasks due.
struct MobileHomeView: View {
  let auth: MobileAuth
  let mailbox: MobileMailbox
  let workspace: MobileWorkspace
  let ai: MobileAI
  @Binding var tab: MobileTab
  @State private var path: [String] = []
  @State private var showSettings = false
  @State private var showAssistant = false
  @State private var composing = false
  @State private var showContacts = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var showModelSample = false
  @State private var sampleModel = "anthropic/claude-sonnet-4.5"
  @State private var draft: MobileDraft?
  /// People the user chose not to see in Keep in touch (this iPhone only), with Undo for the last one.
  @AppStorage("home.ignoredKeepInTouch") private var ignoredStorage = ""
  @State private var lastIgnored: String?
  private var ignored: Set<String> { Set(ignoredStorage.split(separator: "\n").map(String.init)) }
  private var keepInTouch: [Mail] {
    Array(KeepInTouch.candidates(mails: mailbox.allLoaded, accountEmail: account, now: Date(), ignored: ignored).prefix(3))
  }

  private var account: String { auth.email ?? "" }
  private var priorities: [Mail] { mailbox.inbox.filter(\.isPriority) }
  private var waiting: [Mail] { HomeBriefing.awaitingReplies(mails: mailbox.allLoaded, accountEmail: account, now: Date()) }
  private var today: [LocalEvent] { workspace.events(on: Date()).filter { $0.ownResponse != "declined" } }
  private var dueTasks: [GoogleTask] {
    let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
    return workspace.openTasks.filter { ($0.dueDay ?? .distantFuture) < end }
  }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          header
          MobileSetupCard(auth: auth, ai: ai, showSettings: $showSettings)
          banner
          if wide {
            // The Mac's hub columns: decisions and people on the left, the day on the right.
            HStack(alignment: .top, spacing: 28) {
              VStack(alignment: .leading, spacing: 26) {
                prioritySection
                if !waiting.isEmpty { waitingSection }
                if !keepInTouch.isEmpty || lastIgnored != nil { keepInTouchSection }
              }.frame(maxWidth: .infinity, alignment: .leading)
              VStack(alignment: .leading, spacing: 26) {
                if auth.calendarConnected { todaySection }
                if !workspace.pendingInvitations.isEmpty { invitationsSection }
                if auth.tasksConnected { tasksSection }
              }
              .padding(.leading, 25).frame(width: 340, alignment: .leading)
              .overlay(alignment: .leading) { Rectangle().fill(MobilePalette.line).frame(width: 1) }
            }
          } else {
            prioritySection
            if auth.calendarConnected { todaySection }
            if !workspace.pendingInvitations.isEmpty { invitationsSection }
            if !waiting.isEmpty { waitingSection }
            if !keepInTouch.isEmpty || lastIgnored != nil { keepInTouchSection }
            if auth.tasksConnected { tasksSection }
          }
        }
        .padding(.horizontal, wide ? 32 : 20).padding(.top, 8).padding(.bottom, 40)
        .frame(maxWidth: wide ? 1240 : 860).frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      }
      .background(MobilePalette.canvas)
      .refreshable {
        async let mail: Void = mailbox.sync()
        async let events: Void = workspace.loadEvents(force: true)
        async let tasks: Void = workspace.loadTasks()
        _ = await (mail, events, tasks)
      }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: String.self) { id in
        MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
      }
      .sheet(isPresented: $showSettings) {
        MobileSettingsView(auth: auth, mailbox: mailbox, workspace: workspace, ai: ai)
      }
      .sheet(isPresented: $showAssistant) {
        MobileAssistantView(ai: ai, mailbox: mailbox, workspace: workspace) { id in
          showAssistant = false
          path.append(id)
        }
      }
      .sheet(isPresented: $composing) { MobileComposeView(mailbox: mailbox, ai: ai, draft: .init()) }
      .sheet(item: $draft) { draft in MobileComposeView(mailbox: mailbox, ai: ai, draft: draft) }
      #if DEBUG
      .sheet(isPresented: $showModelSample) {
        MobileModelList(title: "OpenRouter", models: ["anthropic/claude-sonnet-4.5", "anthropic/claude-haiku-4.5", "openai/gpt-5.1",
          "openai/gpt-5.1-mini", "google/gemini-3-pro-preview", "meta/muse-spark-1.3-contributor", "mistralai/mistral-large-2512",
          "deepseek/deepseek-v3.2-exp", "x-ai/grok-4.1-fast"], selection: $sampleModel)
      }
      #endif
      .sheet(isPresented: $showContacts) { MobileContactsView(mailbox: mailbox, ai: ai, workspace: workspace) }
      #if DEBUG
      .onAppear {
        // Screenshot checks: `-CoveSettings` and `-CoveAssistant` open those sheets.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CoveSettings") { showSettings = true }
        if arguments.contains("-CoveAssistant") { showAssistant = true }
        if arguments.contains("-CoveContacts") { showContacts = true }
        if arguments.contains("-CoveModelList") { showModelSample = true }
      }
      #endif
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      // On iPad the sidebar already shows the wordmark.
      if sizeClass == .regular { Text("Home").font(.mobileTitle) } else { MobileWordmark(size: 22) }
      Spacer()
      Button { showContacts = true } label: { Image(systemName: "person.crop.rectangle") }
        .buttonStyle(MobileIconButton()).accessibilityLabel("Contacts")
      Button { composing = true } label: { Image(systemName: "square.and.pencil") }
        .buttonStyle(MobileIconButton()).accessibilityLabel("New message")
      Button { showSettings = true } label: { MobileAvatar(name: account, size: 32) }
        .buttonStyle(.plain).accessibilityLabel("Settings and account")
    }
  }

  // MARK: Briefing

  private var greeting: String { auth.isSample ? "A little head start, Alex." : "A little head start." }
  private var briefing: String {
    let attention = priorities.isEmpty ? "A little more room to focus."
      : "\(priorities.count) \(priorities.count == 1 ? "decision" : "decisions") to move things forward."
    guard let event = workspace.nextMeeting else { return attention + "\nYour next clear moment starts here." }
    let time = Calendar.current.isDateInToday(event.start)
      ? event.start.formatted(date: .omitted, time: .shortened)
      : event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return attention + "\n" + (event.start <= Date() ? "Your meeting is underway." : "Your next meeting is at \(time).")
  }

  /// iPad at full width: the Mac's layouts (side-by-side banner, hub columns).
  private var wide: Bool { sizeClass == .regular && width >= 900 }
  /// The page's actual width (iPad portrait leaves ~740 pt beside the sidebar; landscape ~1100).
  @State private var width: CGFloat = 0

  private var banner: some View {
    let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
    return layout {
      VStack(alignment: .leading, spacing: 12) {
        Text(greeting).font(.mobileTitle).foregroundStyle(MobilePalette.nightText)
          .fixedSize(horizontal: false, vertical: true)
        Text(briefing).font(.mobileText).foregroundStyle(MobilePalette.nightSecondary).lineSpacing(5)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          if !workspace.pendingInvitations.isEmpty {
            nightTag("\(workspace.pendingInvitations.count) \(workspace.pendingInvitations.count == 1 ? "invitation" : "invitations")", warm: true)
          }
          if !dueTasks.isEmpty { nightTag("\(dueTasks.count) due today") }
        }
        Button { showAssistant = true } label: { Label("Ask Cove", systemImage: "sparkles") }
          .buttonStyle(MobileSecondaryButton(compact: true))
      }.frame(maxWidth: wide ? 400 : .infinity, alignment: .leading)
      MobileTideView(tide: MailTide(mails: mailbox.allLoaded, now: Date())).frame(maxWidth: .infinity)
    }
    .padding(wide ? 26 : 22).frame(minHeight: wide ? 260 : nil)
    .background(MobilePalette.night, in: RoundedRectangle(cornerRadius: 10))
  }

  private func nightTag(_ text: String, warm: Bool = false) -> some View {
    Text(text).font(.mobileCaption)
      .foregroundStyle(warm ? MobilePalette.warm : Color(white: 0.87))
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
  }

  // MARK: Sections

  private var prioritySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Needs your decision", detail: "\(priorities.count) \(priorities.count == 1 ? "message" : "messages")")
      if priorities.isEmpty {
        Text(mailbox.inbox.isEmpty ? "Your inbox is empty." : "Nothing needs a decision right now.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
        Button("Open Mail") { tab = .mail }.buttonStyle(MobileSecondaryButton(compact: true))
      } else {
        VStack(spacing: 0) {
          ForEach(Array(priorities.prefix(4))) { mail in
            Button { path.append(mail.id) } label: { homeMailRow(mail) }.buttonStyle(MobileRowButtonStyle())
            if mail.id != priorities.prefix(4).last?.id { Divider().overlay(MobilePalette.line) }
          }
        }
        .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        if priorities.count > 4 {
          Button("See all in Mail") { tab = .mail }.font(.mobileControl).foregroundStyle(MobilePalette.body)
        }
      }
    }
  }

  private func homeMailRow(_ mail: Mail) -> some View {
    HStack(alignment: .top, spacing: 12) {
      MobileAvatar(mail: mail, size: 34)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
          Spacer()
          Text(MobileDates.short(mail.date)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }
        Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveMobile(14, weight: .semibold))
          .foregroundStyle(MobilePalette.ink).lineLimit(1)
        Text(mail.decision?.excerpt ?? String(mail.body.prefix(140)).replacingOccurrences(of: "\n", with: " "))
          .font(.mobileSecondary).foregroundStyle(MobilePalette.body).lineLimit(2)
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }

  private var todaySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Today", detail: Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
      if today.isEmpty {
        Text(workspace.loadingEvents ? "Checking your calendar…" : "No events today.").font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
      } else {
        VStack(spacing: 8) {
          ForEach(today) { event in MobileEventRow(event: event) }
        }
      }
      if let error = workspace.eventsError { Text(error).font(.mobileMetadata).foregroundStyle(MobilePalette.danger) }
      Button("Open Calendar") { tab = .calendar }.font(.mobileControl).foregroundStyle(MobilePalette.body)
    }
  }

  private var invitationsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Invitations", detail: "\(workspace.pendingInvitations.count) waiting")
      ForEach(workspace.pendingInvitations) { event in MobileInvitationCard(event: event, workspace: workspace) }
    }
  }

  private var waitingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Waiting on replies", detail: "Sent, no answer yet")
      VStack(spacing: 0) {
        ForEach(Array(waiting.prefix(3))) { mail in
          Button { path.append(mail.id) } label: {
            HStack(spacing: 12) {
              MobileAvatar(name: HomeBriefing.recipientNames(mail), size: 30)
              VStack(alignment: .leading, spacing: 2) {
                Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
                Text("To \(HomeBriefing.recipientNames(mail)) · \(MobileDates.short(mail.date))")
                  .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
              }
              Spacer()
            }.padding(12).contentShape(Rectangle())
          }.buttonStyle(MobileRowButtonStyle())
          if mail.id != waiting.prefix(3).last?.id { Divider().overlay(MobilePalette.line) }
        }
      }
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
    }
  }

  private var keepInTouchSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Keep in touch", detail: "People you haven’t written to lately")
      ForEach(keepInTouch) { mail in
        HStack(spacing: 12) {
          MobileAvatar(mail: mail, size: 34)
          VStack(alignment: .leading, spacing: 2) {
            Text(mail.sender.isEmpty ? mail.senderEmail : mail.sender).font(.mobileLabel).foregroundStyle(MobilePalette.ink).lineLimit(1)
            Text("Last heard \(MobileDates.short(mail.date)) · \(mail.subject)").font(.mobileMetadata)
              .foregroundStyle(MobilePalette.muted).lineLimit(1)
          }
          Spacer(minLength: 6)
          Button("Ignore") {
            let email = ContactDirectory.normalizedEmail(mail.senderEmail)
            ignoredStorage = (ignored.union([email])).sorted().joined(separator: "\n")
            lastIgnored = email
          }.font(.mobileControl).foregroundStyle(MobilePalette.muted)
          Button {
            var note = MobileDraft()
            note.to = mail.senderEmail
            draft = note
          } label: { Image(systemName: "envelope") }
            .buttonStyle(MobileSecondaryButton(compact: true)).accessibilityLabel("Email \(mail.sender)")
        }
      }
      if let lastIgnored {
        HStack {
          Text("\(lastIgnored) won’t appear here.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
          Button("Undo") {
            ignoredStorage = ignored.subtracting([lastIgnored]).sorted().joined(separator: "\n")
            self.lastIgnored = nil
          }.font(.mobileControl).foregroundStyle(MobilePalette.ink)
        }
      }
    }
  }

  private var tasksSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: "Tasks", detail: "\(workspace.openTasks.count) open")
      if dueTasks.isEmpty {
        Text("Nothing due today.").font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
      } else {
        ForEach(dueTasks.prefix(4)) { task in MobileTaskRow(task: task, workspace: workspace) }
      }
      Button("Open Tasks") { tab = .tasks }.font(.mobileControl).foregroundStyle(MobilePalette.body)
    }
  }
}

/// What's left to connect, like the Mac's Home checklist. It disappears once everything is set up.
struct MobileSetupCard: View {
  let auth: MobileAuth
  let ai: MobileAI
  @Binding var showSettings: Bool
  @State private var connecting = false
  @State private var error: String?

  var body: some View {
    if !auth.isSample, !(auth.calendarConnected && auth.tasksConnected && ai.ready) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Finish setting up Cove").font(.mobileSection)
        step("Gmail", done: true, detail: auth.email ?? "")
        step("Calendar and Tasks", done: auth.calendarConnected && auth.tasksConnected,
             detail: auth.calendarConnected && auth.tasksConnected ? "Connected" : "Your agenda, invitations and Google Tasks")
        step("Writing and Ask Cove", done: ai.ready,
             detail: ai.ready ? ai.modelLabel(ai.model(ai.provider), provider: ai.provider) : "Apple Intelligence or your own API key")
        HStack(spacing: 10) {
          if !(auth.calendarConnected && auth.tasksConnected) {
            Button {
              connecting = true
              error = nil
              Task {
                do { try await auth.signIn(hint: auth.email) } catch { self.error = error.localizedDescription }
                connecting = false
              }
            } label: { Text(connecting ? "Connecting…" : "Connect Calendar & Tasks") }
              .buttonStyle(MobilePrimaryButton(compact: true)).disabled(connecting)
          }
          if !ai.ready {
            Button("Set up AI") { showSettings = true }.buttonStyle(MobileSecondaryButton(compact: true))
          }
        }
        if let error { Text(error).font(.mobileMetadata).foregroundStyle(MobilePalette.danger) }
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
    }
  }

  private func step(_ title: String, done: Bool, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
        .foregroundStyle(done ? MobilePalette.ink : MobilePalette.inputBorder)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.mobileLabel)
        Text(detail).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
      }
    }
  }
}

// MARK: Mail tide

/// The Mac's point-cloud chart of received mail over the last seven days (`MailTideView`).
struct MobileTideView: View {
  let tide: MailTide
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedDay: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("\(tide.total) emails received").font(.mobileSubheading)
        Spacer()
        Text("Last 7 days · downloaded").font(.mobileMetadata).foregroundStyle(Color(white: 0.83))
      }
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active || tide.total == 0)) { context in
        let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        Canvas { context, size in
          for layer in Self.dots(counts: tide.days.map(\.count), width: size.width, height: size.height, time: time) {
            var path = Path()
            for dot in layer {
              path.addEllipse(in: CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2))
            }
            context.opacity = layer.first?.opacity ?? 1
            context.fill(path, with: .linearGradient(Gradient(colors: MobilePalette.tide), startPoint: .zero,
                                                     endPoint: CGPoint(x: size.width, y: 0)))
          }
        }
      }.frame(height: 96).accessibilityHidden(true)
      HStack(spacing: 0) {
        ForEach(tide.days) { day in
          Button { selectedDay = selectedDay == day.date ? nil : day.date } label: {
            VStack(spacing: 3) {
              Text("\(day.count)").font(.mobileCaption).monospacedDigit()
              Text(day.date, format: .dateTime.weekday(.narrow)).font(.mobileMetadata).foregroundStyle(Color(white: 0.83))
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
              .background(selectedDay == day.date ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
          }.buttonStyle(.plain)
            .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)): \(day.count) received emails")
        }
      }
      if let day = tide.days.first(where: { $0.date == selectedDay }) {
        Text("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.count) received in downloaded mail")
          .font(.mobileMetadata).foregroundStyle(Color(white: 0.83))
      }
    }.foregroundStyle(MobilePalette.nightText)
  }

  struct Dot { let x: Double; let y: Double; let r: Double; let opacity: Double }

  /// Same geometry as the Mac's `MailTideGeometry`: 14 layers shaped by the seven daily counts, with a
  /// slow ripple of at most 1.6 points.
  static func dots(counts: [Int], width: Double, height: Double, time: Double) -> [[Dot]] {
    guard width > 0, height > 0, !counts.isEmpty else { return [] }
    let maximum = Double(max(counts.max() ?? 0, 1))
    let empty = counts.allSatisfy { $0 == 0 }
    let columns = max(2, Int(width / 3.7))
    return (0..<(empty ? 1 : 14)).map { layer in
      let depth = Double(layer) / 13
      return (0..<columns).map { column in
        let x = Double(column) / Double(columns - 1)
        let position = min(Double(counts.count - 1), max(0, x * Double(counts.count) - 0.5))
        let index = min(counts.count - 1, Int(position))
        let next = min(counts.count - 1, index + 1)
        let fraction = position - Double(index)
        let smooth = fraction * fraction * (3 - 2 * fraction)
        let volume = (Double(counts[index]) * (1 - smooth) + Double(counts[next]) * smooth) / maximum
        let ripple = empty ? 0 : sin(x * .pi * 5 - time * .pi / 7 + depth * 2.4) * 1.6
        let ridge = height * (0.82 - volume * 0.63)
        let y = ridge + depth * (height * 0.90 - ridge) * 0.64 + ripple
        return Dot(x: 2 + x * max(0, width - 4), y: y, r: layer == 0 ? 0.82 : 0.65,
                   opacity: layer == 0 ? 0.95 : max(0.1, 0.66 * pow(1 - depth, 1.3)))
      }
    }
  }
}
#endif
