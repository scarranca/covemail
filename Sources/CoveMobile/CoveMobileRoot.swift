#if os(iOS)
import CoveCore
import SwiftUI

/// The iPhone app: sign-in, then Home, Mail, Calendar, Tasks and Search, the Mac's destinations as tabs.
public struct CoveMobileRoot: View {
  @State private var auth: MobileAuth
  @State private var mailbox: MobileMailbox
  @State private var workspace: MobileWorkspace
  @State private var ai = MobileAI()
  @State private var tab: MobileTab = .home
  @State private var push = MobilePush.shared
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var sizeClass

  public init() {
    MobileAttachmentFiles.removeAll()
    let auth = MobileAuth()
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-CoveSample") { auth.useSample() }
    #endif
    _auth = State(initialValue: auth)
    _mailbox = State(initialValue: MobileMailbox(auth: auth))
    _workspace = State(initialValue: MobileWorkspace(auth: auth))
    #if DEBUG
    // Screenshot checks: `-CoveTab mail|calendar|tasks|search` picks the first tab.
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "-CoveTab"), arguments.indices.contains(index + 1) {
      let tabs: [String: MobileTab] = ["home": .home, "mail": .mail, "calendar": .calendar, "tasks": .tasks, "search": .search]
      _tab = State(initialValue: tabs[arguments[index + 1]] ?? .home)
    }
    #endif
  }

  public var body: some View {
    Group {
      if auth.email == nil {
        MobileSignInView(auth: auth)
      } else if sizeClass == .regular {
        // iPad (full screen or a wide split): the Mac's sidebar, list and reader.
        MobileIPadRoot(auth: auth, mailbox: mailbox, workspace: workspace, ai: ai)
          .overlay(alignment: .bottom) { MobileUndoBar(mailbox: mailbox).frame(maxWidth: 520).padding(.bottom, 24) }
      } else {
        TabView(selection: $tab) {
          Tab("Home", systemImage: "house", value: MobileTab.home) {
            MobileHomeView(auth: auth, mailbox: mailbox, workspace: workspace, ai: ai, tab: $tab)
          }
          Tab("Mail", systemImage: "tray", value: MobileTab.mail) { MobileInboxView(mailbox: mailbox, ai: ai, workspace: workspace) }
            .badge(mailbox.unreadCount(.important))
          Tab("Calendar", systemImage: "calendar", value: MobileTab.calendar) {
            MobileCalendarView(auth: auth, workspace: workspace)
          }
          Tab("Tasks", systemImage: "checklist", value: MobileTab.tasks) {
            MobileTasksView(auth: auth, workspace: workspace, mailbox: mailbox, ai: ai)
          }
          Tab(value: MobileTab.search, role: .search) { MobileSearchView(mailbox: mailbox, ai: ai, workspace: workspace) }
        }
        .overlay(alignment: .bottom) { MobileUndoBar(mailbox: mailbox).padding(.bottom, 70) }
      }
    }
    .font(.mobileBody)
    .foregroundStyle(MobilePalette.ink)
    .tint(MobilePalette.ink)
    // Cove is a light product on the Mac; the iPhone app keeps the same palette. Sign-in opens on dark
    // artwork, so only there the status bar is light.
    .preferredColorScheme(auth.email == nil ? .dark : .light)
    .task { push.configure(auth: auth) }
    .task(id: auth.email) {
      await push.accountChanged(to: auth.email)
      guard auth.email != nil else { mailbox.close(); workspace.reset(); return }
      mailbox.openIfNeeded()
      async let mail: Void = mailbox.sync()
      async let calendar: Void = workspace.loadEvents()
      async let tasks: Void = workspace.loadTasks()
      _ = await (mail, calendar, tasks)
      // Then older mail, quietly, so Contacts, search and suggestions have more than the newest page.
      await mailbox.downloadHistory()
    }
    .task(id: auth.email) {
      MobileMe.shared.auth = auth
      await MobileMe.shared.sync()
    }
    .task(id: auth.email) {
      // While Cove is open, check Gmail about every two minutes, like the Mac.
      while !Task.isCancelled, auth.email != nil {
        try? await Task.sleep(for: .seconds(120))
        if scenePhase == .active {
          await mailbox.sync()
          await mailbox.downloadHistory()
        }
      }
    }
    // An email chosen from a notification opens over whatever is on screen.
    .sheet(isPresented: Binding(get: { push.openMailID != nil && auth.email != nil }, set: { if !$0 { push.openMailID = nil } })) {
      if let id = push.openMailID {
        NavigationStack {
          MobileNotificationMail(mailbox: mailbox, ai: ai, workspace: workspace, mailID: id)
        }
      }
    }
    .onChange(of: auth.calendarConnected) { _, connected in
      if connected { Task { await workspace.loadEvents(force: true) } }
    }
    .onChange(of: auth.tasksConnected) { _, connected in
      if connected { Task { await workspace.loadTasks() } }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        ai.refreshStatus()
        Task { await mailbox.sync() }
        Task { await push.appBecameActive() }
        Task { await MobileMe.shared.sync() }
      case .background:
        // Leaving the app finishes a waiting Trash or Send instead of losing it.
        mailbox.commitPendingNow()
      default: break
      }
    }
  }
}

enum MobileTab: Hashable { case home, mail, calendar, tasks, search }

/// The Undo bar for Trash and Send: the Mac's small bottom notification with a countdown.
struct MobileUndoBar: View {
  let mailbox: MobileMailbox
  var body: some View {
    if let pending = mailbox.pending {
      HStack(spacing: 14) {
        Image(systemName: pending.title.hasPrefix("Send") ? "paperplane" : "trash")
          .font(.system(size: 13)).foregroundStyle(MobilePalette.body).accessibilityHidden(true)
        Text(pending.title).font(.mobileControl).foregroundStyle(MobilePalette.ink)
        Spacer(minLength: 8)
        Button("Undo") { mailbox.undoPending() }
          .buttonStyle(MobileSecondaryButton(compact: true))
      }
      .padding(.leading, 18).padding(.trailing, 8).frame(height: 52)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
      .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
      .padding(.horizontal, 16)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .id(pending.id)
    }
  }
}

/// The Mac's sign-in (docs/design-source/SignIn.html) on a phone: the monochrome landscape above,
/// the wordmark, display line and the larger Gmail button below.
struct MobileSignInView: View {
  let auth: MobileAuth
  @State private var error: String?

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          landscape.frame(height: max(220, geometry.size.height * 0.40)).clipped()
          VStack(alignment: .leading, spacing: 18) {
            MobileWordmark(size: 24)
            Text("A quieter inbox.\nA clearer mind.").font(.mobileDisplay).foregroundStyle(MobilePalette.ink)
              .fixedSize(horizontal: false, vertical: true)
            Text("Jev helps you find what needs your attention. Your mail is stored encrypted on this iPhone.")
              .font(.mobileBody).foregroundStyle(MobilePalette.body).lineSpacing(4)
              .fixedSize(horizontal: false, vertical: true)
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
              HStack(spacing: 10) {
                if auth.signingIn { ProgressView().tint(.white) } else { Image(systemName: "envelope") }
                Text(auth.signingIn ? "Signing in…" : "Sign in with Gmail").font(.coveMobile(15, weight: .medium))
              }.frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(MobilePrimaryButton(expands: true))
            .disabled(!auth.isConfigured || auth.signingIn)
            VStack(alignment: .leading, spacing: 6) {
              Label("Secure sign-in with Google. No new password.", systemImage: "lock")
              Label("Gmail, Calendar and Tasks, in one consent.", systemImage: "checkmark.circle")
              Label("Cove is in private beta: your account must be on the tester list.", systemImage: "person.badge.shield.checkmark")
            }.font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
          .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 32)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .ignoresSafeArea(edges: .top)
    }
    .background(MobilePalette.canvas)
  }

  @ViewBuilder private var landscape: some View {
    if let url = Bundle.module.url(forResource: "sign-in-landscape", withExtension: "jpg"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        .frame(maxWidth: .infinity).accessibilityHidden(true)
    } else {
      MobilePalette.sidebar
    }
  }
}
#endif

#if os(iOS)
/// The email a notification pointed to: read from Gmail if this device hasn't downloaded it yet.
struct MobileNotificationMail: View {
  let mailbox: MobileMailbox
  let ai: MobileAI
  let workspace: MobileWorkspace
  let mailID: String
  @State private var failed = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if mailbox.mail(id: mailID) != nil {
        MobileReaderView(mailbox: mailbox, ai: ai, workspace: workspace, mailID: mailID) { dismiss() }
      } else if failed {
        MobileEmptyState(title: "This email isn’t available", detail: "It may have moved to Trash.")
      } else {
        ProgressView("Opening…").font(.mobileSecondary)
      }
    }
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    .task {
      MobilePush.shared.clearNotification(for: mailID)
      if mailbox.mail(id: mailID) == nil { failed = !(await mailbox.fetch(id: mailID)) }
    }
  }
}
#endif
