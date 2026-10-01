import CoveCore
import SwiftUI

struct WelcomeView: View {
  @Bindable var store: AppStore
  var body: some View {
    GeometryReader { geometry in
      let panelWidth = min(600, max(470, geometry.size.width * 5 / 12))
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 10) {
            Image(systemName: "water.waves").font(.cove(size: 29, weight: .medium))
            Text("cove").font(.cove(size: 30, weight: .semibold))
          }.accessibilityElement(children: .ignore).accessibilityLabel("Cove")
          Spacer(minLength: 32)
          authentication
          Spacer(minLength: 32)
          footer
        }
        .padding(.horizontal, panelWidth < 540 ? 40 : 56)
        .padding(.top, 58).padding(.bottom, 32)
        .frame(width: panelWidth, height: geometry.size.height)
        .background(Palette.surface)
        SignInLandscape().frame(maxWidth: .infinity, maxHeight: .infinity)
          .ignoresSafeArea(.container, edges: .top)
      }
    }
  }

  private var authentication: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("A quieter inbox.\nA clearer mind.").font(.coveDisplay)
        .tracking(-1.6).lineSpacing(0).foregroundStyle(Color(white: 0.141))
        .fixedSize(horizontal: false, vertical: true)
      Text("Jev helps you find what needs your attention.")
      .font(.coveBody).lineSpacing(7).foregroundStyle(Color(white: 0.408))
      .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
      Button {
        let clientID = store.auth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if GoogleOAuthConfiguration(clientID: clientID).isConfigured {
          Task { await store.connect(includeCalendar: store.calendarConnected) }
        } else {
          store.showConnections = true
        }
      } label: {
        HStack(spacing: 12) {
          if store.busy {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "envelope").font(.cove(size: 20))
          }
          Text(store.busy ? "Connecting to Google…" : "Continue with Gmail")
        }.frame(maxWidth: .infinity)
      }
      .buttonStyle(GmailSignInButtonStyle()).disabled(store.busy)
      .accessibilityLabel(store.busy ? "Connecting to Google" : "Continue with Gmail")
      .keyboardShortcut(.defaultAction).padding(.top, 36)
      Text("Secure sign-in with Google. No new password.").font(.coveMetadata)
        .foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 13)
      if store.busy {
        Button("Cancel sign-in") { store.auth.cancel() }
          .buttonStyle(.plain).font(.coveControl).padding(.top, 16)
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Mail stays on this Mac. Credentials stay in Keychain.")
        .font(.coveMetadata).lineSpacing(6).foregroundStyle(Palette.muted)
      HStack {
        Button("Connection settings") { store.showConnections = true }
          .accessibilityLabel("Connection settings")
          .help("Configure Google and Jev, or get help connecting")
        Spacer(minLength: 12)
        Button("Explore a sample inbox") { store.openSample() }.disabled(store.busy)
          .accessibilityLabel("Explore a sample inbox")
      }.buttonStyle(.plain).font(.coveMetadata).foregroundStyle(Palette.body)
    }
  }
}
struct ComposerView: View {
  @Bindable var store: AppStore
  var availableSize = CGSize(width: 1100, height: 780)
  @Environment(\.dismiss) private var dismiss
  @State private var to = ""
  @State private var sender = ""
  @State private var senderAddresses: [String] = []
  @State private var loadingSenders = false
  @State private var senderError: String?
  @State private var subject = ""
  @State private var text = ""
  @State private var selection = NSRange(location: 0, length: 0)
  @State private var writingActivity: WritingActivity
  @State private var aiOpen = false
  private var showAskLine: Bool {
    aiOpen || writingActivity.working || writingActivity.preview != nil || writingActivity.needsAttention
  }
  @FocusState private var recipientFocused: Bool
  @State private var loaded = false
  @State private var saveTask: Task<Void, Never>?
  @State private var confirmDiscard = false
  @State private var undoSuggestion: String?
  @State private var appliedSuggestion: String?

  init(store: AppStore, availableSize: CGSize = CGSize(width: 1100, height: 780), activity: WritingActivity? = nil) {
    self.store = store
    self.availableSize = availableSize
    _writingActivity = State(initialValue: activity ?? WritingActivity())
  }

  private var sheetWidth: CGFloat { min(1260, max(640, availableSize.width - 64)) }
  private var sheetHeight: CGFloat { min(920, max(480, availableSize.height - 64)) }
  private var compact: Bool { sheetWidth < 900 }
  private var sendDisabled: Bool {
    to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy
      || !senderAddresses.contains(sender) || writingActivity.working || writingActivity.preview != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      editor.frame(maxWidth: .infinity)
    }
      .frame(width: sheetWidth, height: sheetHeight)
      .background(Palette.canvas).foregroundStyle(Palette.ink)
      .onAppear {
        guard !loaded else { return }
        sender = store.defaultSender
        senderAddresses = store.sendingAliases.isEmpty ? [store.accountEmail] : store.sendingAliases
        if let mail = store.mails.first(where: { $0.id == store.composeID }) {
          to = mail.to; subject = mail.subject; text = mail.body
          sender = mail.senderEmail.isEmpty ? store.defaultSender : mail.senderEmail
        }
        loaded = true
      }
      .task { await loadSenders() }
      // Saved after a short pause, not on every keystroke (that re-sorted the whole mailbox each time).
      .onChange(of: sender) { _, _ in scheduleSave() }
      .onChange(of: to) { _, _ in scheduleSave() }
      .onChange(of: subject) { _, _ in scheduleSave() }
      .onChange(of: text) { _, _ in scheduleSave() }
      .onDisappear { save() }
      .interactiveDismissDisabled(store.busy)
      .confirmationDialog("Move this draft to Trash?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Move to Trash", role: .destructive) {
          save()
          if let mail = store.mails.first(where: { $0.id == store.composeID }) {
            Task { await store.trash(mail); dismiss() }
          }
        }
        Button("Keep draft", role: .cancel) {}
      }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Text("New message").font(.coveSection)
      Text("Draft saved on this Mac").font(.coveMetadata).foregroundStyle(Palette.body)
      Spacer()
      Button { save(); dismiss() } label: {
        Image(systemName: "xmark").padding(8).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Save and close draft").help("Save and close draft")
        .disabled(store.busy)
    }.padding(.horizontal, 22).frame(height: 62)
  }

  private var editor: some View {
    VStack(spacing: 0) {
      HStack(spacing: 15) {
        Text("From").frame(width: 48, alignment: .leading).foregroundStyle(Palette.body)
        if senderAddresses.count > 1 || !senderAddresses.contains(sender) {
          CoveMenuPicker("From", selection: $sender,
            options: senderAddresses.map { ($0, $0) })
            .disabled(store.busy || loadingSenders)
          if !senderAddresses.contains(sender) {
            Text(sender).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
          }
        } else {
          Text(sender).textSelection(.enabled).lineLimit(1)
        }
        Spacer(minLength: 0)
        if loadingSenders { ProgressView().controlSize(.small) }
        else {
          Button { Task { await loadSenders() } } label: {
            Image(systemName: "arrow.clockwise").padding(6).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Refresh sender aliases")
            .help("Refresh addresses from Gmail’s Send mail as settings").disabled(store.busy)
        }
      }.font(.coveControl).padding(.horizontal, 24).frame(minHeight: 48)
      if let senderError {
        Text(senderError).font(.coveMetadata).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24).padding(.bottom, 8)
      } else if !loadingSenders && !senderAddresses.contains(sender) {
        Text("This draft’s sender is unavailable. Choose another From address.")
          .font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 24).padding(.bottom, 8)
      }
      recipientField
      envelopeField("Subject", text: $subject, placeholder: "Add a subject")
      HStack(spacing: 9) {
        Image(systemName: "waveform")
        Text("Your voice · \(store.preferences.voice)")
        Spacer(minLength: 0)
        if !store.preferences.instructions.isEmpty && sheetWidth > 1080 {
          Text("Saved instructions applied").font(.coveMetadata)
        }
      }.font(.coveControl).foregroundStyle(Palette.body)
        .padding(.horizontal, 24).frame(height: 42).background(Palette.surface)
      ZStack(alignment: .topLeading) {
        ComposeTextEditor(text: $text, selection: $selection, isEditable: writingActivity.preview == nil)
          .opacity(writingActivity.preview == nil ? 1 : 0)
          .accessibilityHidden(writingActivity.preview != nil)
          .allowsHitTesting(writingActivity.preview == nil)
        if let preview = writingActivity.preview {
          WritingCanvasPreview(text: preview, animated: !writingActivity.streamed, onEdit: writingActivity.working ? nil : { writingActivity.preview = $0 },
            onSelection: { writingActivity.previewSelection = $0 }, selectedRange: writingActivity.previewSelection)
            .id(writingActivity.revision)
        } else if writingActivity.working, let streaming = writingActivity.streaming, !streaming.isEmpty {
          // The draft appears as it is written; it becomes the reviewable preview when complete.
          ScrollView {
            Text(streaming).font(.coveBody).lineSpacing(6).foregroundStyle(Palette.ink)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 18)
          }.background(Palette.canvas).accessibilityLabel("Draft being written")
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      HStack(spacing: 10) {
        if let preview = writingActivity.preview {
          Button("Apply draft", systemImage: "checkmark") { writingActivity.applyRequest += 1 }
            .buttonStyle(PrimaryButton(compact: true))
            .disabled(writingActivity.working || preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Discard") { writingActivity.discardRequest += 1 }
            .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body).disabled(writingActivity.working)
        }
        if (writingActivity.preview == nil ? selection : writingActivity.previewSelection).length > 0 {
          Button("Rewrite selection", systemImage: "sparkles") {
            writingActivity.rewriteRequest += 1
          }.buttonStyle(.plain).font(.coveMetadata).disabled(writingActivity.working)
        } else if writingActivity.preview == nil {
          Text("Select text to rewrite just that part.").lineLimit(1)
        }
        Spacer(minLength: 0)
        Text("\((writingActivity.preview ?? text).split(whereSeparator: \.isWhitespace).count) words").fixedSize()
      }.font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 24).padding(.vertical, 10)
      if let undoSuggestion, let appliedSuggestion, text == appliedSuggestion {
        HStack {
          Label("Suggestion applied", systemImage: "checkmark").font(.coveMetadata)
          Spacer()
          Button("Undo") {
            text = undoSuggestion
            selection = NSRange(location: 0, length: 0)
            self.undoSuggestion = nil
            self.appliedSuggestion = nil
          }.buttonStyle(.plain).font(.coveControl)
        }.padding(.horizontal, 24).padding(.vertical, 10).background(Palette.summary)
      }
      // Collapsed to the ✦ button in the footer until asked for; stays mounted so work isn't lost.
      assistant.padding(.horizontal, 20).padding(.bottom, 12)
      Divider()
      HStack(spacing: 12) {
        Button(store.isSample ? "Save sample" : "Send", systemImage: "paperplane") {
          send()
        }.buttonStyle(PrimaryButton()).disabled(sendDisabled)
          .keyboardShortcut(.return, modifiers: .command)

        Spacer(minLength: 0)
        Button { confirmDiscard = true } label: {
          Image(systemName: "trash").padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Discard draft").help("Discard draft").disabled(store.busy)
      }.padding(.horizontal, 24).padding(.vertical, 16)
    }
  }

  private var recipientQuery: String {
    String(to.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var suggestedContacts: [MailContact] {
    Array(store.contacts.filter {
      recipientQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(recipientQuery)
        || $0.email.localizedCaseInsensitiveContains(recipientQuery)
    }.sorted { ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }.prefix(4))
  }
  private func chooseRecipient(_ contact: MailContact) {
    var pieces = to.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    if !pieces.isEmpty { pieces.removeLast() }
    pieces.append(contact.email)
    to = pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    recipientFocused = false
  }
  private var recipientField: some View {
    VStack(spacing: 0) {
      Divider().padding(.horizontal, 24)
      HStack(spacing: 15) {
        Text("To").font(.coveControl).foregroundStyle(Palette.body).frame(width: 48, alignment: .leading)
        TextField("Name or email", text: $to).font(.coveBody).textFieldStyle(.plain)
          .accessibilityLabel("To").focused($recipientFocused)
          .onSubmit { if let first = suggestedContacts.first { chooseRecipient(first) } }
        Button { recipientFocused.toggle() } label: {
          Image(systemName: "person.crop.circle.badge.plus").padding(5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Choose a contact")
      }.padding(.horizontal, 24).frame(height: 46)
      if recipientFocused && !suggestedContacts.isEmpty {
        VStack(spacing: 0) {
          ForEach(suggestedContacts) { contact in
            Button { chooseRecipient(contact) } label: {
              HStack(spacing: 12) {
                Text(contact.initials).font(.coveMetadata).frame(width: 28, height: 28)
                  .background(Palette.selection, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                  Text(contact.name).font(.coveControl).lineLimit(1)
                  Text(contact.email).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !contact.messages.isEmpty {
                  Text("\(contact.messages.count) emails").font(.coveMetadata).foregroundStyle(Palette.body)
                }
              }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Choose \(contact.name), \(contact.email)")
          }
        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 6))
          .padding(.horizontal, 24).padding(.bottom, 8)
      }
    }
  }

  private func envelopeField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(spacing: 0) {
      Divider().padding(.horizontal, 24)
      HStack(spacing: 15) {
        Text(title).font(.coveControl).foregroundStyle(Palette.body).frame(width: 48, alignment: .leading)
        TextField(placeholder, text: text).font(.coveBody).textFieldStyle(.plain)
          .accessibilityLabel(title)
      }.padding(.horizontal, 24).frame(height: 46)
    }
  }

  private var writingEnvelope: String {
    let recipients = Set(WritingContext.recipients(to))
    let names = store.contacts.filter { recipients.contains($0.email) }
      .map { "\($0.name) <\($0.email)>" }.joined(separator: "; ")
    return "From: \(sender)\nTo: \(to)\nRecipient names: \(names)\nSubject: \(subject)"
  }

  private var assistant: some View {
    AIWritingPanel(draft: $text, selection: selection, context: WritingContext.recentMail(to: to, mails: store.mails), availableContext: store.mails,
      voice: store.preferences.voice, instructions: store.preferences.instructions,
      voiceProfile: store.preferences.voiceProfile, memories: store.preferences.memoryPrompt,
      store: store, envelope: writingEnvelope, envelopeIdentity: "\(sender)\n\(to)\n\(subject)", activity: writingActivity, reviewOnCanvas: true, inline: true, onClose: { aiOpen = false },
      isOpen: showAskLine, onOpen: { aiOpen = true; writingActivity.focusRequest += 1 },
      onApply: { value in
        undoSuggestion = text
        text = value
        selection = NSRange(location: 0, length: 0)
        appliedSuggestion = value
        aiOpen = false
        save()
      }, onConfigure: {
        save()
        store.showComposer = false
        store.screen = "integrations"
      })
  }

  private func loadSenders() async {
    guard !loadingSenders else { return }
    loadingSenders = true
    senderError = nil
    defer { loadingSenders = false }
    do {
      let addresses = try await store.sendingAddresses()
      try Task.checkCancellation()
      senderAddresses = addresses
      store.sendingAliases = addresses
      if let canonical = addresses.first(where: { $0.caseInsensitiveCompare(sender) == .orderedSame }) {
        sender = canonical
      }
    } catch {
      if !Task.isCancelled {
        senderAddresses = [store.accountEmail]
        senderError = "Couldn’t load Gmail aliases. You can use your primary address or refresh to retry."
      }
    }
  }

  private func send() {
    save()
    // No "Send this email?" dialog: a 4-second undo bar instead, like Delete. Undo reopens this draft.
    store.queueSend(to: to, subject: subject, body: text, draftID: store.composeID, from: sender)
    dismiss()
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      save()
    }
  }

  private func save() {
    saveTask?.cancel(); saveTask = nil
    guard loaded, let id = store.composeID else { return }
    store.saveComposition(id: id, to: to, subject: subject, body: text, from: sender)
  }
}
