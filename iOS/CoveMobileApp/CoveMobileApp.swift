import CoveMobile
import SwiftUI

@main
struct CoveMobileApp: App {
  // APNs registration and notification taps (new-mail push).
  @UIApplicationDelegateAdaptor(CoveAppDelegate.self) private var delegate
  init() { CoveMobile.registerFonts() }

  var body: some Scene {
    WindowGroup { CoveMobileRoot() }
  }
}
