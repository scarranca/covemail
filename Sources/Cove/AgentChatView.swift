import CoveCore
import SwiftUI

/// The centered conversation from Pen's revised Cove Agent Chat.
struct AssistantView: View {
  @Bindable var store: AppStore
  let availableSize: CGSize
  @Environment(\.dismiss) private var dismissSheet
  @FocusState private var composerFocused: Bool
  @State private var query = ""
  @State private var eventReview: AssistantEventReview?
  @State private var replyReview: AssistantReplyReview?
  @State private var expandedSources = Set<UUID>()

  @State private var exchanges: [ChatExchange] = []
  @State private var contextID: String?
  @State private var scope: AssistantScope = .email
  @State private var choosingContext = false
  @State private var contextSearch = ""
  @State private var request: Task<Void, Never>?
  @State private var scrollTarget: UUID?
  @State private var actionNotice: String?
  @State private var aiSettings: AIProviderSettings
  @State private var selectedModel: AssistantModelChoice?
  @State private var showingModels = false
  @State private var showingPrivacy = false
  @State private var useAI = false
  /// On: research across all of Gmail. Off: downloaded mail only.
  @State private var searchingGmail = true
  /// Emails first found by research in this conversation; they open under All mail.
  @State private var researchedIDs: Set<String> = []
  private var modelChoice: AssistantModelChoice? {
    aiSettings.assistantChoice(preferred: selectedModel)
  }
  private var writingProvider: AIProvider? { modelChoice?.provider }
  /// Embedded in the reader: the conversation is about this email and closes in place.
  var pinnedMailID: String?
  var onClose: (() -> Void)?
  private var embedded: Bool { pinnedMailID != nil }
  init(store: AppStore, availableSize: CGSize, settings: AIProviderSettings = .shared,
       initialExchanges: [ChatExchange] = [], initialQuery: String = "",
       pinnedMailID: String? = nil, onClose: (() -> Void)? = nil) {
    self.store = store
    self.pinnedMailID = pinnedMailID
    self.onClose = onClose
    self.availableSize = availableSize
    _aiSettings = State(initialValue: settings)
    _exchanges = State(initialValue: initialExchanges)
    _query = State(initialValue: initialQuery)
  }
  private var working: Bool { request != nil }
  private func close() {
    if let onClose { onClose() } else { store.showAssistant = false; dismissSheet() }
  }
  private var context: Mail? {
    store.mails.first { $0.id == contextID }
  }
  private var availableMail: [Mail] {
    store.mails.filter {
      $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"])
        && (contextSearch.isEmpty
          || "\($0.subject) \($0.sender)".localizedCaseInsensitiveContains(contextSearch))
    }.sorted { $0.date > $1.date }
  }

  var body: some View {
    VStack(spacing: 0) {
      if embedded { embeddedHeader } else { header }
      Divider()
      conversation
      composer
    }
    .frame(
      width: embedded ? nil : min(800, max(1, availableSize.width - 48)),
      height: embedded ? nil : min(896, max(1, availableSize.height - 48))
    )
    .background(Palette.canvas)
    .font(.coveBody).foregroundStyle(Palette.ink)
    .onAppear {
      // The hub asks about the mailbox; only the mail reader starts with a selected email.
      contextID = pinnedMailID ?? (
        store.screen == "mail" ? availableMail.first { $0.id == store.selectedID }?.id : nil)
      // A conversation is read as a whole by default; "This email" remains in the scope picker.
      if let context, !context.threadID.isEmpty,
        MailConversation.messages(in: store.mails, anchor: context).count > 1
      {
        scope = .thread
      }
      composerFocused = true
    }
    .task {
      await aiSettings.restoreWritingConnection()
      useAI = writingProvider != nil
    }
    .onChange(of: writingProvider) { _, provider in
      if provider == nil { useAI = false }
    }
    .onDisappear { request?.cancel() }
    .onChange(of: store.accountEmail) { _, _ in
      request?.cancel()
      eventReview = nil
      replyReview = nil
      exchanges = []
    }
    .sheet(item: $replyReview) { review in
      AIWritingSheet(context: review.context, initialText: review.mail.draft, onInsert: { value in
        guard store.entered, store.accountEmail == review.account,
          store.mails.contains(where: { $0.id == review.mail.id }) else { return }
        store.saveReply(id: review.mail.id, text: value)
        replyReview = nil
        openSource(review.mail)
      }, onConfigure: { store.screen = "integrations"; close() }, store: store,
        initialInstruction: "Draft a reply to this email. Consider the earlier recommendation, but verify it against the email. Do not invent commitments. Use the language of my original question: \(review.question)",
        recommendationContext: review.recommendation)
    }
    .sheet(item: $eventReview) { review in
      CalendarEventEditor(store: store, draft: review.draft, reviewingProposal: true) { saved in
        guard let index = exchanges.firstIndex(where: { $0.id == review.exchangeID }) else { return }
        exchanges[index].eventCreated = true
        exchanges[index].addedEvent = store.events.first { $0.id == store.calendarEventID }
        exchanges[index].source = "Calendar · event created"
        exchanges[index].answer = "Added “\(saved.title)” to \(saved.onGoogle ? "Google Calendar" : saved.localCalendar.title + " on this Mac") for \(saved.start.formatted(date: .complete, time: .shortened))."
      }
    }
  }

  private func showComposeOutcome(_ outcome: AppStore.AssistantDraftOutcome, exchangeID: UUID,
                                  request: AssistantCalendar.ComposeRequest, question: String, source: String) {
    guard let index = exchanges.firstIndex(where: { $0.id == exchangeID }) else { return }
    switch outcome {
    case .clarification(let text):
      exchanges[index].answer = text
      exchanges[index].source = "Your contacts · nothing drafted"
    case .ambiguous(let name, let candidates):
      exchanges[index].answer = "Which \(name)?"
      exchanges[index].source = "Your contacts · nothing drafted yet"
      exchanges[index].pendingCompose = PendingCompose(request: request, question: question, name: name, candidates: candidates)
    case .opened(let recipients, _):
      exchanges[index].answer = "Here’s your draft to \(recipients.map(\.name).joined(separator: " and ")). It’s saved in Drafts; nothing has been sent."
      exchanges[index].source = source
      if let id = store.composeID, let saved = store.mails.first(where: { $0.id == id }) {
        exchanges[index].draft = AssistantDraftArtifact(mailID: id, to: saved.to, subject: saved.subject, body: saved.body, isReply: false)
      }
    }
  }
  private func update(_ id: UUID, _ change: (inout ChatExchange) -> Void) {
    guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
    change(&exchanges[index])
  }
  /// Approve in place: the explicit Add click is the commit, as in the event editor.
  private func addProposal(_ id: UUID, _ proposal: AssistantCalendar.Proposal) {
    guard proposal.start > Date().addingTimeInterval(-120) else {
      actionNotice = "That start time has passed. Choose Edit to pick a new time."
      return
    }
    if let eventID = proposal.eventID {
      moveEvent(id, eventID: eventID, to: DateInterval(start: proposal.start, end: proposal.end), undoing: false)
      return
    }
    let onGoogle = store.calendarConnected && !store.isSample
    Task {
      let saved = await store.createEvent(title: proposal.title, start: proposal.start, end: proposal.end, onGoogle: onGoogle)
      guard saved, let event = store.events.first(where: { $0.id == store.calendarEventID }) else {
        actionNotice = store.error ?? "Couldn’t add the event. Try Edit to review it."
        return
      }
      update(id) {
        $0.eventCreated = true
        $0.addedEvent = event
        $0.source = "Calendar · event created"
      }
    }
  }
  /// Runs only from the task card's Add button: creates the task, then archives the email if the user asked.
  private func addTask(_ id: UUID) {
    guard let state = exchanges.first(where: { $0.id == id })?.task, state.phase == .review else { return }
    let proposal = state.proposal
    update(id) { $0.task?.phase = .working }
    Task {
      do {
        let created = try await store.createTask(title: proposal.title, due: proposal.due, notes: proposal.notes, from: proposal.mailID)
        var archived = false
        if proposal.archive, let mailID = proposal.mailID, let mail = store.mails.first(where: { $0.id == mailID }),
          mail.labels.contains("INBOX") {
          await store.archive(mail)
          archived = store.mails.first(where: { $0.id == mailID }).map { !$0.labels.contains("INBOX") } ?? false
        }
        update(id) {
          $0.task?.phase = .created(created)
          $0.task?.archived = archived
          $0.source = "Google Tasks · task created" + (archived ? " · email archived" : "")
        }
      } catch {
        update(id) { $0.task?.phase = .review }
        actionNotice = (error as? CoveError)?.localizedDescription ?? "Couldn’t create the task. Try again."
      }
    }
  }
  private func undoTaskArchive(_ id: UUID) {
    guard let state = exchanges.first(where: { $0.id == id })?.task, state.archived,
      let mailID = state.proposal.mailID, let mail = store.mails.first(where: { $0.id == mailID }) else { return }
    update(id) { $0.task?.archived = false }
    Task { await store.modify(mail, add: ["INBOX"]) }
  }
  /// Runs only from the bulk card's Approve or Undo. Undo reverses the change on exactly the emails that
  /// succeeded. It runs in its own task, so closing the chat doesn't stop an approved change halfway.
  private func runBulk(_ id: UUID, undo: Bool) {
    guard let state = exchanges.first(where: { $0.id == id })?.bulk, !state.isRunning,
      undo ? state.phase == .finished : state.phase == .review else { return }
    let plan = state.plan
    let succeeded = Set(state.result?.succeeded ?? [])
    let targets = undo ? plan.targets.filter { succeeded.contains($0.id) } : plan.targets
    guard !targets.isEmpty else { return }
    let account = store.accountEmail
    update(id) { $0.bulk?.phase = undo ? .undoing(done: 0) : .running(done: 0) }
    Task { @MainActor in
      let result = await store.applyBulk(targets, add: undo ? plan.remove : plan.add, remove: undo ? plan.add : plan.remove,
        label: undo ? "Restoring" : plan.operation.progress(label: plan.labelName)) { done in
        update(id) { $0.bulk?.phase = undo ? .undoing(done: done) : .running(done: done) }
      }
      guard store.accountEmail == account else { return }
      update(id) {
        if undo { $0.bulk?.undoResult = result; $0.bulk?.phase = .undone }
        else { $0.bulk?.result = result; $0.bulk?.phase = .finished }
        $0.source = plan.scope + " · \(result.succeeded.count) \(undo ? "restored" : "changed")"
          + (result.failed.isEmpty ? "" : ", \(result.failed.count) failed")
      }
    }
  }
  /// Moves the selected event after the user approved the new time; Undo moves it back.
  private func moveEvent(_ id: UUID, eventID: String, to interval: DateInterval, undoing: Bool) {
    guard let event = store.events.first(where: { $0.id == eventID }), event.canReschedule else {
      actionNotice = "This event can’t be moved from Cove. Open it in Calendar."
      return
    }
    let before = DateInterval(start: event.start, end: event.end)
    Task {
      let saved = await store.createEvent(title: event.title, start: interval.start, end: interval.end,
        onGoogle: event.googleID != nil, editing: event, localCalendar: event.effectiveLocalCalendar)
      guard saved, let moved = store.events.first(where: { $0.id == store.calendarEventID }) else {
        actionNotice = store.error ?? "Couldn’t move “\(event.title)”. Try again."
        return
      }
      update(id) {
        $0.eventCreated = !undoing
        $0.addedEvent = undoing ? nil : moved
        $0.movedFrom = undoing ? nil : before
        // Keep the proposal pointing at the event's current id, so Undo or a retry finds it.
        if let proposal = $0.eventProposal {
          $0.eventProposal = .init(title: proposal.title, start: proposal.start, end: proposal.end,
                                   availability: proposal.availability, eventID: moved.id)
        }
        $0.source = undoing ? "Calendar · moved back" : "Calendar · event moved"
      }
    }
  }
  private func undoProposal(_ id: UUID) {
    if let exchange = exchanges.first(where: { $0.id == id }), let before = exchange.movedFrom,
      let moved = exchange.addedEvent {
      moveEvent(id, eventID: moved.id, to: before, undoing: true)
      return
    }
    guard let event = exchanges.first(where: { $0.id == id })?.addedEvent else { return }
    Task {
      await store.deleteEvent(event)
      guard !store.events.contains(where: { $0.id == event.id }) else {
        actionNotice = store.error ?? "Couldn’t remove the event."
        return
      }
      update(id) {
        $0.eventCreated = false
        $0.addedEvent = nil
        $0.source = "Calendar · nothing created"
      }
    }
  }
  /// Opens the saved draft where the user sends it themselves; the assistant never sends.
  private func reviewDraft(_ draft: AssistantDraftArtifact) {
    guard let mail = store.mails.first(where: { $0.id == draft.mailID }) else {
      actionNotice = "This draft is no longer available."
      return
    }
    close()
    if draft.isReply {
      store.screen = "mail"
      store.select(mail)
    } else {
      store.composeID = mail.id
      store.showComposer = true
    }
  }

  /// A slim header for the reader: what the conversation is about, a fresh start, and close.
  private var embeddedHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles").font(.cove(size: 13)).foregroundStyle(Palette.body).accessibilityHidden(true)
      Text(scope == .thread ? "Ask about this conversation" : "Ask about this email").font(.coveLabel)
      Spacer()
      if !exchanges.isEmpty {
        Button("New") {
          exchanges = []; expandedSources = []; query = ""; actionNotice = nil; researchedIDs = []; composerFocused = true
        }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body).disabled(working)
      }
      Button { close() } label: { Image(systemName: "xmark").font(.cove(size: 12)).frame(width: 24, height: 24) }
        .buttonStyle(.plain).foregroundStyle(Palette.body).help("Close").accessibilityLabel("Close Ask Cove")
        .keyboardShortcut(.cancelAction)
    }.padding(.horizontal, 20).padding(.vertical, 12)
  }
  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "sparkles").font(.cove(size: 16)).foregroundStyle(Palette.body)
        .accessibilityHidden(true)
      Text("Cove assistant").font(.coveSection)
      Spacer()
      Menu {
        if exchanges.isEmpty {
          Text("Your questions will appear here")
        } else {
          ForEach(exchanges) { exchange in
            Button(exchange.question) { scrollTarget = exchange.id }
          }
          Divider()
          Button("New conversation") {
            exchanges = []
            expandedSources = []
            query = ""
            actionNotice = nil
            researchedIDs = []
            composerFocused = true
          }.disabled(working)
        }
      } label: {
        Image(systemName: "clock.arrow.circlepath").font(.cove(size: 17))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        .help("Conversation history").accessibilityLabel("Conversation history")
      Rectangle().fill(Palette.line).frame(width: 1, height: 20)
      Button {
        close()
      } label: {
        Image(systemName: "xmark").font(.cove(size: 17)).frame(width: 28, height: 30)
      }.buttonStyle(.plain).help("Close chat").accessibilityLabel("Close chat")
        .keyboardShortcut(.cancelAction)
    }.padding(.horizontal, 28).padding(.vertical, 18)
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if let mail = context, !embedded {
            Button {
              choosingContext = true
            } label: {
              Label(
                (scope == .thread ? "Thread · " : "")
                  + (mail.subject.isEmpty ? "(No subject)" : mail.subject),
                systemImage: scope == .thread ? "envelope.stack" : "envelope"
              )
              .font(.coveSecondary).lineLimit(1).foregroundStyle(Palette.body)
              .padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Choose an email or its whole thread").disabled(working)
          } else if !embedded {
            Label(
              exchanges.last?.isCalendar == true
                ? (store.isSample ? "Calendar · sample data on this Mac" : "Your calendar")
                : (store.isSample ? "Mailbox · sample data on this Mac" : "Downloaded passages · live Gmail counts"),
              systemImage: exchanges.last?.isCalendar == true ? "calendar" : "tray.full"
            )
            .font(.coveSecondary).foregroundStyle(Palette.body)
            .padding(.vertical, 4)
          }
          if exchanges.isEmpty { introduction }
          ForEach(exchanges) { exchange in
            exchangeView(exchange).id(exchange.id)
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }.padding(.horizontal, embedded ? 20 : 32).padding(.top, embedded ? 16 : 24).padding(.bottom, embedded ? 16 : 28)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: exchanges.count) { _, _ in proxy.scrollTo("conversation-end", anchor: .bottom) }
      .onChange(of: working) { _, value in
        if !value, let latest = exchanges.last {
          proxy.scrollTo(latest.id, anchor: .top)
        } else {
          proxy.scrollTo("conversation-end", anchor: .bottom)
        }
      }
      .onChange(of: scrollTarget) { _, id in
        if let id { proxy.scrollTo(id, anchor: .top) }
      }
    }
  }

  @ViewBuilder private var introduction: some View {
    if embedded {
      // The header already says what this is about; start with the suggestions.
      MailChipLayout(spacing: 9) {
        ForEach(suggestions, id: \.label) { suggestion in
          Button(suggestion.label) { ask(suggestion.question) }
        }
      }.buttonStyle(SecondaryButton(compact: true)).disabled(working)
    } else {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "sparkles").font(.cove(size: 25)).foregroundStyle(Palette.muted)
        .accessibilityHidden(true)
      Text(context == nil ? "What can I help with?" : "Ask about this \(scope == .thread ? "thread" : "email").")
        .font(.coveTitle)
      Text(context != nil ? "Answers point to the original words."
        : store.isSample ? "Sample answers are previews." : "Ask, find, or tidy up. Nothing changes without your OK.")
        .font(.coveBody).foregroundStyle(Palette.body)
      MailChipLayout(spacing: 9) {
        ForEach(suggestions, id: \.label) { suggestion in
          Button(suggestion.label) { ask(suggestion.question) }
        }
      }.buttonStyle(SecondaryButton(compact: true)).disabled(working)
    }.padding(.vertical, 34)
    }
  }

  /// Short starting points for what's on screen, instead of a paragraph of instructions.
  private var suggestions: [(label: String, question: String)] {
    if context != nil {
      return [("What needs my attention?", "What needs my attention?"), ("Which dates are mentioned?", "Which dates are mentioned?")]
        + (useAI ? [("Draft a reply", "Draft a reply that answers what the sender needs.")] : [])
    }
    guard useAI else {
      return [("How many unread?", "How many unread emails do I have?"), ("How many in my inbox?", "How many emails are in my inbox?")]
    }
    var result = [("Brief me on today", "Brief me on today: what needs my attention?")]
    if store.screen == "mail", !store.visible.isEmpty {
      result.append(("Summarize these", "Summarize the emails in this view."))
    }
    result.append(("Open my drafts", "Open my drafts"))
    return result
  }

  private func exchangeView(_ exchange: ChatExchange) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Spacer(minLength: 32)
        // The bubble hugs short questions and wraps long ones, always aligned to the right.
        Text(exchange.question).font(.coveBody).lineSpacing(6)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(Palette.summary, in: RoundedRectangle(cornerRadius: 10))
          .textSelection(.enabled)
          .frame(maxWidth: 464, alignment: .trailing)
      }
      VStack(alignment: .leading, spacing: 20) {
        if let answer = exchange.answer {
          if let agenda = exchange.agenda { AssistantAgendaView(agenda: agenda) }
          else if let response = exchange.response {
            AssistantResponseView(response: response, mails: exchange.passages.map(\.mail), canReply: !store.busy && !working,
              open: openSource, draft: { mail, recommendation in
                let comparisonSources = Set(exchange.response?.primary?.comparison.map(\.source) ?? [])
                let relatedIDs = exchange.passages.enumerated().filter { comparisonSources.contains($0.offset + 1) }.map { $0.element.mail.id }
                replyReview = AssistantReplyReview(sourceID: mail.id, recommendation: recommendation, question: exchange.question, relatedIDs: relatedIDs, store: store)
                if replyReview == nil { actionNotice = "This email is no longer available. Search for it again." }
              })
          } else { ChatMarkdown(answer) }
          if let proposal = exchange.eventProposal {
            AssistantEventCard(
              // A move stays where the event lives; a new event goes to Google Calendar when connected.
              proposal: proposal, destination: proposal.eventID.flatMap { id in store.events.first { $0.id == id } }
                .map { $0.googleID != nil && !store.isSample ? "Google Calendar" : "This Mac" }
                ?? (store.calendarConnected && !store.isSample ? "Google Calendar" : "This Mac"),
              added: exchange.addedEvent, dismissed: exchange.eventDismissed, busy: store.busy || store.calendarSyncing,
              add: { addProposal(exchange.id, proposal) },
              edit: {
                var draft = CalendarEventDraft(title: proposal.title, start: proposal.start, end: proposal.end)
                draft.onGoogle = store.calendarConnected && !store.isSample
                eventReview = AssistantEventReview(exchangeID: exchange.id, draft: draft)
              },
              dismiss: { update(exchange.id) { $0.eventDismissed = true } },
              undo: { undoProposal(exchange.id) },
              open: { event in
                store.selectCalendarDay(event.start)
                store.calendarEventID = event.id
                store.screen = "calendar"
                close()
              }, isMove: proposal.eventID != nil,
              note: proposal.eventID.flatMap { id in store.events.first { $0.id == id } }
                .flatMap { $0.hasOtherGuests && !store.isSample ? "Guests will see the new time." : nil })
          }
          if let bulk = exchange.bulk {
            AssistantBulkCard(state: bulk, approve: { runBulk(exchange.id, undo: false) },
              cancel: { update(exchange.id) { $0.bulk?.phase = .cancelled; $0.source = "Nothing changed" } },
              undo: { runBulk(exchange.id, undo: true) },
              loadAll: {
                guard let targets = exchanges.first(where: { $0.id == exchange.id })?.bulk?.plan.targets else { return }
                do {
                  let detailed = try await store.bulkTargetDetails(targets)
                  update(exchange.id) { $0.bulk?.plan.targets = detailed }
                } catch { actionNotice = error.localizedDescription }
              })
          }
          if let task = exchange.task {
            AssistantTaskCard(state: task, mail: task.proposal.mailID.flatMap { id in store.mails.first { $0.id == id } },
              connected: store.tasksConnected, connecting: store.connectingStep != nil,
              edit: { title in update(exchange.id) { $0.task?.proposal.title = title } },
              toggleArchive: { on in update(exchange.id) { $0.task?.proposal.archive = on } },
              connect: { Task { await store.connectTasks() } },
              add: { addTask(exchange.id) },
              dismiss: { update(exchange.id) { $0.task?.phase = .dismissed; $0.source = "Nothing created" } },
              undoArchive: { undoTaskArchive(exchange.id) },
              open: { store.screen = "tasks"; close() })
          }
          if let pending = exchange.pendingCompose, !pending.resolved {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(pending.candidates) { contact in
                Button { ask(contact.email) } label: {
                  HStack(spacing: 10) {
                    CoveAvatar(initials: contact.initials.isEmpty ? String(contact.email.prefix(1)).uppercased() : contact.initials, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                      Text(contact.name).font(.coveLabel)
                      Text(contact.email).font(.coveMetadata).foregroundStyle(Palette.body)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.cove(size: 11)).foregroundStyle(Palette.muted)
                  }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: 420, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(working).accessibilityLabel("Write to \(contact.name), \(contact.email)")
              }
            }
          }
          if let draft = exchange.draft {
            AssistantDraftCard(draft: draft, review: { reviewDraft(draft) }, copy: {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(draft.body, forType: .string)
              actionNotice = "Draft copied."
            })
          }
          if let memory = exchange.rememberedMemory {
            AssistantMemoryCard(memory: memory, undone: exchange.memoryUndone) {
              store.forgetMemory(exactly: memory)
              update(exchange.id) { $0.memoryUndone = true }
            }
          }
          responseFeedback(exchange, answer: answer)
          if expandedSources.contains(exchange.id), !exchange.passages.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
              ForEach(exchange.passages) { passage in
                Divider()
                sourcePassage(passage.text, mail: passage.mail)
                sourceActions(passage.mail)
              }
            }
          }
        } else if let error = exchange.error {
          VStack(alignment: .leading, spacing: 10) {
            Text(exchange.cancelled ? "Response stopped" : "Couldn’t complete this request")
              .font(.coveControl).foregroundStyle(exchange.cancelled ? Palette.body : Palette.danger)
            Text(error).font(.coveBody).foregroundStyle(Palette.body).textSelection(.enabled)
            if error == JevClient.missingKeyMessage {
              HStack(spacing: 10) {
                Button("Add TypeSafe key") {
                  store.settingsSection = "Jev · Mail agent"
                  close()
                  store.showConnections = true
                }.buttonStyle(PrimaryButton())
                Button("Connect a writing model") {
                  close()
                  store.screen = "integrations"
                }.buttonStyle(SecondaryButton())
              }
            } else {
              Button("Try again") {
                contextID = exchange.mail?.id
                scope = exchange.scope
                ask(exchange.question)
              }.buttonStyle(SecondaryButton()).disabled(working)
            }
          }
        } else {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(
              exchange.progress ?? (exchange.mail == nil
                ? (MailboxQuestion.parse(exchange.question) == nil
                  ? "Finding passages in downloaded mail…" : "Checking your mailbox…")
                : exchange.scope == .thread
                  ? "Reading the conversation and finding passages…"
                  : "Finding the relevant passage…")
            )
            .font(.coveSecondary).foregroundStyle(
              Palette.muted)
          }.padding(.vertical, 10)
        }
      // Answers read as plain text, like a document, not as another card competing for attention.
      }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func responseFeedback(_ exchange: ChatExchange, answer: String) -> some View {
    HStack(spacing: 14) {
      if !exchange.passages.isEmpty {
        Button {
          if expandedSources.contains(exchange.id) { expandedSources.remove(exchange.id) }
          else { expandedSources.insert(exchange.id) }
        } label: {
          HStack(spacing: 6) {
            Text(expandedSources.contains(exchange.id) ? "Hide sources" : "\(Set(exchange.passages.map(\.mail.id)).count) source\(Set(exchange.passages.map(\.mail.id)).count == 1 ? "" : "s")")
            Image(systemName: expandedSources.contains(exchange.id) ? "chevron.up" : "chevron.down").font(.cove(size: 9))
          }.font(.coveMetadata).padding(.horizontal, 8).frame(height: 24)
          .background(Palette.sidebar, in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(Palette.body)
          .accessibilityValue(expandedSources.contains(exchange.id) ? "Expanded" : "Collapsed")
          .help(exchange.source ?? exchange.groundingLabel)
      } else {
        Text(exchange.groundingLabel).font(.coveMetadata).foregroundStyle(Palette.muted)
      }
      Spacer(minLength: 8)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        actionNotice = "Answer copied."
      } label: {
        Image(systemName: "doc.on.doc").font(.cove(size: 12)).frame(width: 24, height: 28)
      }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("Copy answer").accessibilityLabel("Copy answer")
      ForEach(AssistantFeedback.allCases, id: \.self) { feedback in
        Button {
          guard let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
          exchanges[index].feedback = exchange.feedback == feedback ? nil : feedback
          actionNotice = exchanges[index].feedback == nil ? nil : "Feedback noted for this conversation."
        } label: {
          Image(systemName: feedback.symbol + (exchange.feedback == feedback ? ".fill" : ""))
            .font(.cove(size: 12)).frame(width: 24, height: 28)
        }.buttonStyle(.plain).foregroundStyle(exchange.feedback == feedback ? Palette.ink : Palette.muted)
          .accessibilityLabel(feedback == .helpful ? "Helpful answer" : "Not helpful")
          .accessibilityValue(exchange.feedback == feedback ? "Selected" : "Not selected")
          .help("Mark \(feedback == .helpful ? "helpful" : "not helpful") for this conversation only")
      }

    }
  }

  private func sourceActions(_ mail: Mail) -> some View {
    HStack(spacing: 12) {
      Button {
        openSource(mail)
      } label: {
        Label(
          hasDraft(mail) ? "Review draft" : "Open email",
          systemImage: "square.and.pencil")
      }.buttonStyle(AssistantActionButton())
      Menu {
        Button("In one hour") {
          store.snooze(mail, until: Date().addingTimeInterval(3600))
          actionNotice = "Snoozed for one hour on this Mac."
        }
        Button("Tomorrow morning") {
          let calendar = Calendar.current
          if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
            let morning = calendar.date(
              bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
          {
            store.snooze(mail, until: morning)
            actionNotice = "Snoozed until tomorrow at 9 AM on this Mac."
          }
        }
      } label: {
        Label("Remind me", systemImage: "clock")
          .font(.coveControl).padding(.horizontal, 12).frame(height: 40)
          .foregroundStyle(Palette.body)
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Snooze this email and return it to your inbox later on this Mac")
    }.disabled(store.busy)
  }

  private func sourcePassage(_ answer: String, mail: Mail) -> some View {
    AssistantSourcePassage(answer: answer, mail: mail) { openSource(mail) }
  }

  private var modelMenu: some View {
    Button { showingModels.toggle() } label: {
      HStack(spacing: 7) {
        Text(useAI ? modelChoice.map { aiSettings.modelLabel($0.model, provider: $0.provider) } ?? "Choose model" : "Jev passages")
          .font(.coveControl).lineLimit(1)
        Image(systemName: "chevron.down").font(.cove(size: 10, weight: .medium))
      }.foregroundStyle(Palette.ink).padding(.horizontal, 8).frame(height: 32)
    }.buttonStyle(.plain)
      .frame(maxWidth: availableSize.width < 640 ? 130 : 190, alignment: .leading)
      .fixedSize(horizontal: true, vertical: true).disabled(working)
      .accessibilityLabel("Assistant model")
      .help(useAI ? modelChoice.map { "\(aiSettings.modelLabel($0.model, provider: $0.provider)) · \($0.provider.title)" } ?? "Choose a model" : "Jev returns original email passages")
      .popover(isPresented: $showingModels) {
        AssistantModelPicker(settings: aiSettings, selected: modelChoice, useAI: useAI) { choice in
          selectedModel = choice
          useAI = true
          showingModels = false
        } choosePassages: {
          useAI = false
          showingModels = false
        } manage: {
          showingModels = false
          store.screen = "integrations"
          close()
        }
      }
  }

  private var composer: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 20) {
        TextField(
          "Ask Cove…", text: $query,
          prompt: Text(exchanges.isEmpty
            ? (context == nil ? "Ask about your mailbox…" : scope == .thread ? "Ask about this thread…" : "Ask about this email…")
            : "Ask a follow-up…").foregroundStyle(Palette.body), axis: .vertical
        ).font(.coveBody).lineLimit(1...4).textFieldStyle(.plain)
          .accessibilityLabel("Question for Cove")
          .focused($composerFocused).onSubmit { ask(query) }
        HStack(spacing: 12) {
          if !embedded {
          Button {
            choosingContext = true
          } label: {
            Image(systemName: "plus").font(.cove(size: 18)).frame(width: 24, height: 32)
          }.buttonStyle(.plain).foregroundStyle(Palette.body).disabled(working)
            .help("Choose downloaded mail, one email, or its whole thread")
            .accessibilityLabel("Choose email context")
          }
          modelMenu
          Toggle("Mail search", isOn: $searchingGmail)
            .toggleStyle(AssistantMailSearchStyle(compact: availableSize.width < 640)).focusEffectDisabled()
            .disabled(working || !useAI)
            .help("On: search all of Gmail and read up to 100 matching emails. Off: use mail already downloaded to this Mac.")
          Spacer(minLength: 0)
          Button {
            if working {
              request?.cancel()
              if let index = exchanges.lastIndex(where: { $0.answer == nil && $0.error == nil }) {
                exchanges[index].cancelled = true
                exchanges[index].error = "Try again when you’re ready."
              }
            } else { ask(query) }
          } label: {
            Image(systemName: working ? "stop.fill" : "arrow.up")
              .font(.cove(size: working ? 11 : 16, weight: .medium))
          }.buttonStyle(ChatSendButton()).disabled(
            !working && ((useAI && writingProvider == nil) || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          ).help(working ? "Stop response" : "Ask Cove")
            .accessibilityLabel(working ? "Stop response" : "Ask Cove")
        }
      }.padding(16).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(composerFocused ? Palette.inputBorder : Palette.line, lineWidth: 1))
      HStack(spacing: 7) {
        Label(actionNotice ?? "Nothing is sent without your approval.", systemImage: "checkmark.shield")
          .font(.coveMetadata).foregroundStyle(Palette.body)
        Button { showingPrivacy.toggle() } label: {
          Image(systemName: "info.circle").font(.cove(size: 11)).frame(width: 22, height: 22)
        }.buttonStyle(.plain).foregroundStyle(Palette.muted)
          .help("How Cove uses your email context").accessibilityLabel("AI privacy and context details")
          .popover(isPresented: $showingPrivacy) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Your context, your control").font(.coveSection)
              Text(useAI
                ? "Your requests and up to 20 relevant emails are sent to \(writingProvider?.title ?? "your chosen provider"). Calendar requests use your connected calendar. Adding an event requires review."
                : "Jev finds original passages in your email context. It does not generate replies. Mailbox counts are checked with Gmail.")
              Text("Mail search prepares a query for you to review. Feedback stays in this conversation; it is not sent to a provider.")
            }.font(.coveSecondary).foregroundStyle(Palette.body).lineSpacing(4)
              .padding(20).frame(width: 330)
          }
      }
    }.padding(.horizontal, embedded ? 16 : 24).padding(.bottom, embedded ? 14 : 20)
      .popover(isPresented: $choosingContext) { contextPicker }
  }

  private var contextPicker: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose a scope").font(.coveSection)
      Button {
        contextID = nil
        choosingContext = false
        composerFocused = true
      } label: {
        HStack {
          Label("Downloaded mail", systemImage: "tray.full")
          Spacer()
          if contextID == nil { Image(systemName: "checkmark") }
        }.font(.coveControl).padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
      }.buttonStyle(.plain)
      Text(
        "Across conversations saved on this Mac. Drafts, Spam and Trash are excluded. Count questions still check Gmail directly."
      )
      .font(.coveSecondary).foregroundStyle(Palette.muted)
      Picker("Read from", selection: $scope) {
        ForEach(AssistantScope.allCases, id: \.self) { value in
          Text(value.rawValue).tag(value)
        }
      }.pickerStyle(.segmented)
        .onChange(of: scope) { _, _ in
          if context != nil {
            choosingContext = false
            composerFocused = true
          }
        }
      Text(
        scope == .thread
          ? "Choose an email to read its Gmail conversation. Drafts, Spam and Trash are excluded."
          : "Choose one email for source-passage questions."
      )
      .font(.coveSecondary).foregroundStyle(Palette.muted)

      TextField(
        "Search downloaded mail", text: $contextSearch,
        prompt: Text("Search downloaded mail").foregroundStyle(Palette.muted)
      )
      .textFieldStyle(CoveFieldStyle())
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          if availableMail.isEmpty {
            Text("No matching emails").font(.coveBody).foregroundStyle(Palette.muted).padding(
              .vertical, 20)
          }
          ForEach(availableMail) { mail in
            Button {
              contextID = mail.id
              choosingContext = false
              composerFocused = true
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveControl)
                    .lineLimit(2)
                  HStack {
                    Text(mail.sender).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mail.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                      .lineLimit(1)
                  }.font(.coveMetadata).foregroundStyle(Palette.muted)
                }
                Spacer()
                if mail.id == context?.id { Image(systemName: "checkmark").font(.coveControl) }
              }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  mail.id == context?.id ? Palette.surface : Palette.canvas,
                  in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }.frame(height: 280)
    }.padding(20).frame(width: 390).background(Palette.canvas)
  }

  private func hasDraft(_ mail: Mail) -> Bool {
    !(store.mails.first { $0.id == mail.id }?.draft ?? "").isEmpty
  }

  private func openSource(_ mail: Mail) {
    guard let current = store.mails.first(where: { $0.id == mail.id }) else {
      actionNotice = "This email is no longer available. Search for it again."
      return
    }
    store.search = ""
    let folder =
      current.labels.contains("DRAFT")
      ? "Drafts"
      : (current.snoozedUntil ?? .distantPast) > store.now
        ? "Snoozed"
        : current.labels.contains("SENT")
          ? "Sent"
          : current.labels.contains("INBOX") ? "Inbox" : "Archive"
    store.chooseFolder(researchedIDs.contains(current.id) ? "All mail" : folder)
    store.priorityOnly = false
    store.select(current)
    close()
  }

  private func ask(_ question: String) {
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !working, !question.isEmpty else { return }
    let mailboxQuestion = MailboxQuestion.parse(question)
    let mail = mailboxQuestion == nil ? context : nil
    if mailboxQuestion != nil { contextID = nil }
    let account = store.accountEmail
    // Keep follow-ups within the selected conversation; failed attempts are not evidence.
    let conversationHistory = exchanges.filter {
      $0.mail?.id == mail?.id && $0.scope == scope && $0.answer != nil
    }.suffix(3).map {
      "User: " + String($0.question.prefix(600)) + "\nCove: " + String(($0.answer ?? $0.error ?? "").prefix(900))
        + ($0.eventProposal.map { "\nProposed: \($0.title), \($0.start.ISO8601Format()) to \($0.end.ISO8601Format())." } ?? "")
    }.joined(separator: "\n")
    // Follow-ups ("make it shorter") reuse the emails the previous answer used instead of searching again.
    let previousSources: [Mail] = {
      guard let last = exchanges.last(where: { $0.mail?.id == mail?.id && $0.scope == scope && $0.answer != nil }) else { return [] }
      var seen = Set<String>()
      return last.passages.compactMap { passage in
        guard seen.insert(passage.mail.id).inserted else { return nil }
        return store.mails.first { $0.id == passage.mail.id } ?? passage.mail
      }
    }()
    // What the user is looking at when they ask; "this" and "these" resolve from it.
    let screenContext = store.assistantScreenContext()
    // An answer to "Which Martha?" continues that draft instead of starting over.
    let resume: (exchangeID: UUID, pending: PendingCompose, contact: MailContact)? = {
      guard let last = exchanges.last, let pending = last.pendingCompose, !pending.resolved,
        let contact = RecipientResolver.pick(from: pending.candidates, reply: question) else { return nil }
      return (last.id, pending, contact)
    }()
    let exchange = ChatExchange(question: question, mail: mail, scope: scope)
    exchanges.append(exchange)
    query = ""
    actionNotice = nil
    request = Task { @MainActor in
      defer { request = nil }
      do {
        let answer: String
        var source: String?
        var passages: [MailPassage] = []
        var response: AssistantResponse?
        if let resume, useAI, let choice = modelChoice {
          if let old = exchanges.firstIndex(where: { $0.id == resume.exchangeID }) { exchanges[old].pendingCompose?.resolved = true }
          if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
            exchanges[index].progress = "Writing your draft to \(resume.contact.name)…"
          }
          let folded = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
          let original = resume.pending.request
          let request = AssistantCalendar.ComposeRequest(
            recipients: original.recipients.map { folded($0) == folded(resume.pending.name) ? resume.contact.email : $0 },
            subject: original.subject, purpose: original.purpose, intro: original.intro)
          let outcome = try await store.draftNewEmail(request, question: resume.pending.question, present: false) { prompt in
            try await aiSettings.complete(prompt, provider: choice.provider, model: choice.model)
          }
          guard !Task.isCancelled, store.accountEmail == account else { return }
          showComposeOutcome(outcome, exchangeID: exchange.id, request: request, question: resume.pending.question,
                             source: "Draft · \(choice.provider.title) · \(choice.model)")
          return
        }
        if mailboxQuestion == .unsupportedCount, useAI, searchingGmail, !store.isSample, let choice = modelChoice {
          let counted = try await store.countMatchingMail(question, history: conversationHistory) { prompt in
            try await aiSettings.complete(prompt, provider: choice.provider, model: choice.model)
          }
          guard !Task.isCancelled, store.entered, store.accountEmail == account else { return }
          answer = counted.answer.text
          source = "\(choice.provider.title) · \(choice.model) wrote the search · " + counted.answer.source
          passages = counted.examples.enumerated().map { index, mail in
            MailPassage(mail: mail, text: "[\(index + 1)] " + String(mail.body.prefix(300)))
          }
        } else if let mailboxQuestion {
          let reply = try await store.mailboxAnswer(mailboxQuestion)
          answer = reply.text
          source = reply.source
        } else if useAI {
          guard let choice = modelChoice else { throw CoveError.message("Connect a writing provider in Integrations first.") }
          let provider = choice.provider
          let model = choice.model
          // Resolve the user's selection before routing. Otherwise invitation questions
          // reach the calendar planner without the very email visible in the header.
          var selectedMails: [Mail] = []
          var selectedCoverage = "Selected email"
          if let mail {
            if exchange.scope == .thread {
              let thread = try await store.aiThreadContext(mail)
              // Keep the selected message first when the thread exceeds prompt limits.
              selectedMails = [thread.messages.first { $0.id == mail.id } ?? mail]
                + thread.messages.filter { $0.id != mail.id }
              selectedCoverage = thread.coverage
            } else {
              selectedMails = [mail]
            }
          }
          guard !Task.isCancelled, store.entered, store.accountEmail == account else { return }
          let router = AssistantCalendar(complete: { prompt in
            try await aiSettings.complete(prompt, provider: provider, model: model)
          }, calendar: { from, to in
            try await store.writingCalendar(from: from, to: to)
          }, calendarAvailable: store.calendarConnected || store.isSample, sample: store.isSample, labels: store.gmailLabels)
          let result = try await router.respond(question, mails: selectedMails, history: conversationHistory,
                                                previousSources: !previousSources.isEmpty, screen: screenContext) { progress in
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
              exchanges[index].progress = progress
            }
          }
          guard !Task.isCancelled, store.entered, store.accountEmail == account,
            let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
          switch result {
          case .clarification(let question):
            exchanges[index].isCalendar = true
            exchanges[index].answer = question
            exchanges[index].source = "Calendar · nothing created"
            return
          case .question(let question):
            exchanges[index].answer = question
            exchanges[index].source = "Nothing changed"
            return
          case .navigate(let destination):
            exchanges[index].answer = destination.summary
            exchanges[index].source = "Opened in Cove"
            store.perform(destination)
            close()
            return
          case .bulk(let bulkRequest):
            exchanges[index].progress = bulkRequest.scope == .query && searchingGmail && !store.isSample
              ? "Finding the matching emails in Gmail…" : "Finding the emails…"
            let plan = try await store.resolveBulk(bulkRequest, liveSearch: searchingGmail && !store.isSample)
            guard !Task.isCancelled, store.entered, store.accountEmail == account,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            exchanges[index].source = plan.scope + " · nothing changed yet"
            if plan.targets.isEmpty {
              exchanges[index].answer = plan.unchanged > 0
                ? "Nothing to change: \(plan.unchanged) matching email\(plan.unchanged == 1 ? " is" : "s are") \(plan.operation.unchanged(label: plan.labelName))."
                : "I didn’t find any emails to change. Try other words, or open the folder with those emails."
            } else {
              exchanges[index].answer = "Here’s exactly what will change. Nothing happens until you approve."
              exchanges[index].bulk = AssistantBulkState(plan: plan)
            }
            return
          case .task(let proposal):
            exchanges[index].task = AssistantTaskState(proposal: proposal)
            exchanges[index].answer = "Here’s your task. Nothing is created until you add it."
            exchanges[index].source = "Google Tasks · nothing created yet"
            return
          case .view:
            let inView = Array(store.visible.prefix(20))
            guard !inView.isEmpty else {
              exchanges[index].answer = "There are no emails in this view."
              exchanges[index].source = "Current view"
              return
            }
            exchanges[index].progress = "Reading the \(inView.count) newest emails in \(store.folderTitle)…"
            let prompt = try AIPrompt(intent: .assistantAnswer,
              instruction: question + "\n(About the emails in the current view: \(store.folderTitle).)", mails: inView,
              evidence: String((store.preferences.memoryPrompt ?? "").prefix(2_500)))
            let generated = try await aiSettings.complete(prompt, provider: provider, model: model)
            guard !Task.isCancelled, store.accountEmail == account,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            let parsed = try AssistantResponse.parse(generated, mails: prompt.sourceMails)
            exchanges[index].response = parsed
            exchanges[index].answer = parsed?.plainText ?? generated
            exchanges[index].source = "Generated by \(provider.title) · \(model) · \(prompt.sourceMails.count) newest emails in \(store.folderTitle)"
            exchanges[index].passages = prompt.sourceMails.enumerated().map { number, mail in
              MailPassage(mail: mail, text: "[\(number + 1)] " + String(mail.body.prefix(300)))
            }
            return
          case .proposal(let proposal):
            exchanges[index].isCalendar = true
            exchanges[index].eventProposal = proposal
            exchanges[index].answer = proposal.eventID == nil
              ? "Here’s your event to review. It hasn’t been added yet."
              : "Here’s the new time to review. Nothing has changed yet."
            exchanges[index].source = "Calendar · nothing created"
            return
          case .agenda(let agenda):
            exchanges[index].isCalendar = true
            exchanges[index].agenda = agenda
            exchanges[index].answer = agenda.plainText
            exchanges[index].source = store.isSample ? "Calendar · sample data" : "Calendar · live lookup"
            return
          case .compose(let request):
            exchanges[index].progress = "Finding contacts and writing your draft…"
            let outcome = try await store.draftNewEmail(request, question: question, present: false) { prompt in
              try await aiSettings.complete(prompt, provider: provider, model: model)
            }
            guard !Task.isCancelled, store.accountEmail == account else { return }
            showComposeOutcome(outcome, exchangeID: exchange.id, request: request, question: question,
                               source: "Draft · \(provider.title) · \(model)")
            return
          case .reply(let instruction):
            guard let mail else { return }
            exchanges[index].progress = "Writing your reply…"
            let text = try await store.draftReply(to: mail, request: instruction, write: { prompt in
              try await aiSettings.complete(prompt, provider: provider, model: model)
            }, progress: { stage in
              if let current = exchanges.firstIndex(where: { $0.id == exchange.id }) { exchanges[current].progress = stage }
            })
            guard !Task.isCancelled, store.accountEmail == account,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            exchanges[index].answer = "Here’s your reply to \(mail.sender). It’s saved with the email; nothing has been sent."
            exchanges[index].source = "Draft · \(provider.title) · \(model)"
            exchanges[index].draft = AssistantDraftArtifact(
              mailID: mail.id, to: MailConversation.replyRecipient(for: mail, accountEmail: store.accountEmail),
              subject: mail.subject.lowercased().hasPrefix("re:") ? mail.subject : "Re: \(mail.subject)", body: text, isReply: true)
            return
          case .remember(let memory):
            let saved = store.remember(memory) ?? memory
            exchanges[index].rememberedMemory = saved
            exchanges[index].answer = "I’ll remember that." + (store.preferences.useMemories
              ? " You can review or forget it in Agents → Memories."
              : " Memories are turned off, so I won’t use it until you turn them on in Agents → Memories.")
            exchanges[index].source = "Saved on this Mac · encrypted with your mailbox"
            return
          case .forget(let text):
            let removed = store.forgetMemories(matching: text)
            exchanges[index].answer = removed.isEmpty
              ? "I don’t have a saved memory matching “\(text)”. You can review all memories in Agents → Memories."
              : "Forgotten: " + removed.map { "“\($0)”" }.joined(separator: ", ") + "."
            exchanges[index].source = "Memories on this Mac"
            return
          case .contact(let name):
            exchanges[index].answer = store.contactSummary(name, question: question)
            exchanges[index].source = "Your contacts and downloaded mail · no AI used"
            return
          case .brief:
            exchanges[index].progress = "Checking today’s calendar, invitations and inbox…"
            let context = await store.briefingContext()
            let prompt = try AIPrompt(intent: .assistantAnswer,
              instruction: question + "\nGive a short briefing for today: what needs my attention first, my schedule, and invitations awaiting a reply. Cite emails by number.",
              mails: context.mails, evidence: context.evidence + (store.preferences.memoryPrompt.map { "\n" + String($0.prefix(2_500)) } ?? ""))
            let generated = try await aiSettings.complete(prompt, provider: provider, model: model)
            guard !Task.isCancelled, store.accountEmail == account,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            let parsed = try AssistantResponse.parse(generated, mails: prompt.sourceMails)
            exchanges[index].response = parsed
            exchanges[index].answer = parsed?.plainText ?? generated
            exchanges[index].source = "Generated by \(provider.title) · \(model) · " + context.coverage
            exchanges[index].passages = prompt.sourceMails.enumerated().map { number, mail in
              MailPassage(mail: mail, text: "[\(number + 1)] " + String(mail.body.prefix(300)))
            }
            return
          case .followUp:
            exchanges[index].progress = "Revising with the same emails…"
            let prompt = try AIPrompt(intent: .assistantAnswer, instruction: question, mails: Array(previousSources.prefix(20)),
              evidence: "Recent conversation (the user is refining this; keep what they didn't ask to change):\n"
                + String(conversationHistory.suffix(4_000)) + "\n" + String((store.preferences.memoryPrompt ?? "").prefix(2_500)))
            let generated = try await aiSettings.complete(prompt, provider: provider, model: model)
            guard !Task.isCancelled, store.accountEmail == account,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            let parsed = try AssistantResponse.parse(generated, mails: prompt.sourceMails)
            exchanges[index].response = parsed
            exchanges[index].answer = parsed?.plainText ?? generated
            exchanges[index].source = "Generated by \(provider.title) · \(model) · same \(prompt.sourceMails.count) email\(prompt.sourceMails.count == 1 ? "" : "s") as the previous answer"
            exchanges[index].passages = prompt.sourceMails.enumerated().map { number, mail in
              MailPassage(mail: mail, text: "[\(number + 1)] " + String(mail.body.prefix(300)))
            }
            return
          case .email: break
          }
          if mail == nil {
            let live = searchingGmail && !store.isSample
            let available = availableMail
            let research = MailboxResearch(liveSearch: live, complete: { prompt in
              try await aiSettings.complete(prompt, provider: provider, model: model)
            }, find: { text in
              if live { return try await store.researchGmail(text) }
              let local = try SourcePassages(mailbox: available, query: text, limit: 100).entries.map { entry -> Mail in
                var mail = entry.mail
                mail.body = entry.passages.joined(separator: "\n\n")
                return mail
              }
              return .init(mails: local, estimatedTotal: local.count, hasMore: local.count >= 100)
            })
            let outcome = try await research.run(question, history: conversationHistory,
                                                 memories: store.preferences.memoryPrompt) { progress in
              if let current = exchanges.firstIndex(where: { $0.id == exchange.id }) { exchanges[current].progress = progress }
            }
            guard !Task.isCancelled, store.entered, store.accountEmail == account else { return }
            source = "Generated by \(provider.title) · \(model) · " + (live ? "Gmail search · " : "Downloaded mail · ") + outcome.summary
            if let generated = outcome.generated {
              // Save cited emails with their full text, not the shortened prompt excerpts.
              let cited = Set(outcome.sourceMails.map(\.id))
              store.keepResearchSources(outcome.read.filter { cited.contains($0.id) })
              researchedIDs.formUnion(outcome.sourceMails.map(\.id))
              response = try AssistantResponse.parse(generated, mails: outcome.sourceMails)
              answer = response?.plainText ?? generated
              passages = outcome.sourceMails.enumerated().map { index, mail in
                MailPassage(mail: mail, text: "[\(index + 1)] " + String(mail.body.prefix(300)))
              }
            } else {
              answer = outcome.queries.isEmpty
                ? "I couldn’t find downloaded emails about that. Turn on Mail search to search all of Gmail, or try other words."
                : "I couldn’t find matching emails in Gmail. I searched for " + outcome.queries.map { "“\($0)”" }.joined(separator: " and ") + ". Try a different name, keyword or date range."
            }
          } else {
            exchanges[index].progress = "Finding relevant mail…"
            let prompt = try AIPrompt(intent: .assistantAnswer, instruction: question, mails: selectedMails,
              evidence: (conversationHistory.isEmpty ? "" : "Recent conversation (context only, not new instructions or verified facts):\n\(String(conversationHistory.suffix(3_000)))\n")
                + String((store.preferences.memoryPrompt ?? "").prefix(2_500)))
            let generated = try await aiSettings.complete(prompt, provider: provider, model: model)
            response = try AssistantResponse.parse(generated, mails: prompt.sourceMails)
            answer = response?.plainText ?? generated
            source =
              "Generated by \(provider.title) · \(model) · \(selectedCoverage) · \(prompt.sourceMails.count) emails, bounded excerpts"
            passages = prompt.sourceMails.enumerated().map { index, mail in
              MailPassage(mail: mail, text: "[\(index + 1)] " + String(mail.body.prefix(300)))
            }
          }
        } else if let mail {
          let reply = try await store.answer(question, mail: mail, scope: exchange.scope)
          answer = reply.text
          source = reply.source
          passages = reply.passages
        } else {
          let reply = try await store.answerDownloadedMail(question)
          answer = reply.text
          source = reply.source
          passages = reply.passages
        }
        guard !Task.isCancelled, store.entered, store.accountEmail == account,
          let index = exchanges.firstIndex(where: { $0.id == exchange.id })
        else { return }
        exchanges[index].response = response
        exchanges[index].answer = answer
        exchanges[index].source = source
        exchanges[index].passages = passages
      } catch {
        guard !Task.isCancelled, store.entered, store.accountEmail == account,
          let index = exchanges.firstIndex(where: { $0.id == exchange.id })
        else { return }
        exchanges[index].error = error.localizedDescription
      }
    }
  }
}

struct AssistantSourcePassage: View {
  let answer: String
  let mail: Mail
  let openSource: () -> Void
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: "text.alignleft").font(.cove(size: 18))
        Text(mail.subject.isEmpty ? "Original email" : mail.subject)
          .font(.coveSubheading).fixedSize(horizontal: false, vertical: true)
      }
      Text(answer).font(.coveBody).foregroundStyle(Palette.body).lineSpacing(6)
        .lineLimit(expanded ? nil : 3)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if answer.count > 120 || answer.components(separatedBy: .newlines).count > 3 {
        Button(expanded ? "Show less" : "Show full passage") { expanded.toggle() }
          .buttonStyle(.plain).font(.coveControl)
          .accessibilityLabel(
            expanded ? "Collapse passage from \(mail.sender)" : "Expand passage from \(mail.sender)"
          )
      }
      Button {
        openSource()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "envelope")
          Text(mail.sender).lineLimit(1)
          Text("·")
          Text(mail.date, format: .dateTime.month(.abbreviated).day().hour().minute())
          Image(systemName: "arrow.up.right")
        }.font(.coveSecondary).foregroundStyle(Palette.body)
      }.buttonStyle(.plain).help("Read the original email")
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum AssistantFeedback: CaseIterable {
  case helpful, notHelpful
  var symbol: String { self == .helpful ? "hand.thumbsup" : "hand.thumbsdown" }
}

struct PendingCompose {
  let request: AssistantCalendar.ComposeRequest
  let question: String
  let name: String
  let candidates: [MailContact]
  var resolved = false
}

struct ChatExchange: Identifiable {
  let id = UUID()
  let question: String
  let mail: Mail?
  let scope: AssistantScope
  var passages: [MailPassage] = []
  var answer: String?
  var source: String?
  var error: String?
  var cancelled = false
  var progress: String?
  var isCalendar = false
  var eventProposal: AssistantCalendar.Proposal?
  var agenda: AssistantAgenda?
  var response: AssistantResponse?
  var eventCreated = false
  var addedEvent: LocalEvent?
  var eventDismissed = false
  var draft: AssistantDraftArtifact?
  var rememberedMemory: String?
  /// A new email waiting for the user to say which of several contacts they meant.
  var pendingCompose: PendingCompose?
  var memoryUndone = false
  var bulk: AssistantBulkState?
  var task: AssistantTaskState?
  /// The selected event's times before an approved move, for Undo.
  var movedFrom: DateInterval?
  var feedback: AssistantFeedback?
  var groundingLabel: String {
    if let bulk { return bulk.groundingLabel }
    if let task { return task.groundingLabel }
    if isCalendar {
      if eventProposal?.eventID != nil { return eventCreated ? "Event moved" : "Move ready to review" }
      return eventCreated ? "Event added" : eventProposal == nil ? "Calendar" : "Event ready to review"
    }
    if let draft { return draft.isReply ? "Reply ready to review" : "Draft ready to review" }
    if let pendingCompose { return pendingCompose.resolved ? "Recipient chosen" : "Choose who to write to" }
    if rememberedMemory != nil { return memoryUndone ? "Memory removed" : "Saved to memories" }
    let count = Set(passages.map { $0.mail.id }).count
    if count > 0 { return "\(count) email\(count == 1 ? "" : "s") used" }
    if source?.hasPrefix("Live Gmail message count") == true { return "Live Gmail count" }
    if source?.hasPrefix("Downloaded mail only") == true { return "Downloaded mail only" }
    return "Response details"
  }
}

@MainActor struct AssistantReplyReview: Identifiable {
  let id = UUID()
  let mail: Mail
  let context: [Mail]
  let recommendation: String
  let account: String
  let question: String
  init?(sourceID: String, recommendation: String, question: String, relatedIDs: [String] = [], store: AppStore) {
    guard let current = store.mails.first(where: { $0.id == sourceID }),
      current.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]) else { return nil }
    mail = current
    let related = Set(relatedIDs).subtracting([current.id])
    context = [current] + Array(store.mails.filter { related.contains($0.id) && $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]) }.prefix(19))
    self.recommendation = recommendation
    self.question = question
    account = store.accountEmail
  }
}

private struct AssistantEventReview: Identifiable {
  let id = UUID()
  let exchangeID: UUID
  let draft: CalendarEventDraft
}

struct AssistantDraftArtifact: Equatable {
  let mailID: String
  let to: String
  let subject: String
  let body: String
  let isReply: Bool
}

/// Inline approval card for a proposed event: add it right here, edit it, or let it go.
struct AssistantEventCard: View {
  let proposal: AssistantCalendar.Proposal
  let destination: String
  let added: LocalEvent?
  let dismissed: Bool
  let busy: Bool
  let add: () -> Void
  let edit: () -> Void
  let dismiss: () -> Void
  let undo: () -> Void
  let open: (LocalEvent) -> Void
  /// Moving the selected event rather than adding a new one.
  var isMove = false
  /// Shown on moves that change other people's calendars too.
  var note: String? = nil
  private var clear: Bool {
    proposal.availability.hasPrefix("No overlaps") || proposal.availability.hasPrefix("Your first free")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 0) {
          Text(proposal.start.formatted(.dateTime.month(.abbreviated)).uppercased())
            .font(.cove(size: 10, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 3).background(Palette.ink)
          Text(proposal.start.formatted(.dateTime.day())).font(.cove(size: 20, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 48, height: 52).background(Palette.canvas)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(proposal.title).font(.coveSubheading)
          Text(proposal.start.formatted(.dateTime.weekday(.wide)) + " · "
               + proposal.start.formatted(date: .omitted, time: .shortened) + " – "
               + proposal.end.formatted(date: Calendar.current.isDate(proposal.start, inSameDayAs: proposal.end) ? .omitted : .abbreviated, time: .shortened))
            .font(.coveSecondary).foregroundStyle(Palette.body)
          Label(destination, systemImage: destination == "Google Calendar" ? "calendar" : "laptopcomputer")
            .font(.coveMetadata).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 0)
      }
      Label(proposal.availability, systemImage: clear ? "checkmark.circle" : "exclamationmark.circle")
        .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      if let note, added == nil {
        Label(note, systemImage: "person.2").font(.coveMetadata).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let added {
        HStack(spacing: 12) {
          Label(isMove ? "Moved" : "Added", systemImage: "checkmark.circle.fill").font(.coveControl)
          Spacer(minLength: 0)
          Button("Undo", action: undo).buttonStyle(SecondaryButton(compact: true)).disabled(busy)
          Button("Open in Calendar") { open(added) }.buttonStyle(SecondaryButton(compact: true))
        }
      } else if dismissed {
        Text(isMove ? "Not moved." : "Not added.").font(.coveSecondary).foregroundStyle(Palette.muted)
      } else {
        HStack(spacing: 10) {
          Button { add() } label: {
            Label(isMove ? "Move event" : "Add to calendar", systemImage: isMove ? "arrow.right" : "plus")
          }.buttonStyle(PrimaryButton(compact: true)).disabled(busy)
          if !isMove { Button("Edit", action: edit).buttonStyle(SecondaryButton(compact: true)).disabled(busy) }
          Spacer(minLength: 0)
          Button("Not now", action: dismiss).buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        }
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    .accessibilityElement(children: .contain)
  }
}

/// Inline preview of a drafted email. Sending always happens in the composer or reader.
struct AssistantDraftCard: View {
  let draft: AssistantDraftArtifact
  let review: () -> Void
  let copy: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        field("To", draft.to.isEmpty ? "No recipient yet" : draft.to)
        field("Subject", draft.subject.isEmpty ? "(No subject)" : draft.subject)
      }.padding(16)
      Divider()
      Text(draft.body).font(.coveBody).lineSpacing(CoveTypography.bodyLineSpacing).lineLimit(10)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      HStack(spacing: 10) {
        Button { review() } label: { Label("Review & send", systemImage: "paperplane") }
          .buttonStyle(PrimaryButton(compact: true))
        Button("Copy", action: copy).buttonStyle(SecondaryButton(compact: true))
        Spacer(minLength: 0)
        Text(draft.isReply ? "Saved as your reply" : "Saved in Drafts").font(.coveMetadata).foregroundStyle(Palette.muted)
      }.padding(12)
    }
    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    .accessibilityElement(children: .contain)
  }
  private func field(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(name).font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 52, alignment: .leading)
      Text(value).font(.coveSecondary).foregroundStyle(Palette.ink).lineLimit(2)
    }
  }
}

/// A saved memory, shown with Undo so nothing is remembered by accident.
struct AssistantTaskState: Equatable {
  enum Phase: Equatable { case review, working, created(GoogleTask), dismissed }
  var proposal: AssistantCalendar.TaskProposal
  var phase: Phase = .review
  var archived = false
  var groundingLabel: String {
    switch phase {
    case .review, .working: "Task ready to review"
    case .created: archived ? "Task added · email archived" : "Task added"
    case .dismissed: "No task created"
    }
  }
}

/// A task Ask Cove prepared. Nothing reaches Google Tasks, and the email isn't archived, until the user clicks Add.
struct AssistantTaskCard: View {
  let state: AssistantTaskState
  let mail: Mail?
  let connected: Bool
  let connecting: Bool
  let edit: (String) -> Void
  let toggleArchive: (Bool) -> Void
  let connect: () -> Void
  let add: () -> Void
  let dismiss: () -> Void
  let undoArchive: () -> Void
  let open: () -> Void

  private var created: Bool { if case .created = state.phase { true } else { false } }
  private var editable: Bool { state.phase == .review }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: created ? "checkmark.circle.fill" : "circle").font(.cove(size: 16))
          .foregroundStyle(created ? Palette.ink : Palette.muted).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          if editable {
            TextField("Task", text: Binding(get: { state.proposal.title }, set: edit))
              .textFieldStyle(.plain).font(.coveSubheading)
          } else {
            Text(state.proposal.title).font(.coveSubheading).foregroundStyle(state.phase == .dismissed ? Palette.muted : Palette.ink)
              .strikethrough(state.phase == .dismissed)
          }
          HStack(spacing: 6) {
            Text(state.proposal.due.map { "Due " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "No due date")
            if let mail { Text("·"); Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).lineLimit(1) }
          }.font(.coveMetadata).foregroundStyle(Palette.body)
          if !state.proposal.notes.isEmpty {
            Text(state.proposal.notes).font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(3)
          }
        }
        Spacer(minLength: 0)
      }
      if mail != nil, editable {
        Toggle("Archive the email when the task is added", isOn: Binding(get: { state.proposal.archive }, set: toggleArchive))
          .toggleStyle(.checkbox).font(.coveSecondary).foregroundStyle(Palette.body)
      }
      HStack(spacing: 10) {
        switch state.phase {
        case .review, .working:
          if connected {
            Button(state.proposal.archive && mail != nil ? "Add task and archive" : "Add task", action: add)
              .buttonStyle(PrimaryButton(compact: true)).disabled(state.phase == .working || state.proposal.title.trimmingCharacters(in: .whitespaces).isEmpty)
          } else {
            Button(connecting ? "Connecting…" : "Connect Google Tasks", action: connect)
              .buttonStyle(PrimaryButton(compact: true)).disabled(connecting)
          }
          Button("Not now", action: dismiss).buttonStyle(SecondaryButton(compact: true)).disabled(state.phase == .working)
          if state.phase == .working { ProgressView().controlSize(.small) }
        case .created:
          Button("Open Tasks", action: open).buttonStyle(SecondaryButton(compact: true))
          if state.archived {
            Text("Email archived").font(.coveMetadata).foregroundStyle(Palette.body)
            Button("Undo archive", action: undoArchive).buttonStyle(SecondaryButton(compact: true))
          }
        case .dismissed:
          Text("No task created").font(.coveMetadata).foregroundStyle(Palette.muted)
        }
      }
    }
    .padding(14).frame(maxWidth: 520, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
  }
}

struct AssistantMemoryCard: View {
  let memory: String
  let undone: Bool
  let undo: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: undone ? "brain" : "brain.head.profile").font(.cove(size: 15)).foregroundStyle(Palette.body)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(undone ? "Forgotten" : "Remembered").font(.coveMetadata).foregroundStyle(Palette.muted)
        Text(memory).font(.coveSecondary).strikethrough(undone).foregroundStyle(undone ? Palette.muted : Palette.ink)
      }
      Spacer(minLength: 0)
      if !undone { Button("Undo", action: undo).buttonStyle(SecondaryButton(compact: true)) }
    }
    .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
  }
}

private struct ChatSendButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(enabled ? .white : Palette.disabledText)
      .frame(width: 34, height: 34)
      .background(
        enabled
          ? (configuration.isPressed ? Palette.pressed : hovering ? Palette.hover : Palette.ink)
          : Palette.disabled,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: 9).stroke(Palette.ink, lineWidth: 2).padding(-3)
        }
      }
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
  }
}
