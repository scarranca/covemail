#if os(iOS)
import CoveCore
import SwiftUI
import UserNotifications

/// The local "Back in your inbox" notification for a snooze. It is a time-triggered request iOS itself
/// keeps and delivers, so it fires even when Cove isn't running. Sender and subject only, never the body.
enum MobileSnoozeNotifier {
  /// Asks once (the first snooze); true when iOS will show the notification.
  static func ensurePermission() async -> Bool {
    let center = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: return true
    case .denied: return false
    default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
  }

  /// Schedules (replacing any earlier request for this email). Returns whether notifications are on.
  @discardableResult
  static func schedule(mailID: String, sender: String, subject: String, account: String, at date: Date) async -> Bool {
    let allowed = await ensurePermission()
    guard allowed else { return false }
    add(mailID: mailID, sender: sender, subject: subject, account: account, at: date)
    return true
  }

  private static func add(mailID: String, sender: String, subject: String, account: String, at date: Date) {
    let content = UNMutableNotificationContent()
    content.title = SnoozeNotice.title
    content.body = SnoozeNotice.body(sender: sender, subject: subject)
    content.sound = .default
    // `mailID` is what MobilePush's tap routing already opens.
    content.userInfo = ["mailID": mailID, "account": account]
    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: SnoozeNotice.identifier(mailID: mailID), content: content, trigger: trigger))
  }

  static func cancel(_ mailIDs: [String]) {
    let ids = mailIDs.map { SnoozeNotice.identifier(mailID: $0) }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
  }

  /// Makes pending requests match the snoozed mail (never asks for permission here).
  static func reconcile(_ snoozed: [Mail], account: String) {
    Task {
      let center = UNUserNotificationCenter.current()
      let status = await center.notificationSettings().authorizationStatus
      guard status == .authorized || status == .provisional || status == .ephemeral else { return }
      let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
      for mail in snoozed {
        guard let until = mail.snoozedUntil, !pending.contains(SnoozeNotice.identifier(mailID: mail.id)) else { continue }
        add(mailID: mail.id, sender: SnoozeNotice.senderName(of: mail), subject: mail.subject, account: account, at: until)
      }
    }
  }
}

/// The choices as buttons, for a Menu, a context menu or a confirmation dialog.
struct MobileSnoozeChoices: View {
  let mail: Mail
  let mailbox: MobileMailbox
  /// Called after a choice that snoozes or returns the email (the reader leaves).
  var onChosen: () -> Void = {}
  /// Opens the date picker.
  let pickDate: () -> Void

  var body: some View {
    ForEach(SnoozePreset.available(), id: \.preset) { choice in
      Button {
        mailbox.snooze(mail, until: choice.date)
        onChosen()
      } label: {
        Text("\(choice.preset.title) · \(SnoozePreset.describe(choice.date))")
      }
    }
    Button("Pick a date…", systemImage: "calendar") { pickDate() }
    if mail.snoozedUntil != nil && mailbox.isSnoozed(mail) {
      Button("Return to inbox", systemImage: "tray.and.arrow.down") {
        mailbox.snooze(mail, until: nil)
        onChosen()
      }
    }
  }
}

extension View {
  /// The row chooser: a confirmation dialog with the presets, the picker and the honest footer.
  func mobileSnoozeDialog(mail: Binding<Mail?>, mailbox: MobileMailbox, pickDate: @escaping (Mail) -> Void) -> some View {
    confirmationDialog("Snooze until…", isPresented: Binding(get: { mail.wrappedValue != nil }, set: { if !$0 { mail.wrappedValue = nil } }),
                       titleVisibility: .visible, presenting: mail.wrappedValue) { target in
      MobileSnoozeChoices(mail: target, mailbox: mailbox, pickDate: { pickDate(target) })
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(MobileSnoozeCopy.footer(mailbox.snoozeNotificationsAllowed))
    }
  }
}

enum MobileSnoozeCopy {
  /// Snoozes live on this iPhone only; say so, and say when notifications are off.
  static func footer(_ notificationsAllowed: Bool?) -> String {
    var text = "Snoozes are saved on this iPhone and don’t sync to your Mac yet."
    if notificationsAllowed == false { text += " Notifications are off for Cove, so it can’t tell you when this returns." }
    return text
  }
}

/// "Pick a date…": a graphical calendar and time, at least 30 minutes ahead (as on the Mac).
struct MobileSnoozeDatePicker: View {
  let mail: Mail
  let mailbox: MobileMailbox
  var onChosen: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date

  init(mail: Mail, mailbox: MobileMailbox, onChosen: @escaping () -> Void = {}) {
    self.mail = mail
    self.mailbox = mailbox
    self.onChosen = onChosen
    let tomorrow = SnoozePreset.tomorrowMorning.date() ?? Date().addingTimeInterval(24 * 3600)
    _date = State(initialValue: tomorrow)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        DatePicker("Return to inbox", selection: $date, in: Date().addingTimeInterval(30 * 60)...,
                   displayedComponents: [.date, .hourAndMinute])
          .datePickerStyle(.graphical).labelsHidden()
        Text(SnoozePreset.describe(date)).font(.mobileLabel).foregroundStyle(MobilePalette.ink)
        Text(MobileSnoozeCopy.footer(mailbox.snoozeNotificationsAllowed)).font(.mobileSecondary)
          .foregroundStyle(MobilePalette.body)
        Button {
          mailbox.snooze(mail, until: date)
          dismiss()
          onChosen()
        } label: { Text("Snooze").frame(maxWidth: .infinity) }
          .buttonStyle(MobilePrimaryButton(expands: true))
        Spacer(minLength: 0)
      }
      .padding(20)
      .background(MobilePalette.surface)
      .navigationTitle("Snooze").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .presentationDetents([.large])
  }
}
#endif
