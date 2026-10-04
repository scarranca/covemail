import CoveMobile
import SwiftUI

@main
struct CoveMobileApp: App {
  init() { CoveMobile.registerFonts() }

  var body: some Scene {
    WindowGroup { CoveMobileRoot() }
  }
}
