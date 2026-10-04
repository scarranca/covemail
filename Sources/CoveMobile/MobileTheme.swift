#if os(iOS)
import CoveCore
import CoreText
import SwiftUI
import UIKit

/// Cove's palette on iPhone. The Mac palette is light only; here each color adapts to Dark Mode.
enum MobilePalette {
  static let canvas = dynamic(light: 0xFFFFFF, dark: 0x111111)
  static let surface = dynamic(light: 0xFAFAFA, dark: 0x1C1C1C)
  static let selection = dynamic(light: 0xEBEBEB, dark: 0x2A2A2A)
  static let ink = dynamic(light: 0x303030, dark: 0xF2F2F2)
  static let body = dynamic(light: 0x4B4B4B, dark: 0xD0D0D0)
  /// For white or near-white surfaces only (see DESIGN.md); darker text elsewhere.
  static let muted = dynamic(light: 0x737373, dark: 0xA3A3A3)
  static let line = dynamic(light: 0xDEDEDE, dark: 0x333333)
  static let danger = dynamic(light: 0xAD3636, dark: 0xF07A7A)
  static let badge = dynamic(light: 0xEAE8EE, dark: 0x2E2A35)
  static let badgeText = dynamic(light: 0x62576F, dark: 0xC9BFD6)
  static let accent = dynamic(light: 0x171717, dark: 0xFFFFFF)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
  }
}

private extension UIColor {
  convenience init(hex: UInt32) {
    self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
              blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}

/// The Mac's text roles in Inter, scaled with Dynamic Type on iPhone.
extension Font {
  static func coveMobile(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
    .custom("Inter-Regular", size: size, relativeTo: style).weight(weight)
  }
  static let mobileTitle = Font.coveMobile(24, weight: .medium, relativeTo: .title2)
  static let mobileDetailTitle = Font.coveMobile(20, weight: .medium, relativeTo: .title3)
  static let mobileSection = Font.coveMobile(16, weight: .medium, relativeTo: .headline)
  static let mobileSubheading = Font.coveMobile(15, weight: .medium, relativeTo: .subheadline)
  /// Reading text is a little larger than on the Mac (14 pt) for phone distances.
  static let mobileBody = Font.coveMobile(16, relativeTo: .body)
  static let mobileLabel = Font.coveMobile(14, weight: .medium, relativeTo: .callout)
  static let mobileSecondary = Font.coveMobile(13, relativeTo: .footnote)
  static let mobileMetadata = Font.coveMobile(12, relativeTo: .caption)
}

public enum CoveMobile {
  /// Registers the bundled Inter font. Call once at launch, before the first view renders.
  public static func registerFonts() {
    if let font = Bundle.module.url(forResource: "Inter", withExtension: "ttf") {
      CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
    }
  }
}

/// Cove's primary action: dark fill, 44 pt high on iPhone (the Mac uses 40 pt).
struct MobilePrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.mobileLabel)
      .padding(.horizontal, 18).frame(minHeight: 44)
      .foregroundStyle(enabled ? MobilePalette.canvas : MobilePalette.muted)
      .background(enabled ? MobilePalette.accent.opacity(configuration.isPressed ? 0.8 : 1) : MobilePalette.selection,
                  in: Capsule())
  }
}

struct MobileSecondaryButton: ButtonStyle {
  var destructive = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.mobileLabel)
      .padding(.horizontal, 16).frame(minHeight: 44)
      .foregroundStyle(!enabled ? MobilePalette.muted : destructive ? MobilePalette.danger : MobilePalette.ink)
      .background(MobilePalette.selection.opacity(configuration.isPressed ? 1 : 0.7), in: Capsule())
  }
}

/// Initials in Cove's soft avatar.
struct MobileAvatar: View {
  let mail: Mail
  var body: some View {
    Text(mail.initials).font(.coveMobile(13, weight: .medium, relativeTo: .footnote))
      .foregroundStyle(MobilePalette.badgeText)
      .frame(width: 36, height: 36)
      .background(MobilePalette.badge, in: Circle())
      .accessibilityHidden(true)
  }
}

#endif
