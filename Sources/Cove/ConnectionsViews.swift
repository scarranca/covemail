import CoveCore
import SwiftUI

/// Everything Cove can connect, in the order a new user should set it up.
enum SetupStep: String, CaseIterable, Identifiable {
  case gmail, ai, jev, calendar, tasks
  var id: String { rawValue }
  var title: String {
    switch self {
    case .gmail: "Gmail"
    case .ai: "AI writing"
    case .jev: "Jev by TypeSafe"
    case .calendar: "Google Calendar"
    case .tasks: "Google Tasks"
    }
  }
  /// What it unlocks, in one line.
  var powers: String {
    switch self {
    case .gmail: "Your mail, on this Mac"
    case .ai: "Drafts, replies and Ask Cove"
    case .jev: "Organizes mail, runs your agents, finds tasks"
    case .calendar: "Meetings, free time and invitations"
    case .tasks: "Keeps the promises in your email"
    }
  }
  var icon: String {
    switch self {
    case .gmail: "envelope"
    case .ai: "sparkles"
    case .jev: "wand.and.stars"
    case .calendar: "calendar"
    case .tasks: "checklist"
    }
  }
}

@MainActor enum Setup {
  /// Whether a TypeSafe key is saved, without reading the secret (which may ask for Touch ID).
  static var jevKeySaved: Bool {
    if let known = UserDefaults.standard.object(forKey: "setup.jevKeySaved") as? Bool { return known }
    // Keys saved before this flag existed: check silently once when no Touch ID prompt is involved.
    guard !Vault.aiKeysRequireTouchID else { return true }
    let saved = ((try? Vault.read("typesafeKey")) ?? nil)?.isEmpty == false
    UserDefaults.standard.set(saved, forKey: "setup.jevKeySaved")
    return saved
  }
  static func recordJevKey(saved: Bool) { UserDefaults.standard.set(saved, forKey: "setup.jevKeySaved") }

  static func isDone(_ step: SetupStep, store: AppStore) -> Bool {
    switch step {
    case .gmail: store.entered && !store.isSample
    case .ai: AIProviderSettings.shared.writingProvider() != nil
    case .jev: jevKeySaved
    case .calendar: store.calendarConnected
    case .tasks: store.tasksConnected
    }
  }
  static func remaining(_ store: AppStore) -> [SetupStep] { SetupStep.allCases.filter { !isDone($0, store: store) } }
}

/// Paste a TypeSafe key right where it's needed; saved to the Keychain and checked before reporting success.
struct JevKeyField: View {
  var onSaved: () -> Void = {}
  @State private var key = ""
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        SecureField("Paste your TypeSafe API key", text: $key).textFieldStyle(CoveFieldStyle())
          .onSubmit(save).accessibilityLabel("TypeSafe API key")
        Button("Save", action: save).buttonStyle(PrimaryButton(compact: true))
          .disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      HStack(spacing: 14) {
        Link("Get a key ↗", destination: URL(string: "https://console.typesafe.ai")!)
        Text("Email text you run through Jev is sent to TypeSafe.").foregroundStyle(Palette.body)
          .help("TypeSafe states it does not train on inputs; zero data retention is not established.")
      }.font(.coveMetadata)
      if let error { Text(error).font(.coveMetadata).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
    }
  }
  private func save() {
    let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    saving = true
    defer { saving = false }
    do {
      try Vault.save(clean, name: "typesafeKey")
      if !Vault.aiKeysRequireTouchID, try Vault.read("typesafeKey") != clean {
        throw CoveError.message("Your TypeSafe key couldn’t be saved to the Keychain. Try again.")
      }
      Setup.recordJevKey(saved: true)
      key = ""
      error = nil
      onSaved()
    } catch { self.error = error.localizedDescription }
  }
}

/// One connection: what it powers, whether it's on, and the single action to turn it on.
struct ConnectionRow<Detail: View>: View {
  let step: SetupStep
  let done: Bool
  var actionTitle: String = "Connect"
  var action: (() -> Void)? = nil
  var expanded: Bool = false
  /// Shown instead of the status when connected, e.g. "Change model".
  var manageTitle: String? = nil
  var manage: (() -> Void)? = nil
  @ViewBuilder var detail: () -> Detail
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        Image(systemName: step.icon).font(.cove(size: 16)).frame(width: 36, height: 36)
          .background(done ? Palette.sidebar : Palette.surface, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title).font(.coveSubheading)
          Text(step.powers).font(.coveSecondary).foregroundStyle(Palette.body)
        }
        Spacer(minLength: 12)
        if done {
          HStack(spacing: 12) {
            if let manageTitle, let manage {
              Button(manageTitle, action: manage).buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
            }
            Label("Connected", systemImage: "checkmark.circle.fill").font(.coveControl).foregroundStyle(Palette.ink)
          }
        } else if let action {
          Button(actionTitle, action: action).buttonStyle(PrimaryButton(compact: true))
        }
      }
      if expanded { detail().padding(.leading, 50) }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(done ? Palette.line : Palette.inputBorder))
    .accessibilityElement(children: .contain)
  }
}

/// "3 of 5 connected" with a slim bar.
struct SetupProgress: View {
  let done: Int
  let total: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(done == total ? "Everything’s connected." : "\(done) of \(total) connected").font(.coveControl)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Palette.sidebar)
          Capsule().fill(Palette.ink).frame(width: geometry.size.width * CGFloat(done) / CGFloat(max(total, 1)))
        }
      }.frame(height: 6).animation(.spring(response: 0.5, dampingFraction: 0.8), value: done)
    }.accessibilityElement(children: .combine).accessibilityLabel("\(done) of \(total) connected")
  }
}

/// Shown on Home until setup is done or dismissed: the next few steps, each one click away.
struct SetupChecklistCard: View {
  @Bindable var store: AppStore
  @AppStorage("setup.checklistDismissed") private var dismissed = false
  @State private var refresh = 0
  var body: some View {
    let remaining = Setup.remaining(store)
    if !dismissed && !store.isSample && !remaining.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("Finish setting up Cove").font(.coveSection)
          Spacer()
          Button { dismissed = true } label: { Image(systemName: "xmark").font(.cove(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Hide").accessibilityLabel("Hide setup")
        }
        SetupProgress(done: SetupStep.allCases.count - remaining.count, total: SetupStep.allCases.count)
        VStack(spacing: 0) {
          ForEach(Array(remaining.enumerated()), id: \.element) { index, step in
            if index > 0 { Divider() }
            HStack(spacing: 12) {
              Image(systemName: step.icon).frame(width: 20).foregroundStyle(Palette.body)
              VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.coveLabel)
                Text(step.powers).font(.coveMetadata).foregroundStyle(Palette.body)
              }
              Spacer(minLength: 8)
              Button(index == 0 ? "Set up" : "Set up") { open(step) }
                .buttonStyle(index == 0 ? AnyButtonStyle(PrimaryButton(compact: true)) : AnyButtonStyle(SecondaryButton(compact: true)))
            }.padding(.vertical, 10)
          }
        }
      }
      .padding(20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
      .id(refresh)
    }
  }
  private func open(_ step: SetupStep) {
    switch step {
    case .calendar: Task { await store.connectCalendar() }
    case .tasks: Task { await store.connectTasks() }
    default:
      store.integrationsFocus = step
      store.screen = "integrations"
    }
  }
}

/// A ButtonStyle eraser, so one row can be primary and the rest secondary.
struct AnyButtonStyle: ButtonStyle {
  private let make: (Configuration) -> AnyView
  init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// A gate: explains what's missing and connects Jev right here.
struct JevRequiredBanner: View {
  var reason: String
  @State private var saved = Setup.jevKeySaved
  var body: some View {
    if !saved {
      VStack(alignment: .leading, spacing: 12) {
        Label("Connect Jev to use this", systemImage: "wand.and.stars").font(.coveSubheading)
        Text(reason).font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        JevKeyField { saved = true }
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

extension Int {
  /// nil for zero, so badges disappear when nothing is left.
  var nonZero: Int? { self == 0 ? nil : self }
}
