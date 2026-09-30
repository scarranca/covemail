import CoveCore
import Foundation

extension AppStore {
  /// What the user is looking at right now, for the assistant's router (bounded; see `promptText`).
  func assistantScreenContext() -> AssistantScreenContext {
    var context = AssistantScreenContext(screen: screen)
    switch screen {
    case "mail":
      context.view = selectedLabelID == nil ? folderTitle : "Label \(folderTitle)"
      context.visibleCount = visible.count
      context.search = search
      if let mail = selected {
        let thread = mail.threadID.isEmpty ? 1 : MailConversation.messages(in: mails, anchor: mail).count
        context.mail = .init(id: mail.id, subject: mail.subject.isEmpty ? "(No subject)" : mail.subject,
                             sender: mail.sender.isEmpty ? mail.senderEmail : mail.sender, threadCount: max(1, thread))
      }
    case "calendar":
      context.calendarDay = calendarDay
      if let event = events.first(where: { $0.id == calendarEventID }) {
        context.event = .init(id: event.id, title: event.title, start: event.start, end: event.end, googleID: event.googleID)
      }
    default: break
    }
    return context
  }

  /// Opens a validated destination. The assistant closes afterwards so the user sees it.
  func perform(_ navigation: AssistantNavigation) {
    switch navigation.screen {
    case "mail":
      if let labelID = navigation.labelID { chooseFolder("label:" + labelID) }
      else if let folder = navigation.folder { chooseFolder(folder) }
      else { screen = "mail" }
      // `chooseFolder` clears the search, so a requested search is applied afterwards.
      if let query = navigation.query { search = query }
    case "calendar":
      selectCalendarDay(navigation.day ?? now)
      screen = "calendar"
    default:
      screen = navigation.screen
    }
    showAssistant = false
  }
}
