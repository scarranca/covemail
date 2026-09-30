import CoveCore
import SwiftUI

/// Reply entry point. Compose embeds the same panel beside the message instead of opening a second sheet.
struct AIWritingSheet: View {
  let context: [Mail]
  let initialText: String
  let onInsert: (String) -> Void
  var onConfigure: (() -> Void)? = nil
  var store: AppStore? = nil
  var initialInstruction = ""
  var recommendationContext = ""
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Write with Cove").font(.coveSection)
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(SecondaryButton())
      }.padding(20)
      Divider()
      AIWritingPanel(draft: $draft, context: context, availableContext: store?.mails ?? [], voice: store?.preferences.voice ?? "Natural and concise", instructions: store?.preferences.instructions ?? [], voiceProfile: store?.preferences.voiceProfile, memories: store?.preferences.memoryPrompt, store: store, initialInstruction: initialInstruction, recommendationContext: recommendationContext, envelope: "Reply to: \(context.first?.replyRecipient ?? "")\nSubject: \(context.first?.subject ?? "")", onApply: { value in
        onInsert(value)
        dismiss()
      }, onConfigure: {
        dismiss()
        onConfigure?()
      })
    }.frame(width: 440, height: 660).background(Palette.canvas).foregroundStyle(Palette.ink)
      .onAppear { draft = initialText }
  }
}

struct AIWritingPanel: View {
  @Binding var draft: String
  var selection: NSRange = NSRange(location: 0, length: 0)
  var context: [Mail] = []
  var availableContext: [Mail] = []
  var voice = "Natural and concise"
  var instructions: [String] = []
  var voiceProfile: VoiceProfile?
  var memories: String?
  var store: AppStore? = nil
  var initialInstruction = ""
  var recommendationContext = ""
  var envelope = ""
  var envelopeIdentity: String? = nil
  var activity: WritingActivity? = nil
  var reviewOnCanvas = false
  /// One "ask" line with a tools menu, living inside the editor it writes for. The suggestion is
  /// previewed on that editor's canvas (via `activity`), never in a separate panel.
  var inline = false
  /// Inline only: closes the ask line (Esc or ✕) when nothing is pending.
  var onClose: (() -> Void)? = nil
  @FocusState private var askFocused: Bool
  var providerSettings: AIProviderSettings? = nil
  let onApply: (String) -> Void
  var onConfigure: (() -> Void)? = nil
  @State private var settings = AIProviderSettings.shared
  @State private var instruction = ""
  @State private var suggestion: ComposeSuggestion?
  @State private var writingSession = WritingSession()
  @State private var error: String?
  @State private var failedAttempt: WritingAttempt?
  @State private var attemptedModel = ""
  @State private var task: Task<Void, Never>?
  @State private var includedIDs = Set<String>()
  @State private var excludedIDs = Set<String>()
  @State private var contextPicker = false
  @State private var contextQuery = ""
  @State private var translate = false
  @State private var language = "Spanish"
  @State private var targetSelection = true
  @State private var reviewSelection = NSRange(location: 0, length: 0)
  @State private var usedSources: [Mail] = []
  @State private var lookupEnabled = true
  @State private var lookupActivity: [String] = []
  @State private var workingStage = "Preparing your draft"
  @State private var streamingText = ""
  @State private var useRecipientContext = true


  private var selectedMails: [Mail] {
    var seen = Set<String>()
    return ((useRecipientContext ? context : []) + availableContext.filter { includedIDs.contains($0.id) }).filter {
      !excludedIDs.contains($0.id) && seen.insert($0.id).inserted
    }
  }
  private var hasSelection: Bool { selection.length > 0 && Range(selection, in: draft) != nil }
  private var activeSettings: AIProviderSettings { providerSettings ?? settings }
  private var pendingSelection: NSRange { activity?.previewSelection ?? reviewSelection }
  private var writingProvider: AIProvider? { activeSettings.writingProvider() }
  private var canGenerate: Bool {
    task == nil && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && writingProvider != nil
  }

  var body: some View {
    Group {
      if inline { inlineBar } else { fullPanel }
    }
      .onAppear { if instruction.isEmpty { instruction = initialInstruction } }
      .task { await activeSettings.restoreWritingConnection() }
      .onDisappear { task?.cancel(); activity?.reset() }
      .onChange(of: envelopeIdentity ?? envelope) { _, _ in
        task?.cancel(); suggestion = nil; activity?.reset(); lookupActivity = []; writingSession = WritingSession(); error = nil; failedAttempt = nil
      }
      .onChange(of: store?.accountEmail) { _, _ in
        task?.cancel(); suggestion = nil; activity?.reset(); lookupActivity = []; writingSession = WritingSession(); error = nil; failedAttempt = nil
      }
      .onChange(of: activity?.applyRequest) { _, _ in
        guard task == nil else { return }
        apply()
      }
      .onChange(of: activity?.discardRequest) { _, _ in discardSuggestion() }
      .onChange(of: activity?.focusRequest) { _, _ in askFocused = true }
      .onChange(of: error) { _, value in activity?.needsAttention = value != nil }
      .onChange(of: activity?.rewriteRequest) { _, _ in
        generate(refining: suggestion != nil,
          request: "Rewrite the selected passage in my voice for clarity and flow. Preserve its meaning, facts, and commitments.",
          requireSelection: true)
      }
      .onChange(of: suggestion?.text) { _, text in activity?.preview = text }
      .onChange(of: activity?.preview) { _, text in
        if let text, suggestion != nil, suggestion?.text != text { suggestion?.text = text }
      }
      .popover(isPresented: $contextPicker) { contextSelection }
      .popover(isPresented: $translate) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Translate into").font(.coveSection)
          TextField("Language", text: $language).textFieldStyle(CoveFieldStyle())
          Button("Use instruction") {
            instruction = "Translate this draft into \(language). Preserve the meaning and tone."
            translate = false
          }.buttonStyle(PrimaryButton()).disabled(language.trimmingCharacters(in: .whitespaces).isEmpty)
        }.padding(20).frame(width: 300)
      }
  }

  private static let disclosure = "Your draft, recipients, writing preferences and chosen context go to your writing provider. Lookups can include relevant mail and calendar events. Nothing sends automatically."

  private func discardSuggestion() {
    task?.cancel()
    suggestion = nil; error = nil; activity?.preview = nil; writingSession = WritingSession(); lookupActivity = []
  }

  private var inlineBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.danger)
          Text(error).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if failedAttempt != nil { Button("Retry", action: retryFailedAttempt).buttonStyle(.plain).font(.coveControl) }
          if let onConfigure { Button("Settings", action: onConfigure).buttonStyle(.plain).font(.coveControl) }
        }.font(.coveMetadata).foregroundStyle(Palette.body)
      }
      if writingProvider == nil {
        HStack(spacing: 10) {
          Image(systemName: "sparkles").foregroundStyle(Palette.body)
          Text("Connect a writing model to write with AI.").font(.coveSecondary).foregroundStyle(Palette.body)
          Spacer(minLength: 0)
          if let onConfigure { Button("Connect", action: onConfigure).buttonStyle(.plain).font(.coveControl) }
        }.frame(minHeight: 40)
      } else {
        if task != nil { WritingThinkingBar(stage: workingStage).transition(.opacity) }
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: "sparkles").font(.cove(size: 14)).foregroundStyle(Palette.body)
            .help(Self.disclosure).accessibilityLabel("About AI writing").accessibilityValue(Self.disclosure)
          TextField(suggestion != nil ? "Ask for a change…" : hasSelection ? "Ask Cove to change the selected text…" : "Ask Cove to write or change this…",
                    text: $instruction, axis: .vertical)
            .lineLimit(1...4).textFieldStyle(.plain).font(.coveBody)
            .onSubmit { if canGenerate { generate(refining: suggestion != nil) } }
            .focused($askFocused).onExitCommand { if task == nil && suggestion == nil { onClose?() } }
            .disabled(task != nil).accessibilityLabel("Writing instructions")
          toolsMenu
          if task != nil {
            Button { task?.cancel() } label: {
              Image(systemName: "stop.fill").font(.cove(size: 10)).frame(width: 28, height: 28)
                .background(Palette.ink, in: Circle()).foregroundStyle(.white)
            }.buttonStyle(.plain).help("Stop writing").accessibilityLabel("Stop writing")
          } else {
            Button { generate(refining: suggestion != nil) } label: {
              Image(systemName: "arrow.up").font(.cove(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                .background(canGenerate ? Palette.ink : Palette.disabled, in: Circle())
                .foregroundStyle(canGenerate ? Color.white : Palette.disabledText)
            }.buttonStyle(.plain).disabled(!canGenerate).help("Write (Return)").accessibilityLabel("Write with AI")
            if let onClose, suggestion == nil {
              Button(action: onClose) {
                Image(systemName: "xmark").font(.cove(size: 11)).foregroundStyle(Palette.muted).frame(width: 22, height: 28)
              }.buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close AI writing")
            }
          }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6).frame(minHeight: 40)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(task != nil ? Palette.inputBorder : Palette.line))
      }
    }
  }

  private var toolsMenu: some View {
    Menu {
      let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && suggestion == nil
      Text(hasSelection ? "Selected text" : "Whole draft")
      Group {
        Button("Rewrite", systemImage: "arrow.triangle.2.circlepath") { runTool("Rewrite this in my voice for clarity and flow. Preserve its meaning, facts, and commitments.") }
        Button("Fix grammar", systemImage: "textformat.abc") { runTool("Correct grammar, punctuation, and spelling only. Preserve the voice and meaning.") }
        Button("Polish", systemImage: "sparkles") { runTool("Polish this draft for clarity and flow. Preserve its meaning.") }
        Button("Shorten", systemImage: "text.alignleft") { runTool("Make this draft shorter. Keep all questions, facts, dates, and commitments.") }
        Button("Match my voice", systemImage: "waveform") { runTool("Rewrite this draft using my saved writing voice and preferences.") }
        Menu("Change tone") {
          ForEach(["Warm", "Professional", "Direct"], id: \.self) { tone in
            Button(tone) { runTool("Rewrite this draft in a \(tone.lowercased()) tone. Preserve the meaning.") }
          }
        }
        Menu("Translate") {
          ForEach(["English", "Spanish", "Portuguese", "French", "German"], id: \.self) { language in
            Button(language) { runTool("Translate this draft into \(language). Preserve the meaning and tone.") }
          }
          Button("Other language…") { translate = true }
        }
        Button("Check before send", systemImage: "checkmark.shield") {
          runTool("Correct grammar and ambiguous wording. Preserve facts and commitments; leave uncertain details as questions instead of inventing them.")
        }
      }.disabled(empty)
      Divider()
      if store != nil { Toggle("Look up mail and dates", isOn: $lookupEnabled) }
      if !context.isEmpty { Toggle("Use this conversation", isOn: $useRecipientContext) }
      if !availableContext.isEmpty {
        Button("Add an email as context…", systemImage: "plus") { contextPicker = true }.disabled(selectedMails.count >= 20)
      }
    } label: {
      Image(systemName: "slider.horizontal.3").font(.cove(size: 13)).foregroundStyle(Palette.body)
        .frame(width: 28, height: 28).contentShape(Rectangle())
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .disabled(task != nil).help("Writing tools and context").accessibilityLabel("Writing tools")
  }

  private var fullPanel: some View {
    VStack(spacing: 0) {
      if let error {
        WritingFailureNotice(message: error, model: attemptedModel,
          onRetry: failedAttempt == nil ? nil : retryFailedAttempt, onConfigure: onConfigure)
      }
      ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Label(task != nil ? (suggestion == nil ? "Writing your draft" : "Updating your draft") : (suggestion == nil ? "Make it sound like you." : "Your draft is ready"), systemImage: "sparkles")
          .font(.coveSection)
        if suggestion == nil { voiceSummary }
        else { Label("Your voice · \(voice)", systemImage: "waveform").font(.coveMetadata).foregroundStyle(Palette.body) }
        if let suggestion {
          review(suggestion)
        } else if writingProvider != nil {
          instructionComposer
          contextControls
          writingTools
        }
        if suggestion != nil && (!usedSources.isEmpty || !lookupActivity.isEmpty) {
          DisclosureGroup("Sources & checks") {
            VStack(alignment: .leading, spacing: 12) {
              if !usedSources.isEmpty {
                Text("\(usedSources.count) emails used").font(.coveControl)
                ForEach(usedSources) { mail in
                  Text("\(mail.sender) · \(mail.subject)").font(.coveMetadata)
                    .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
                }
              }
              ForEach(Array(lookupActivity.enumerated()), id: \.offset) { _, line in
                Text(line).font(.coveMetadata).foregroundStyle(Palette.body)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }.padding(.top, 10)
          }.font(.coveMetadata).disclosureGroupStyle(CoveDisclosureStyle())
        }
        Text(suggestion == nil
             ? "Your draft, recipients, writing preferences, and the context shown here are shared with your writing provider. Lookups can include relevant mail and calendar events. Nothing sends automatically."
             : "Your email hasn’t changed yet. Applying a suggestion can be undone. Nothing sends automatically.")
          .font(.coveMetadata).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.background(Palette.surface)
  }

  private var voiceSummary: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("Your voice · \(voice)", systemImage: "waveform").font(.coveControl)
      if writingProvider == nil {
        Text("Connect a writing provider and save a model in Integrations to get started.").font(.coveMetadata).foregroundStyle(Palette.body)
        if let onConfigure {
          Button("Open writing settings", action: onConfigure).buttonStyle(SecondaryButton())
        }
      } else {
        Text("Your saved writing preferences are applied.").font(.coveMetadata).foregroundStyle(Palette.body)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var progressRow: some View {
    VStack(alignment: .leading, spacing: 10) {
      WritingProgressRow(stage: workingStage) { task?.cancel() }
      if !streamingText.isEmpty && !reviewOnCanvas {
        Text(streamingText).font(.coveBody).lineSpacing(6).foregroundStyle(Palette.body)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel("Draft being written")
      }
    }
  }

  private var instructionComposer: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What would you like to say?").font(.coveControl)
      TextField("Describe your message or a change…", text: $instruction, axis: .vertical)
        .lineLimit(3...6).textFieldStyle(CoveFieldStyle())
        .accessibilityLabel("Writing instructions").disabled(task != nil)
      if hasSelection {
        Toggle("Rewrite selected text only", isOn: $targetSelection)
          .toggleStyle(CoveToggleStyle()).font(.coveControl).disabled(task != nil)
      }
      if task != nil {
        progressRow
      } else {
        HStack {
          Spacer(minLength: 0)
          Button(hasSelection && targetSelection ? "Rewrite selection" : "Draft in my voice", systemImage: "sparkles") { generate() }
            .buttonStyle(PrimaryButton()).disabled(!canGenerate)
        }
      }
    }
  }

  private var contextControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Use context").font(.coveControl)
        Spacer()
        if !availableContext.isEmpty {
          Button("Add context", systemImage: "plus") { contextPicker = true }
            .buttonStyle(.plain).font(.coveControl).disabled(task != nil || selectedMails.count >= 20)
        }
      }
      if !context.isEmpty {
        Toggle("Recent conversation context", isOn: $useRecipientContext)
          .toggleStyle(CoveToggleStyle()).font(.coveMetadata).disabled(task != nil)
      }
      if store != nil {
        Toggle("Look up mail and dates", isOn: $lookupEnabled)
          .toggleStyle(CoveToggleStyle()).font(.coveMetadata).disabled(task != nil)
        Text("Cove can search Gmail and check your connected Calendar while drafting.")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      ForEach(selectedMails.prefix(20)) { mail in
        HStack(spacing: 8) {
          Image(systemName: "envelope").foregroundStyle(Palette.body)
          Text(mail.subject.isEmpty ? "No subject" : mail.subject).lineLimit(1)
          Spacer(minLength: 0)
          Button {
            includedIDs.remove(mail.id)
            excludedIDs.insert(mail.id)
          } label: { Image(systemName: "xmark").padding(4).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel("Remove context: \(mail.subject)").disabled(task != nil)
        }.font(.coveMetadata).padding(9).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
      }
      Text(selectedMails.isEmpty ? "Choose a recipient to include recent conversations, or add an email." : "Included before lookups. Cove uses up to 20 emails in total.")
        .font(.coveMetadata).foregroundStyle(Palette.body)
    }
  }

  private var contextSelection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose email context").font(.coveSection)
      TextField("Search subject or sender", text: $contextQuery).textFieldStyle(CoveFieldStyle())
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(availableContext.filter {
            !$0.labels.contains("DRAFT") && !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM")
              && (contextQuery.isEmpty || ($0.subject + $0.sender).localizedCaseInsensitiveContains(contextQuery))
          }.prefix(50)) { mail in
            Button {
              includedIDs.insert(mail.id)
              excludedIDs.remove(mail.id)
              contextPicker = false
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(mail.subject.isEmpty ? "No subject" : mail.subject).font(.coveControl).lineLimit(1)
                Text(mail.sender).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider()
          }
        }
      }.frame(height: 280)
    }.padding(18).frame(width: 350)
  }

  private var writingTools: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Give this draft a little help").font(.coveControl)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        tool("Polish", "sparkles", "Polish this draft for clarity and flow. Preserve its meaning.")
        tool("Shorten", "text.alignleft", "Make this draft shorter. Keep all questions, facts, dates, and commitments.")
        tool("Match my voice", "waveform", "Rewrite this draft using my saved writing voice and preferences.")
        Menu {
          ForEach(["Warm", "Professional", "Direct"], id: \.self) { tone in
            Button(tone) { runTool("Rewrite this draft in a \(tone.lowercased()) tone. Preserve the meaning.") }
          }
        } label: { toolLabel("Change tone", "slider.horizontal.3") }.menuStyle(.borderlessButton)
          .disabled(task != nil)
        Button { translate = true } label: { toolLabel("Translate", "globe") }.buttonStyle(.plain).disabled(task != nil)
        tool("Check before send", "checkmark.shield", "Correct grammar and ambiguous wording. Preserve facts and commitments; leave uncertain details as questions instead of inventing them.")
      }
      Menu("More writing tools") {
        Button("Expand") { runTool("Expand this draft for clarity without adding facts or commitments.") }
        Button("Fix grammar") { runTool("Correct grammar, punctuation, and spelling only. Preserve the voice and meaning.") }
      }.menuStyle(.borderlessButton).font(.coveMetadata).disabled(task != nil)
    }
  }

  private func tool(_ title: String, _ icon: String, _ prompt: String) -> some View {
    Button { runTool(prompt) } label: { toolLabel(title, icon) }
      .buttonStyle(.plain).disabled(task != nil)
  }
  private func runTool(_ prompt: String) {
    instruction = prompt
    generate(refining: suggestion != nil, request: prompt)
  }
  private func toolLabel(_ title: String, _ icon: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icon)
      Text(title).lineLimit(2)
      Spacer(minLength: 0)
    }.font(.coveMetadata).padding(10).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
      .contentShape(Rectangle())
  }

  private func review(_ value: ComposeSuggestion) -> some View {
    AIWritingReview(value: value, text: Binding(get: { suggestion?.text ?? "" }, set: { suggestion?.text = $0 }),
      instruction: $instruction, provider: "", working: task != nil, canRefine: canGenerate,
      onApply: apply, onKeep: { suggestion = nil; error = nil; activity?.preview = nil; writingSession = WritingSession(); lookupActivity = [] },
      onRefine: { generate(refining: true) }, onStop: { task?.cancel() },
      inlinePreview: !reviewOnCanvas, stage: workingStage, lastRequest: writingSession.requests.last ?? "",
      selection: Binding(get: { pendingSelection }, set: { range in
        reviewSelection = range; activity?.previewSelection = range
      }))
  }

  private func apply() {
    guard var suggestion else { return }
    if let preview = activity?.preview { suggestion.text = preview }
    do {
      let replacement = try suggestion.applying(to: draft)
      onApply(replacement)
      self.suggestion = nil
      activity?.preview = nil
      activity?.previewSelection = NSRange(location: 0, length: 0)
      reviewSelection = NSRange(location: 0, length: 0)
      error = nil
      instruction = ""
    } catch { self.error = error.localizedDescription }
  }

  private func retryFailedAttempt() {
    guard let attempt = failedAttempt else { return }
    let preview = activity?.preview ?? suggestion?.text
    guard attempt.matches(draft: draft, preview: preview) else {
      error = "Your text changed since this request. Select the text and request a new rewrite."
      failedAttempt = nil
      return
    }
    generate(refining: attempt.refining, request: attempt.request,
      requireSelection: attempt.selection.length > 0, selectionOverride: attempt.selection)
  }

  private func generate(refining: Bool = false, request prompt: String? = nil, requireSelection: Bool = false,
                        selectionOverride: NSRange? = nil) {
    let userRequest = prompt ?? instruction
    guard task == nil, !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard writingProvider != nil else {
      error = "Connect a writing provider and save a model in Integrations to rewrite text."
      return
    }
    error = nil
    failedAttempt = nil
    if refining && suggestion == nil { return }
    if refining, let preview = activity?.preview { suggestion?.text = preview }
    let range = selectionOverride ?? (refining ? pendingSelection : selection)
    let selectedPassage = range.length > 0 && (refining || targetSelection || requireSelection)
    let selectionText = refining ? suggestion?.text ?? "" : draft
    guard (!requireSelection || selectedPassage),
      (!selectedPassage || ComposeRefinement.validSelection(range, in: selectionText)) else {
      error = "Select the text you want to rewrite again. Your draft hasn’t changed."
      return
    }
    let base = (refining ? suggestion : nil) ?? ComposeSuggestion(original: draft,
      selection: selectedPassage ? range : nil, text: "")
    let refinement: ComposeRefinement?
    do { refinement = refining ? try ComposeRefinement(base: base, selection: selectedPassage ? range : nil) : nil }
    catch { self.error = error.localizedDescription; return }
    let source = refinement?.sourceText ?? base.sourceText
    let request = ComposeSuggestion.instruction(userRequest, voice: voice,
      instructions: instructions, selection: selectedPassage || base.selection != nil, profile: voiceProfile, memories: memories)
    let session = writingSession
    let mails = selectedMails
    guard let selectedProvider = writingProvider else { return }
    let selectedModel = activeSettings.model(selectedProvider)
    attemptedModel = selectedModel
    let attempt = WritingAttempt(request: userRequest, draft: draft, preview: refining ? base.text : nil,
      selection: selectedPassage ? range : NSRange(location: 0, length: 0), refining: refining)
    let excluded = excludedIDs
    lookupActivity = []
    activity?.working = true
    activity?.streamed = false
    if !refining { activity?.preview = nil }
    workingStage = "Preparing your draft"
    activity?.stage = workingStage
    // A scoped style rewrite must not replay earlier full-email scheduling requests.
    let scoped = selectedPassage || base.selection != nil
    let lookup = lookupEnabled && store != nil && (!scoped || WritingAvailability.isAvailabilityRequest(userRequest))
    let currentEnvelope = envelope
    let requestAccount = store?.accountEmail
    let requestIsSample = store?.isSample
    task = Task { @MainActor in
      defer {
        task = nil; activity?.working = false; activity?.streaming = nil; streamingText = ""
        if let suggestion { activity?.preview = suggestion.text }
      }
      do {
        let showPartial: @MainActor (String) -> Void = { text in
          streamingText = text
          activity?.streaming = text
          if !text.isEmpty { activity?.streamed = true }
        }
        let agent = WritingAgent(
          complete: { prompt in
            // Only the final draft streams; lookup plans are JSON and stay hidden.
            let streams = prompt.system.contains("Write an email draft following")
            return try await activeSettings.complete(prompt, provider: selectedProvider, model: selectedModel,
                                                     onPartial: streams ? showPartial : nil)
          },
          search: { query in
            guard let store else { return [] }
            guard store.accountEmail == requestAccount, store.isSample == requestIsSample else { throw CancellationError() }
            if store.isSample { return mails }
            return try await store.aiSearchMail(query).filter { !excluded.contains($0.id) }
          },
          calendar: { from, to in
            guard let store else { return [] }
            guard store.accountEmail == requestAccount, store.isSample == requestIsSample else { throw CancellationError() }
            return try await store.writingCalendar(from: from, to: to)
          }, calendarAvailable: store?.calendarConnected == true || store?.isSample == true)
        let result = try await agent.draft(instruction: request, draft: source, mails: mails,
          envelope: currentEnvelope, useTools: lookup, userInstruction: userRequest, session: scoped ? WritingSession() : session, recommendationContext: recommendationContext) { stage in
            workingStage = stage; activity?.stage = stage
          }
        let text = result.text
        lookupActivity = result.activity
        usedSources = result.mails
        guard !Task.isCancelled else { return }
        let updated = try refinement?.merging(text) ?? ComposeSuggestion(original: base.original, selection: base.selection, text: text)
        writingSession = scoped ? session.recording(userRequest, availability: result.session.availability ?? session.availability) : result.session
        suggestion = updated
        reviewSelection = NSRange(location: 0, length: 0)
        activity?.previewSelection = NSRange(location: 0, length: 0)
        activity?.preview = updated.text
        activity?.revision += 1
        instruction = ""
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription; failedAttempt = attempt }
      }
    }
  }
}

/// Shared production review surface, also renderable with synthetic drafts in isolated tests.
struct AIWritingReview: View {
  let value: ComposeSuggestion
  @Binding var text: String
  @Binding var instruction: String
  let provider: String
  let working: Bool
  let canRefine: Bool
  let onApply: () -> Void
  let onKeep: () -> Void
  let onRefine: () -> Void
  let onStop: () -> Void

  var inlinePreview = true
  var stage = "Updating your draft"
  var lastRequest = ""
  var selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0))

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if !lastRequest.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text("Your request").font(.coveMetadata).foregroundStyle(Palette.body)
          Text(lastRequest).font(.coveControl).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
      }
      if inlinePreview {
        Text(value.selection == nil ? "Suggested draft" : "Suggested selection").font(.coveControl)
        ComposeTextEditor(text: $text, selection: selection, accessibilityName: "Suggested email text", isEditable: !working)
          .padding(8)
          .frame(minHeight: 210, maxHeight: 300).background(Palette.canvas)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
          .accessibilityLabel("Suggested email text").disabled(working)
      } else {
        Label("Review and edit on the canvas", systemImage: "arrow.left")
          .font(.coveControl).foregroundStyle(Palette.body)
        Text("\(text.split(whereSeparator: \.isWhitespace).count) words · \(value.selection == nil ? "Full draft" : "Selected text")")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      if inlinePreview {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { applyButton; keepButton }
          VStack(alignment: .leading, spacing: 10) { applyButton; keepButton }
        }
      } else { keepButton }
      DisclosureGroup("Compare with original") {
        Text(value.sourceText.isEmpty ? "Empty draft" : value.sourceText).font(.coveBody)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
      }.font(.coveMetadata).disclosureGroupStyle(CoveDisclosureStyle())
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text(selection.wrappedValue.length > 0 ? "Rewrite selected text" : "What would you change?").font(.coveControl)
        if selection.wrappedValue.length > 0 {
          Text("Only your selection will change.").font(.coveMetadata).foregroundStyle(Palette.body)
        }
        VStack(alignment: .leading, spacing: 6) {
          TextField("Ask for a change…", text: $instruction, axis: .vertical)
            .lineLimit(2...4).textFieldStyle(.plain).font(.coveBody)
            .accessibilityLabel("Refine suggestion instructions").disabled(working)
          if working {
            WritingProgressRow(stage: stage, onCancel: onStop)
          } else {
            HStack {
              Text("Keeps the conversation in mind").font(.coveMetadata).foregroundStyle(Palette.body)
              Spacer(minLength: 0)
              Button(action: onRefine) { Image(systemName: "arrow.up").frame(width: 30, height: 30) }
                .buttonStyle(.plain).foregroundStyle(canRefine ? Palette.canvas : Palette.body)
                .background(canRefine ? Palette.ink : Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
                .disabled(!canRefine).help("Update suggestion").accessibilityLabel("Update suggestion")
            }
          }
        }.padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.inputBorder))
        HStack(spacing: 8) {
          quickChange("Shorter", "Make this shorter while keeping the important details.")
          quickChange("Warmer", "Make the tone warmer while preserving the facts.")
          quickChange("More direct", "Make this more direct while preserving the facts.")
        }
      }
    }
  }
  private var applyButton: some View {
    Button("Apply to draft", systemImage: "checkmark", action: onApply)
      .buttonStyle(PrimaryButton()).disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  private var keepButton: some View {
    Button("Keep original", action: onKeep).buttonStyle(.plain)
      .font(.coveControl).foregroundStyle(Palette.body).padding(.vertical, 10).disabled(working)
  }
  private func quickChange(_ label: String, _ prompt: String) -> some View {
    Button(label) { instruction = prompt; onRefine() }.buttonStyle(.plain)
      .font(.coveMetadata).padding(.horizontal, 9).padding(.vertical, 7)
      .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 5)).disabled(working)
  }
}

struct WritingAttempt {
  let request: String
  let draft: String
  let preview: String?
  let selection: NSRange
  let refining: Bool
  func matches(draft: String, preview: String?) -> Bool {
    self.draft == draft && self.preview == preview
  }
}

/// Stays above the scrollable controls so failures cannot disappear below context cards.
struct WritingFailureNotice: View {
  let message: String
  let model: String
  var onRetry: (() -> Void)?
  var onConfigure: (() -> Void)?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Draft wasn’t updated", systemImage: "exclamationmark.circle").font(.coveControl)
      if !model.isEmpty { Text(model).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1) }
      Text(message).font(.coveControl).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      HStack(spacing: 14) {
        if let onRetry { Button("Try again", action: onRetry).buttonStyle(PrimaryButton(compact: true)) }
        if let onConfigure { Button("Writing settings", action: onConfigure).buttonStyle(.plain).font(.coveMetadata) }
      }
    }.foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
      .padding(16).background(Palette.canvas)
      .overlay(alignment: .bottom) { Divider() }
      .accessibilityElement(children: .contain)
  }
}
