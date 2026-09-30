import CoveCore
import SwiftUI

struct AgentHubView: View {
  @Bindable var store: AppStore
  var loadLiveData = true
  @Environment(\.scenePhase) private var scenePhase
  @State private var weather: HomeWeatherController
  @State private var showAllFiles = false
  @State private var lastIgnored: String?
  @State private var showExtras = false
  @State private var showActivity = false

  init(store: AppStore, loadLiveData: Bool = true, weather: HomeWeatherController? = nil) {
    self.store = store
    self.loadLiveData = loadLiveData
    _weather = State(initialValue: weather ?? HomeWeatherController(defaults: loadLiveData ? .standard : UserDefaults(suiteName: "Cove-Weather-Preview-" + UUID().uuidString)!))
  }

  private var mail: [Mail] {
    store.mails.filter { !store.queuedTrashIDs.contains($0.id) && !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM") }
  }
  private var inbox: [Mail] {
    mail.filter {
      $0.labels.contains("INBOX") && ($0.snoozedUntil ?? .distantPast) <= store.now
    }.sorted { $0.date > $1.date }
  }
  private var priorities: [Mail] {
    let pending = Set(store.customAgents.runs.filter { $0.replySuggestion != nil && $0.replyApplied != true }.map(\.mailID))
    return inbox.filter { $0.isPriority || pending.contains($0.id) }
  }
  private var waiting: [Mail] { HomeBriefing.awaitingReplies(mails: mail, accountEmail: store.accountEmail, now: store.now) }
  private var nextMeeting: LocalEvent? {
    store.events.filter { $0.end > store.now && $0.ownResponse != "declined" && $0.allDay != true }
      .sorted { $0.start < $1.start }.first
  }
  private var tide: MailTide { MailTide(mails: mail, now: store.now) }
  private var tideLabels: [(name: String, count: Int)] {
    store.agentMailCategories.compactMap { category in
      guard let label = category.label else { return nil }
      let count = tide.received.filter { $0.labels.contains(label.id) }.count
      return count > 0 ? (name: category.name, count: count) : nil
    }.sorted { $0.count > $1.count }
  }
  private var files: [HubFile] {
    mail.sorted { $0.date > $1.date }.flatMap { message in
      message.availableAttachments.map { HubFile(message: message, attachment: $0) }
    }
  }
  private var contacts: [Mail] {
    KeepInTouch.candidates(mails: mail, accountEmail: store.accountEmail, now: store.now, ignored: store.ignoredKeepInTouch)
  }
  private var greeting: String {
    if store.isSample { return "A little head start, Alex." }
    return "A little head start."
  }
  private var briefing: String {
    let attention = priorities.isEmpty ? "A little more room to focus." : "\(priorities.count) \(priorities.count == 1 ? "decision" : "decisions") to move things forward."
    guard let event = nextMeeting else { return attention + "\nYour next clear moment starts here." }
    let time = Calendar.current.isDate(event.start, inSameDayAs: store.now)
      ? event.start.formatted(date: .omitted, time: .shortened)
      : event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return attention + "\n\(event.start <= store.now ? "Your meeting is underway." : "Your next meeting is at \(time).")"
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        toolbar
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 25) {
            briefingBanner(compact: geometry.size.width < 960, viewportHeight: geometry.size.height - 62)
            if geometry.size.width >= 900 {
              hubColumns(width: geometry.size.width)
            } else {
              prioritySection
              nextMeetingSection
              waitingSection
            }
            invitationSection
            activitySummary
            DisclosureGroup(isExpanded: $showExtras) {
              VStack(alignment: .leading, spacing: 28) {
                HomeCalendarView(store: store)
                HomeWeatherView(weather: weather)
                reconnectSection
                recentSection
              }.padding(.top, 20)
            } label: {
              Text("Your day & people").font(HomeType.action)
            }.tint(Palette.body)
          }.padding(.horizontal, geometry.size.width < 760 ? 24 : 34).padding(.vertical, 26)
        }.coordinateSpace(name: "hub-scroll")
      }.background(Palette.canvas).foregroundStyle(Palette.ink)
        .onChange(of: store.accountEmail) { _, _ in lastIgnored = nil }
        .task(id: "\(scenePhase)-\(store.calendarConnected)-\(store.accountEmail)") {
          guard loadLiveData, scenePhase == .active else { return }
          while !Task.isCancelled {
            await store.refreshHomeCalendar()
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
          }
        }
        .task(id: scenePhase) {
          guard loadLiveData, scenePhase == .active else { return }
          while !Task.isCancelled {
            await weather.refresh()
            do { try await Task.sleep(for: .seconds(1800)) } catch { return }
          }
        }
    }
  }

  private func hubColumns(width: CGFloat) -> some View {
    let sidebarWidth = min(350, width * 0.30)
    return HStack(alignment: .top, spacing: 28) {
      prioritySection.frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 26) {
        nextMeetingSection
        waitingSection
      }.padding(.leading, 25).frame(width: sidebarWidth, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
  }

  private var toolbar: some View {
    HStack {
      Text("Home").font(.coveSubheading)
      if store.isSample {
        Text("Sample mailbox").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
      Spacer()
      Text(store.now, format: .dateTime.weekday(.wide).month(.wide).day())
        .font(.coveSecondary).foregroundStyle(Palette.muted)
    }.padding(.horizontal, 34).frame(height: 62)
  }

  private func briefingBanner(compact: Bool, viewportHeight: CGFloat) -> some View {
    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 26)) : AnyLayout(HStackLayout(spacing: 32))
    return layout {
      VStack(alignment: .leading, spacing: 15) {
        Text(greeting).font(.coveTitle)
          .foregroundStyle(Color(white: 0.96)).fixedSize(horizontal: false, vertical: true)
        Text(briefing).font(.coveText).foregroundStyle(Color(white: 0.84))
          .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
        if !store.pendingInvitations.isEmpty {
          briefingTag("\(store.pendingInvitations.count) \(store.pendingInvitations.count == 1 ? "invitation" : "invitations")", warm: true)
        }
        Button { store.showAssistant = true } label: {
          Label("Ask Cove", systemImage: "sparkles")
        }.buttonStyle(SecondaryButton(compact: true)).frame(height: 36)
      }.frame(maxWidth: compact ? .infinity : 420, alignment: .leading)
      MailTideView(tide: tide, labels: tideLabels, viewportHeight: viewportHeight)
        .frame(maxWidth: .infinity)
    }.padding(26).frame(minHeight: 290)
      .background(Color(red: 0.114, green: 0.125, blue: 0.165), in: RoundedRectangle(cornerRadius: 10))
  }

  private func briefingTag(_ text: String, warm: Bool = false) -> some View {
    Text(text).font(.coveCaption)
      .foregroundStyle(warm ? Color(red: 0.94, green: 0.78, blue: 0.64) : Color(white: 0.87))
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
  }

  private var prioritySection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Needs your decision").font(HomeType.primarySection)
        Spacer()
        Text("\(priorities.count) \(priorities.count == 1 ? "message" : "messages")")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
      }.padding(.bottom, 8)
      if priorities.isEmpty {
        emptyMessage(title: inbox.isEmpty ? "Your inbox is empty" : "Nothing needs a decision")
        Button(inbox.isEmpty ? "Sync Gmail" : "Organize mail") {
          Task {
            if inbox.isEmpty { await store.sync() } else { await store.classifyInbox() }
          }
        }.buttonStyle(PrimaryButton()).disabled(store.busy || store.isSample)
          .help(inbox.isEmpty ? "Download your latest mail" : "Let Jev find messages that may need a reply")
      } else {
        ForEach(Array(priorities.prefix(3))) { message in
          // One primary action per screen: only the top decision gets it.
          priorityRow(message, primary: message.id == priorities.first?.id)
        }
        if priorities.count > 3 {
          Button("View all priority mail →") {
            store.chooseFolder("Inbox")
            store.priorityOnly = true
            store.reconcileSelection()
          }.buttonStyle(.plain).font(HomeType.action)
        }
      }
    }
  }

  private func priorityRow(_ message: Mail, primary: Bool) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Button { open(message) } label: {
        VStack(alignment: .leading, spacing: 11) {
          HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(message.subject.isEmpty ? "No subject" : message.subject)
              .font(.coveSubheading).lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(message.date, format: .dateTime.month(.abbreviated).day())
              .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize()
          }
          Text(message.decision?.excerpt ?? String(message.body.prefix(160)))
            .font(HomeType.compactBody).foregroundStyle(Palette.body).lineSpacing(5).lineLimit(2)
          HStack(spacing: 8) {
            Image(systemName: "envelope")
            Text("\(message.sender) · \(message.date.formatted(date: .omitted, time: .shortened))").lineLimit(1)
            if let file = message.availableAttachments.first {
              Text("·")
              Image(systemName: "paperclip")
              Text(file.filename).lineLimit(1)
            }
          }.font(.coveMetadata).foregroundStyle(Palette.body)
        }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(HubEmailButtonStyle()).accessibilityLabel("Open email from \(message.sender): \(message.subject)")
      HStack(spacing: 12) {
        reviewButton(message, primary: primary)
        Menu {
          Button("Tomorrow morning") { store.snooze(message, until: tomorrowMorning) }
          Button("In a week") { store.snooze(message, until: Calendar.current.date(byAdding: .day, value: 7, to: store.now)) }
        } label: { Label("Later", systemImage: "clock") }
          .menuStyle(.borderlessButton).fixedSize().font(HomeType.compactBody).disabled(store.busy)
        Spacer(minLength: 0)
        Menu {
          Button("Delegate…") { store.prepareHomeDelegation(message) }
            .help("Prepare a forwarding draft; choose a recipient and review before sending")
          Button(message.isStarred ? "Remove follow-up flag" : "Flag for follow-up") { Task { await store.toggleFlag(message) } }
          Button("Archive") { Task { await store.archive(message) } }
          Button("Move to Trash") { store.queueTrash(message) }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
          .menuStyle(.borderlessButton).fixedSize().disabled(store.busy).accessibilityLabel("More actions for \(message.subject)")
      }.foregroundStyle(Palette.body)
    }.padding(.vertical, 22).overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
  }

  @ViewBuilder private func reviewButton(_ message: Mail, primary: Bool) -> some View {
    let button = Button { store.reviewHomeDecision(message) } label: {
      Label(hasDraft(message) ? "Review draft" : "Review", systemImage: "square.and.pencil")
    }
    if primary { button.buttonStyle(PrimaryButton(compact: true)) }
    else { button.buttonStyle(SecondaryButton(compact: true)) }
  }

  private func hasDraft(_ message: Mail) -> Bool {
    !message.draft.isEmpty || store.customAgents.runs.contains { $0.mailID == message.id && $0.replySuggestion != nil && $0.replyApplied != true }
  }
  private var tomorrowMorning: Date {
    let day = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: store.now)) ?? store.now
    return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
  }
  private var nextMeetingSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("Next meeting").font(HomeType.primarySection)
        Spacer(minLength: 4)
        if let event = nextMeeting {
          Text(event.start, format: .dateTime.hour().minute()).font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }
      if let event = nextMeeting {
        Text(event.title).font(.coveSubheading).fixedSize(horizontal: false, vertical: true)
        Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · \(max(1, Int(event.end.timeIntervalSince(event.start) / 60))) min")
          .font(.coveMetadata).foregroundStyle(Palette.body)
        let people = (event.attendees ?? []).filter { $0.isSelf != true && $0.response != "declined" }.compactMap { $0.name ?? $0.email }
        if !people.isEmpty { Text("With " + people.prefix(3).joined(separator: ", ")).font(HomeType.compactBody).foregroundStyle(Palette.body).lineLimit(2) }
        if let details = event.details, !details.isEmpty {
          Text(details).font(HomeType.compactBody).foregroundStyle(Palette.body).lineSpacing(5).lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        } else if let location = event.location, !location.isEmpty {
          Label(location, systemImage: "mappin").font(HomeType.compactBody).foregroundStyle(Palette.body)
        }
        Button { openEvent(event) } label: { Label("Open", systemImage: "calendar") }
          .buttonStyle(SecondaryButton(compact: true))
      } else {
        Text("No upcoming meetings.")
          .font(HomeType.compactBody).foregroundStyle(Palette.body)
        Button(store.calendarConnected || store.isSample ? "Open calendar" : "Connect Calendar") {
          if store.calendarConnected || store.isSample { store.screen = "calendar" } else { store.showConnections = true }
        }.buttonStyle(SecondaryButton(compact: true))
      }
      if store.calendarSyncing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing calendar") }
      if let error = store.calendarSyncError { Text("Saved schedule · " + error).font(.coveMetadata).foregroundStyle(Palette.danger) }
    }
  }
  private func openEvent(_ event: LocalEvent) {
    store.selectCalendarDay(event.start); store.calendarEventID = event.id
    store.revealCalendar(for: event); store.screen = "calendar"
  }
  private var waitingSection: some View {
    VStack(alignment: .leading, spacing: 17) {
      Text("Waiting on others").font(HomeType.supportingSection)
        .help("Sent threads with no reply in downloaded mail from the last 30 days")
      if waiting.isEmpty {
        Text("Nothing waiting.").font(HomeType.compactBody).foregroundStyle(Palette.body)
      }
      ForEach(Array(waiting.prefix(2))) { message in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text(HomeBriefing.recipientNames(message)).font(HomeType.action).lineLimit(1)
            Spacer(minLength: 4)
            Text("Sent " + message.date.formatted(.dateTime.month(.abbreviated).day())).font(.coveMetadata).foregroundStyle(Palette.muted).lineLimit(1)
          }
          Button(message.subject.isEmpty ? "No subject" : message.subject) { open(message) }
            .buttonStyle(.plain).font(HomeType.compactBody).lineLimit(2)
          Button {
            store.prepareHomeFollowUp(message)
          } label: { Label("Draft follow-up", systemImage: "arrowshape.turn.up.left") }
            .buttonStyle(.plain).font(HomeType.action).disabled(store.busy)
        }
      }
    }.padding(.top, 22).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
  }
  @ViewBuilder private var invitationSection: some View {
    if !store.pendingInvitations.isEmpty {
      DisclosureGroup("Invitations · \(store.pendingInvitations.count) pending") {
        ForEach(Array(store.pendingInvitations.prefix(3))) { event in
          VStack(alignment: .leading, spacing: 10) {
            Button(event.title) { openEvent(event) }.buttonStyle(.plain).font(HomeType.itemTitle)
            Text(event.start, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.coveMetadata)
            InvitationResponseButtons(store: store, event: event)
          }.padding(.vertical, 12)
        }
        if let error = store.invitationError { Text(error).font(.coveMetadata).foregroundStyle(Palette.danger) }
        if let notice = store.invitationNotice { Text(notice).font(.coveMetadata) }
        Button("View all invitations") { showExtras = true }.buttonStyle(.plain).font(HomeType.action)
      }.font(HomeType.action).tint(Palette.body)
    }
  }
  private var activitySummary: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { showActivity.toggle() } label: {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.circle")
          Text("\(mail.filter { $0.decision != nil }.count) organized · \(store.customAgents.runs.filter { $0.replySuggestion != nil && $0.replyApplied != true }.count) agent drafts to review")
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: showActivity ? "chevron.down" : "chevron.right")
        }.font(HomeType.compactBody).foregroundStyle(Palette.body).padding(.vertical, 16).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(showActivity ? "Hide activity" : "Show activity")
      if showActivity { activitySection.padding(.vertical, 16) }
    }.overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
  }

  private var reconnectSection: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text("Keep in touch").font(HomeType.supportingSection)
          .help("People from personal and work conversations. Marketing and automated mail are excluded.")
        Spacer()
        if !store.ignoredKeepInTouch.isEmpty {
          Menu {
            ForEach(store.ignoredKeepInTouch.sorted(), id: \.self) { address in
              Button("Suggest \(address) again") {
                if store.setKeepInTouchIgnored(address, ignored: false), lastIgnored == address { lastIgnored = nil }
              }
            }
          } label: { Text("Ignored (\(store.ignoredKeepInTouch.count))").font(HomeType.action) }
            .menuStyle(.borderlessButton).fixedSize().help("Restore ignored people")
        }
      }
      if let lastIgnored {
        HStack(alignment: .top, spacing: 10) {
          Text("\(lastIgnored) won’t be suggested here.").font(.coveMetadata).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Undo") {
            if store.setKeepInTouchIgnored(lastIgnored, ignored: false) { self.lastIgnored = nil }
          }.buttonStyle(.plain).font(HomeType.action)
        }
      }
      if contacts.isEmpty {
        emptyMessage(title: "No one to check in with yet")
      }
      ForEach(Array(contacts.prefix(2))) { message in
        VStack(alignment: .leading, spacing: 11) {
          HStack(spacing: 9) {
            CoveAvatar(initials: message.initials, size: 32)
            Text(message.sender).font(HomeType.supportingTitle).lineLimit(1)
            Spacer(minLength: 6)
            Button("Ignore") {
              if store.setKeepInTouchIgnored(message.senderEmail, ignored: true) {
                lastIgnored = ContactDirectory.normalizedEmail(message.senderEmail)
              }
            }.buttonStyle(.plain).font(HomeType.action).foregroundStyle(Palette.body)
              .help("Stop suggesting this person in Keep in touch")
              .accessibilityLabel("Ignore Keep in touch suggestions for \(message.sender)")
          }
          Text(
            "Last received \(message.date.formatted(date: .abbreviated, time: .omitted)).\n\(message.subject)"
          )
          .font(HomeType.compactBody).foregroundStyle(Palette.body).lineSpacing(4).lineLimit(3)
          HStack(spacing: 16) {
            Button {
              store.newDraft()
              if let id = store.composeID {
                store.saveComposition(
                  id: id, to: message.senderEmail, subject: "Checking in", body: "")
              }
            } label: {
              Label("Draft a check-in", systemImage: "square.and.pencil")
            }.buttonStyle(.plain).font(HomeType.action).disabled(store.busy)
            Button("View email") { open(message) }.buttonStyle(.plain).font(HomeType.action)
          }
          Divider().padding(.top, 6)
        }.padding(.top, 8)
      }
    }
  }

  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Text("Fresh from your inbox").font(HomeType.supportingSection)
        Spacer()
        if files.count > 3 {
          Button(showAllFiles ? "Show recent ↑" : "All files →") { showAllFiles.toggle() }
            .buttonStyle(.plain).font(HomeType.action).foregroundStyle(Palette.body)
        }
      }
      if files.isEmpty {
        emptyMessage(title: "No attachments in downloaded mail")
      }
      ForEach(showAllFiles ? files : Array(files.prefix(3))) { file in
        HStack(spacing: 12) {
          Image(systemName: attachmentIcon(file.attachment))
            .font(.cove(size: 16)).foregroundStyle(Palette.body)
            .frame(width: 34, height: 39).background(
              Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
          VStack(alignment: .leading, spacing: 5) {
            Text(file.attachment.filename)
              .font(HomeType.supportingTitle).lineLimit(1)
            Button {
              open(file.message)
            } label: {
              Text(
                "\(file.message.sender) · \(file.message.subject.isEmpty ? "No subject" : file.message.subject)"
              )
              .font(.coveMetadata).foregroundStyle(Palette.muted).lineLimit(1)
            }.buttonStyle(.plain).help("Open source email")
          }.frame(maxWidth: .infinity, alignment: .leading)
          if let byteCount = file.attachment.byteCount {
            Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
              .font(.coveMetadata).foregroundStyle(Palette.muted).fixedSize()
          }
          Button {
            Task { await store.downloadAttachment(file.attachment, from: file.message) }
          } label: {
            Image(systemName: "arrow.down.to.line").font(.cove(size: 15))
              .foregroundStyle(Palette.body).frame(width: 30, height: 34)
          }.buttonStyle(.plain).disabled(store.busy)
            .help("Save \(file.attachment.filename)")
            .accessibilityLabel("Save \(file.attachment.filename)")
        }.padding(.vertical, 6)
        Divider()
      }
    }
  }

  private func attachmentIcon(_ attachment: MailAttachment) -> String {
    if attachment.mimeType.hasPrefix("image/") { return "photo" }
    if attachment.mimeType.contains("spreadsheet") || attachment.mimeType.contains("excel") {
      return "tablecells"
    }
    return "doc.text"
  }

  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 15) {
      activity(
        "\(mail.filter { $0.decision != nil }.count) emails organized",
        detail: store.isSample ? "Sample categories and priority decisions" : "Categories and priority decisions from Jev")
      activity(
        "\(mail.filter { !$0.draft.isEmpty || $0.labels.contains("DRAFT") }.count) drafts saved",
        detail: "Ready for your review. Nothing is sent automatically.")
      activity("\(files.count) attachments found", detail: "Linked to their original conversations")
      Button("Your agent preferences →") { store.screen = "agent" }.buttonStyle(.plain)
        .font(HomeType.action)
    }
  }

  private func activity(_ title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "checkmark.circle").foregroundStyle(Palette.muted)
      Text(title).font(HomeType.action)
    }.help(detail)
  }

  private func emptyMessage(title: String) -> some View {
    Text(title).font(HomeType.supportingTitle).foregroundStyle(Palette.body).padding(.vertical, 16)
  }

  private func open(_ message: Mail) { store.openHomeMail(message) }

}

private struct HubFile: Identifiable {
  let message: Mail
  let attachment: MailAttachment
  var id: String { message.id + ":" + attachment.id }
}

private struct HubEmailButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HubEmailButtonSurface(configuration: configuration)
  }
}

private struct HubEmailButtonSurface: View {
  let configuration: ButtonStyleConfiguration
  @State private var hovering = false
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    configuration.label.foregroundStyle(Palette.ink)
      .background(
        configuration.isPressed ? Palette.selection : hovering ? Palette.surface : Palette.canvas,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: 6).stroke(Palette.ink, lineWidth: 2)
        }
      }
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
  }
}
