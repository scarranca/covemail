import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = AppUpdater()
  @Published private(set) var canCheck = false
  @Published private(set) var automaticChecks = true
  @Published private(set) var restartPending = false
  @Published private(set) var status: String?
  @Published private var controller: SPUStandardUpdaterController?
  private var restart: (() -> Void)?
  var interruptionReason: () -> String? = { nil }
  var showNotice: (String) -> Void = { message in
    let alert = NSAlert()
    alert.messageText = "Finish your work before restarting"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  var isAvailable: Bool { controller != nil }
  var menuTitle: String { restartPending ? "Install Update and Relaunch…" : "Check for Updates…" }

  func start(store: AppStore) {
    guard controller == nil, Self.isConfigured(bundle: .main, arguments: ProcessInfo.processInfo.arguments) else { return }
    interruptionReason = { [weak store] in
      guard let store else { return nil }
      if store.busy || store.calendarSyncing || store.trashDeadline != nil || store.trashCommitting {
        return "Wait for Cove’s current mail or calendar operation to finish, then choose Install Update and Relaunch from the Cove menu."
      }
      if store.showComposer || store.showAssistant || NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
        return "Save your work and close any open editor or conversation, then choose Install Update and Relaunch from the Cove menu."
      }
      return nil
    }
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    self.controller = controller
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
    do { try controller.updater.start() }
    catch { status = "Update checks couldn’t start: \(error.localizedDescription)" }
  }

  static func isConfigured(bundle: Bundle, arguments: [String]) -> Bool {
    guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
          let url = URL(string: feed), url.scheme == "https", url.host?.isEmpty == false,
          let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
          Data(base64Encoded: key)?.count == 32 else { return false }
    return bundle.bundleIdentifier == "ai.cove.mac"
      && bundle.object(forInfoDictionaryKey: "CoveUpdatesEnabled") as? Bool == true
      && !arguments.contains("--qa")
  }

  func checkForUpdates() {
    if restartPending { resumeRestart() }
    else { controller?.checkForUpdates(nil) }
  }

  func setAutomaticChecks(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
               untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    postponeRestart(reason: interruptionReason(), install: installHandler)
  }

  @discardableResult func postponeRestart(reason: String?, install: @escaping () -> Void) -> Bool {
    guard let reason else { return false }
    restart = install
    restartPending = true
    status = reason
    showNotice(reason)
    return true
  }

  func resumeRestart() {
    guard let restart else { return }
    if let reason = interruptionReason() { showNotice(reason); return }
    self.restart = nil
    restartPending = false
    status = nil
    restart()
  }
}

struct AppUpdateSettings: View {
  var showsHeading = true
  @ObservedObject private var updater = AppUpdater.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        if showsHeading { Text("App updates").font(.coveSection) }
        if showsHeading { Spacer() }
        Text("Cove \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
          .font(.coveSecondary).foregroundStyle(Palette.muted)
      }
      if updater.isAvailable {
        Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
          .toggleStyle(CoveToggleStyle())
        Text("Cove checks daily. You choose when to download, install, and restart.")
          .font(.coveSecondary).foregroundStyle(Palette.body)
        Button(updater.menuTitle, action: updater.checkForUpdates).buttonStyle(SecondaryButton())
          .disabled(!updater.canCheck && !updater.restartPending)
        if let status = updater.status { Text(status).font(.coveSecondary).foregroundStyle(Palette.body) }
      } else {
        Text("Update checks are available in the installed release of Cove.").font(.coveSecondary).foregroundStyle(Palette.body)
      }
    }
  }
}
