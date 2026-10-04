#if os(iOS)
import CoveCore
import SwiftUI

/// The iPhone app: sign-in, then Mail, Search and Settings tabs.
public struct CoveMobileRoot: View {
  @State private var auth: MobileAuth
  @State private var mailbox: MobileMailbox
  @State private var ai = MobileAI()
  @Environment(\.scenePhase) private var scenePhase

  public init() {
    let auth = MobileAuth()
    _auth = State(initialValue: auth)
    _mailbox = State(initialValue: MobileMailbox(auth: auth))
  }

  public var body: some View {
    Group {
      if auth.email == nil {
        MobileSignInView(auth: auth)
      } else {
        TabView {
          Tab("Mail", systemImage: "tray") { MobileInboxView(mailbox: mailbox, ai: ai) }
          Tab("Settings", systemImage: "gearshape") { MobileSettingsView(auth: auth, mailbox: mailbox, ai: ai) }
          Tab(role: .search) { MobileSearchView(mailbox: mailbox, ai: ai) }
        }
        .overlay(alignment: .bottom) { MobileUndoBar(mailbox: mailbox).padding(.bottom, 64) }
      }
    }
    .font(.mobileBody)
    .tint(MobilePalette.accent)
    .task(id: auth.email) {
      guard auth.email != nil else { mailbox.close(); return }
      mailbox.openIfNeeded()
      await mailbox.sync()
    }
    .task(id: auth.email) {
      // While Cove is open, check Gmail about every two minutes, like the Mac.
      while !Task.isCancelled, auth.email != nil {
        try? await Task.sleep(for: .seconds(120))
        if scenePhase == .active { await mailbox.sync() }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        ai.refreshStatus()
        Task { await mailbox.sync() }
      case .background:
        // Leaving the app finishes a waiting Trash or Send instead of losing it.
        mailbox.commitPendingNow()
      default: break
      }
    }
  }
}

/// The Undo bar for Trash and Send.
struct MobileUndoBar: View {
  let mailbox: MobileMailbox
  var body: some View {
    if let pending = mailbox.pending {
      HStack(spacing: 16) {
        Text(pending.title).font(.mobileLabel)
        Spacer()
        Button("Undo") { mailbox.undoPending() }.font(.mobileLabel)
      }
      .padding(.horizontal, 20).padding(.vertical, 14)
      .glassEffect(.regular, in: Capsule())
      .padding(.horizontal, 16)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .id(pending.id)
    }
  }
}

struct MobileSignInView: View {
  let auth: MobileAuth
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Spacer()
      Text("Cove").font(.coveMobile(42, weight: .medium, relativeTo: .largeTitle))
      Text("A calm place for your Gmail. Your mail is stored encrypted on this iPhone.")
        .font(.mobileBody).foregroundStyle(MobilePalette.body)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      if !auth.isConfigured {
        Label("This build has no Google sign-in configured. Add an iOS OAuth client ID (see docs/IOS.md).",
              systemImage: "exclamationmark.triangle")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.danger)
      }
      if let error {
        Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        error = nil
        Task {
          do { try await auth.signIn() } catch { self.error = error.localizedDescription }
        }
      } label: {
        HStack {
          if auth.signingIn { ProgressView().tint(MobilePalette.canvas) }
          Text(auth.signingIn ? "Signing in…" : "Sign in with Google")
        }.frame(maxWidth: .infinity)
      }
      .buttonStyle(MobilePrimaryButton())
      .disabled(!auth.isConfigured || auth.signingIn)
      Text("Cove is in private beta. Your Google account must be on the tester list.")
        .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(MobilePalette.canvas)
    .foregroundStyle(MobilePalette.ink)
  }
}
#endif
