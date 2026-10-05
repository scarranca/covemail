#if os(iOS)
import CoveCore
import SwiftUI

/// Ask Cove (⌘J on the Mac): questions about mail on this iPhone, upcoming events and open tasks.
/// It reads; it never sends, deletes or changes anything. Sources open the email they came from.
struct MobileAssistantView: View {
  let ai: MobileAI
  let mailbox: MobileMailbox
  let workspace: MobileWorkspace
  let openMail: (String) -> Void
  @State private var turns: [Turn] = []
  @State private var question = ""
  @State private var running: Task<Void, Never>?
  @FocusState private var focused: Bool
  @Environment(\.dismiss) private var dismiss

  struct Turn: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var sources: [Mail] = []
    var error: String?
  }

  private let suggestions = ["What needs my attention today?", "Who is waiting on a reply from me?", "What’s on my calendar this week?"]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles").font(.system(size: 18, weight: .medium))
          .frame(width: 32, height: 32).background(MobilePalette.sidebar, in: Circle())
        Text("Ask Cove").font(.coveMobile(16, weight: .semibold))
        Spacer()
        Button { running?.cancel(); dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(MobileIconButton()).accessibilityLabel("Close")
      }
      .foregroundStyle(MobilePalette.ink)
      .padding(.horizontal, 20).padding(.vertical, 14)
      Divider().overlay(MobilePalette.line)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if turns.isEmpty { welcome }
            ForEach(turns) { turn in turnView(turn).id(turn.id) }
          }.padding(20)
        }
        .onChange(of: turns.last?.answer) { _, _ in
          if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
      composer
    }
    .background(MobilePalette.canvas)
    .presentationDragIndicator(.visible)
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Ask about your mail, calendar and tasks.").font(.mobileSection)
      Text("Cove reads the mail on this iPhone, your upcoming events and what you told it in About you. It can’t send, delete or change anything. Say “remember …” to add a note.")
        .font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(suggestions, id: \.self) { suggestion in
          Button(suggestion) { question = suggestion; ask() }
            .buttonStyle(MobileSecondaryButton(compact: true)).disabled(!ai.ready)
        }
      }
      if !ai.ready {
        Text("Choose an AI model in Settings → Writing and Ask Cove first. Apple Intelligence works on this iPhone with no account.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func turnView(_ turn: Turn) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(turn.question).font(.mobileBody).foregroundStyle(MobilePalette.ink)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .trailing)
      VStack(alignment: .leading, spacing: 14) {
        if turn.answer.isEmpty && turn.error == nil {
          HStack(spacing: 8) { ProgressView(); Text("Reading your mail…") }
            .font(.mobileSecondary).foregroundStyle(MobilePalette.body)
        }
        if !turn.answer.isEmpty {
          Text(MobileAskCoveView.markdown(turn.answer)).font(.mobileBody).foregroundStyle(MobilePalette.ink).lineSpacing(4)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let error = turn.error {
          Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger).fixedSize(horizontal: false, vertical: true)
        }
        if !turn.sources.isEmpty && !turn.answer.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.mobileCaption).foregroundStyle(MobilePalette.muted)
            ForEach(Array(turn.sources.prefix(6).enumerated()), id: \.element.id) { index, mail in
              Button { openMail(mail.id) } label: {
                HStack(spacing: 8) {
                  Text("\(index + 1)").font(.mobileCaption).frame(width: 20, height: 20)
                    .background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 4))
                  VStack(alignment: .leading, spacing: 1) {
                    Text(mail.subject.isEmpty ? "(No subject)" : mail.subject).font(.mobileLabel).lineLimit(1)
                    Text((mail.sender.isEmpty ? mail.senderEmail : mail.sender) + " · " + MobileDates.short(mail.date))
                      .font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
                  }
                  Spacer()
                  Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(MobilePalette.muted)
                }.foregroundStyle(MobilePalette.ink).contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
        }
        if !turn.answer.isEmpty {
          HStack {
            Button { UIPasteboard.general.string = turn.answer } label: { Label("Copy", systemImage: "doc.on.doc") }
              .font(.mobileControl).foregroundStyle(MobilePalette.body)
            Spacer()
            Text(ai.modelLabel(ai.model(ai.provider), provider: ai.provider)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
        }
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(MobilePalette.line))
    }
  }

  private var composer: some View {
    VStack(spacing: 8) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField(turns.isEmpty ? "Ask Cove anything about your mail…" : "Ask a follow-up…", text: $question, axis: .vertical)
          .lineLimit(1...4).font(.mobileBody).focused($focused).onSubmit(ask)
        Button(action: running == nil ? ask : { running?.cancel() }) {
          Image(systemName: running == nil ? "arrow.up" : "stop.fill").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(canAsk || running != nil ? Color.white : MobilePalette.disabledText)
            .frame(width: 34, height: 34)
            .background(canAsk || running != nil ? MobilePalette.ink : MobilePalette.disabled, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!canAsk && running == nil).accessibilityLabel(running == nil ? "Ask" : "Stop")
      }
      .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? MobilePalette.ink : MobilePalette.inputBorder))
      Label("Reads mail on this iPhone · nothing is sent without your approval", systemImage: "checkmark.shield")
        .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private var canAsk: Bool { ai.ready && !question.trimmingCharacters(in: .whitespaces).isEmpty }

  private func ask() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, running == nil, ai.ready else { return }
    question = ""
    if let command = PersonalContext.command(in: text) {
      turns.append(Turn(question: text, answer: MobileMe.shared.handle(command)))
      return
    }
    // Evidence: matching mail on this iPhone, else (and for follow-ups) the previous sources and recent Inbox.
    var sources = mailbox.localMatches(text, limit: 8)
    if sources.count < 3 {
      let previous = turns.last?.sources ?? []
      let recent = mailbox.inbox.prefix(10)
      for mail in previous + recent where !sources.contains(where: { $0.id == mail.id }) && sources.count < 10 {
        sources.append(mail)
      }
    }
    let history = turns.suffix(2).map { "Earlier question: \($0.question)\nEarlier answer: \(String($0.answer.prefix(600)))" }
      .joined(separator: "\n\n")
    let instruction = (history.isEmpty ? "" : history + "\n\nCurrent question: ") + text
    turns.append(Turn(question: text, sources: sources))
    let index = turns.count - 1
    let evidence = (MobileMe.shared.prompt.map { $0 + "\n\n" } ?? "") + Self.evidence(events: workspace.events, tasks: workspace.openTasks)
    let mails = sources
    running = Task {
      defer { running = nil }
      do {
        let prompt = try AIPrompt(intent: .answer, instruction: instruction, mails: mails, evidence: evidence)
        let result = try await ai.complete(prompt) { partial in if turns.indices.contains(index) { turns[index].answer = partial } }
        if turns.indices.contains(index) { turns[index].answer = result }
      } catch is CancellationError {
        if turns.indices.contains(index), turns[index].answer.isEmpty { turns[index].error = "Stopped." }
      } catch {
        if turns.indices.contains(index) {
          turns[index].error = error.localizedDescription + " (" + ai.modelLabel(ai.model(ai.provider), provider: ai.provider) + ")"
        }
      }
    }
  }

  /// Upcoming events (next 7 days) and open tasks as plain lookup evidence, labeled as partial.
  static func evidence(events: [LocalEvent], tasks: [GoogleTask]) -> String {
    let now = Date()
    let week = now.addingTimeInterval(7 * 86_400)
    let upcoming = events.filter { $0.end > now && $0.start < week }.prefix(20).map {
      "- \($0.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))–\($0.end.formatted(date: .omitted, time: .shortened)): \($0.title)"
        + ($0.isPendingInvitation ? " (invitation, not answered)" : "")
    }
    let open = tasks.prefix(20).map { "- \($0.title)" + ($0.dueDay.map { " (due \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "") }
    var parts: [String] = []
    if !upcoming.isEmpty { parts.append("Calendar, next 7 days (time zone \(TimeZone.current.identifier); partial):\n" + upcoming.joined(separator: "\n")) }
    if !open.isEmpty { parts.append("Open Google Tasks:\n" + open.joined(separator: "\n")) }
    parts.append("Now: \(now.formatted(date: .complete, time: .shortened))")
    return parts.joined(separator: "\n\n")
  }
}
#endif
