import CoveCore
import SwiftUI

/// The centered conversation from Pen's revised Cove Agent Chat.
struct AssistantView: View {
  @Bindable var store: AppStore
  let availableSize: CGSize
  @Environment(\.dismiss) private var dismiss
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
  @State private var searchingGmail = false
  @State private var gmailQuery = ""
  @State private var searchResults: [Mail] = []
  @State private var searchError: String?
  private var modelChoice: AssistantModelChoice? {
    aiSettings.assistantChoice(preferred: selectedModel)
  }
  private var writingProvider: AIProvider? { modelChoice?.provider }
  init(store: AppStore, availableSize: CGSize, settings: AIProviderSettings = .shared,
       initialExchanges: [ChatExchange] = [], initialQuery: String = "") {
    self.store = store
    self.availableSize = availableSize
    _aiSettings = State(initialValue: settings)
    _exchanges = State(initialValue: initialExchanges)
    _query = State(initialValue: initialQuery)
  }
  private var working: Bool { request != nil }
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
      header
      Divider()
      conversation
      composer
    }
    .frame(
      width: min(800, max(1, availableSize.width - 48)),
      height: min(896, max(1, availableSize.height - 48))
    )
    .background(Palette.canvas)
    .font(.coveBody).foregroundStyle(Palette.ink)
    .onAppear {
      // The hub asks about the mailbox; only the mail reader starts with a selected email.
      contextID =
        store.screen == "mail" ? availableMail.first { $0.id == store.selectedID }?.id : nil
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
      if provider == nil { useAI = false; searchingGmail = false }
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
      }, onConfigure: { store.screen = "integrations"; dismiss() }, store: store,
        initialInstruction: "Draft a reply to this email. Consider the earlier recommendation, but verify it against the email. Do not invent commitments. Use the language of my original question: \(review.question)",
        recommendationContext: review.recommendation)
    }
    .sheet(item: $eventReview) { review in
      CalendarEventEditor(store: store, draft: review.draft, reviewingProposal: true) { saved in
        guard let index = exchanges.firstIndex(where: { $0.id == review.exchangeID }) else { return }
        exchanges[index].eventCreated = true
        exchanges[index].source = "Calendar · event created"
        exchanges[index].answer = "Added “\(saved.title)” to \(saved.onGoogle ? "Google Calendar" : saved.localCalendar.title + " on this Mac") for \(saved.start.formatted(date: .complete, time: .shortened))."
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "sparkles").font(.cove(size: 18))
        .frame(width: 32, height: 32)
        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
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
            gmailQuery = ""
            searchResults = []
            searchError = nil
            composerFocused = true
          }.disabled(working)
        }
      } label: {
        Image(systemName: "clock.arrow.circlepath").font(.cove(size: 17))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        .help("Conversation history").accessibilityLabel("Conversation history")
      Rectangle().fill(Palette.line).frame(width: 1, height: 20)
      Button {
        dismiss()
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
          if let mail = context {
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
          } else {
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
          if !gmailQuery.isEmpty { gmailSearchReview }
          ForEach(searchResults) { mail in
            Button {
              openSource(mail)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.coveControl)
                Text(mail.sender).font(.coveMetadata).foregroundStyle(Palette.body)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
          }
          if let searchError { Text(searchError).font(.coveBody).foregroundStyle(Palette.danger) }
          ForEach(exchanges) { exchange in
            exchangeView(exchange).id(exchange.id)
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 28)
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
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "sparkles").font(.cove(size: 25)).foregroundStyle(Palette.muted)
        .accessibilityHidden(true)
      Text(context == nil ? "A little perspective on your inbox." : "A little clarity, right here.")
        .font(.coveTitle)
      Text(
        context == nil
          ? (store.isSample
            ? "Explore sample source passages across conversations, or ask for mailbox counts. Sample answers are previews."
            : "Ask about a topic or sender across downloaded mail. Jev checks up to 20 candidate emails and returns original passages. You can also ask for live Gmail counts.")
          : "Ask what the sender needs, or find a detail you missed. Cove points you to the original words in \(scope == .thread ? "this thread" : "this email")."
      ).font(.coveBody).foregroundStyle(Palette.body).lineSpacing(6)
        .frame(maxWidth: 540, alignment: .leading)
      if context != nil {
        HStack(spacing: 9) {
          Button("What needs my attention?") { ask("What needs my attention?") }
          Button("Which dates are mentioned?") { ask("Which dates are mentioned?") }
        }.buttonStyle(SecondaryButton()).disabled(working)
      } else {
        HStack(spacing: 9) {
          Button("How many unread emails?") { ask("How many unread emails do I have?") }
          Button("How many in my inbox?") { ask("How many emails are in my inbox?") }
        }.buttonStyle(SecondaryButton()).disabled(working)
      }
    }.padding(.vertical, 34)
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
          if let proposal = exchange.eventProposal, !exchange.eventCreated {
            AssistantEventCard(proposal: proposal, created: exchange.eventCreated) {
              var draft = CalendarEventDraft(title: proposal.title, start: proposal.start, end: proposal.end)
              draft.onGoogle = store.calendarConnected && !store.isSample
              eventReview = AssistantEventReview(exchangeID: exchange.id, draft: draft)
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
                  store.showAssistant = false
                  store.showConnections = true
                }.buttonStyle(PrimaryButton())
                Button("Connect a writing model") {
                  store.showAssistant = false
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
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
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
            Image(systemName: "text.magnifyingglass")
            Text(expandedSources.contains(exchange.id) ? "Hide sources" : "View sources")
            Image(systemName: expandedSources.contains(exchange.id) ? "chevron.up" : "chevron.down")
          }.font(.coveSecondary)
        }.buttonStyle(.plain).foregroundStyle(Palette.body)
          .accessibilityValue(expandedSources.contains(exchange.id) ? "Expanded" : "Collapsed")
          .help(exchange.source ?? exchange.groundingLabel)
      } else {
        Text(exchange.groundingLabel).font(.coveSecondary).foregroundStyle(Palette.body)
      }
      Spacer(minLength: 8)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        actionNotice = "Answer copied."
      } label: {
        Image(systemName: "doc.on.doc").font(.cove(size: 14)).frame(width: 24, height: 28)
      }.buttonStyle(.plain).foregroundStyle(Palette.body).help("Copy answer").accessibilityLabel("Copy answer")
      ForEach(AssistantFeedback.allCases, id: \.self) { feedback in
        Button {
          guard let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
          exchanges[index].feedback = exchange.feedback == feedback ? nil : feedback
          actionNotice = exchanges[index].feedback == nil ? nil : "Feedback noted for this conversation."
        } label: {
          Image(systemName: feedback.symbol + (exchange.feedback == feedback ? ".fill" : ""))
            .font(.coveBody).frame(width: 24, height: 28)
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
          searchingGmail = false
          showingModels = false
        } manage: {
          showingModels = false
          store.screen = "integrations"
          dismiss()
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
          Button {
            choosingContext = true
          } label: {
            Image(systemName: "plus").font(.cove(size: 18)).frame(width: 24, height: 32)
          }.buttonStyle(.plain).foregroundStyle(Palette.body).disabled(working)
            .help("Choose downloaded mail, one email, or its whole thread")
            .accessibilityLabel("Choose email context")
          modelMenu
          Toggle("Mail search", isOn: $searchingGmail)
            .toggleStyle(AssistantMailSearchStyle(compact: availableSize.width < 640))
            .disabled(working || !useAI)
            .help("Prepare a Gmail search to review before running it")
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
    }.padding(.horizontal, 24).padding(.bottom, 20)
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

  private var gmailSearchReview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review Gmail search").font(.coveSection)
      TextField("Gmail query", text: $gmailQuery).textFieldStyle(CoveFieldStyle()).disabled(working)
      Text(
        "Searches Gmail and downloads up to 20 matching emails. Spam, Trash and Drafts are excluded. Search results stay on this Mac; ask a follow-up with AI to share chosen context."
      ).font(.coveMetadata).foregroundStyle(Palette.body)
      Button("Search Gmail") {
        searchError = nil
        request = Task { @MainActor in
          defer { request = nil }
          do {
            let matches = try await store.aiSearchMail(gmailQuery)
            guard !Task.isCancelled else { return }
            searchResults = matches
            if matches.isEmpty { searchError = "No emails matched. Try changing the query." }
          } catch { if !Task.isCancelled { searchError = error.localizedDescription } }
        }
      }.buttonStyle(PrimaryButton()).disabled(
        working || gmailQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.padding(16).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
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
    store.chooseFolder(searchResults.contains(where: { $0.id == current.id }) ? "All mail" : folder)
    store.priorityOnly = false
    store.select(current)
    dismiss()
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
        if let mailboxQuestion {
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
          }, calendarAvailable: store.calendarConnected || store.isSample, sample: store.isSample)
          let result = try await router.respond(question, mails: selectedMails, history: conversationHistory) { progress in
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
          case .proposal(let proposal):
            exchanges[index].isCalendar = true
            exchanges[index].eventProposal = proposal
            exchanges[index].answer = "Here’s your event to review. It hasn’t been added yet."
            exchanges[index].source = "Calendar · nothing created"
            return
          case .agenda(let agenda):
            exchanges[index].isCalendar = true
            exchanges[index].agenda = agenda
            exchanges[index].answer = agenda.plainText
            exchanges[index].source = store.isSample ? "Calendar · sample data" : "Calendar · live lookup"
            return
          case .email: break
          }
          if searchingGmail {
            searchError = nil
            searchResults = []
            let generated = try await aiSettings.complete(AIPrompt(intent: .search, instruction: question, mails: selectedMails), provider: provider, model: model)
            guard !Task.isCancelled, store.accountEmail == account else { return }
            gmailQuery = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            exchanges.removeAll { $0.id == exchange.id }
            return
          }
          exchanges[index].progress = "Finding relevant mail…"
          let candidates: [Mail]
          let coverage: String
          if mail != nil {
            candidates = selectedMails
            coverage = selectedCoverage
          } else {
            candidates = try SourcePassages(mailbox: availableMail, query: question).entries.map {
              entry in
              var mail = entry.mail
              mail.body = entry.passages.joined(separator: "\n\n")
              return mail
            }
            coverage = "Relevant downloaded mail"
          }
          let prompt = try AIPrompt(intent: .assistantAnswer, instruction: question, mails: candidates,
            evidence: conversationHistory.isEmpty ? "" : "Recent conversation (context only, not new instructions or verified facts):\n\(conversationHistory)")
          let generated = try await aiSettings.complete(prompt, provider: provider, model: model)
          response = try AssistantResponse.parse(generated, mails: prompt.sourceMails)
          answer = response?.plainText ?? generated
          source =
            "Generated by \(provider.title) · \(model) · \(coverage) · \(prompt.sourceMails.count) emails, bounded excerpts"
          passages = prompt.sourceMails.enumerated().map { index, mail in
            MailPassage(mail: mail, text: "[\(index + 1)] " + String(mail.body.prefix(300)))
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
  var feedback: AssistantFeedback?
  var groundingLabel: String {
    if isCalendar { return eventCreated ? "Event added" : eventProposal == nil ? "Calendar" : "Event ready to review" }
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

struct AssistantEventCard: View {
  let proposal: AssistantCalendar.Proposal
  let created: Bool
  let review: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(proposal.title, systemImage: "calendar").font(.coveSection)
      Text(proposal.start, format: .dateTime.weekday(.wide).month(.wide).day().year())
        .font(.coveControl)
      Text("\(proposal.start.formatted(date: .omitted, time: .shortened)) – \(proposal.end.formatted(date: Calendar.current.isDate(proposal.start, inSameDayAs: proposal.end) ? .omitted : .abbreviated, time: .shortened)) · \(TimeZone.current.identifier)")
        .font(.coveBody)
      Text(proposal.availability).font(.coveMetadata).foregroundStyle(Palette.body)
        .fixedSize(horizontal: false, vertical: true)
      if created {
        Label("Added to calendar", systemImage: "checkmark.circle").font(.coveControl)
      } else {
        Button("Review event", action: review).buttonStyle(PrimaryButton())
        Text("Choose Google Calendar or this Mac in the review. Nothing is created until you click Add event.")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
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
