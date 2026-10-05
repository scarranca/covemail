#if os(iOS)
import CoveCore
import CoreText
import SwiftUI
import UIKit

/// The Mac's exact sRGB tokens (DESIGN.md, `Palette` in the Mac app). Cove is a light, quiet product on
/// both platforms, so the iPhone app uses the same light palette rather than inventing a dark one.
enum MobilePalette {
  static let canvas = Color(hex: 0xFFFFFF)
  static let surface = Color(hex: 0xFAFAFA)
  static let sidebar = Color(hex: 0xF0F0F0)
  static let selection = Color(hex: 0xDEDEDE)
  /// For white or near-white surfaces only (see DESIGN.md); `body` on gray fills.
  static let muted = Color(hex: 0x737373)
  static let body = Color(hex: 0x4B4B4B)
  static let ink = Color(hex: 0x303030)
  static let line = Color(hex: 0xDEDEDE)
  static let inputBorder = Color(hex: 0xA0A0A0)
  static let toggleOff = Color(hex: 0xBBBBBB)
  static let pressed = Color(hex: 0x171717)
  static let disabled = Color(hex: 0xE8E8E8)
  static let disabledText = Color(hex: 0x999999)
  static let danger = Color(hex: 0xAD3636)
  static let dangerSurface = Color(hex: 0xFFF5F5)
  static let mailSelection = Color(hex: 0xEBEBEB)
  static let mailRead = Color(hex: 0xF7F7F7)
  static let mailReadText = Color(hex: 0x646464)
  static let assessment = Color(hex: 0xF4F6F8)
  static let assessmentBorder = Color(hex: 0xDEE4E9)
  static let badge = Color(hex: 0xEAE8EE)
  static let badgeText = Color(hex: 0x62576F)
  /// Home's briefing banner and the Tasks overview (the Mac's night-blue card).
  static let night = Color(red: 0.114, green: 0.125, blue: 0.165)
  static let nightText = Color(white: 0.96)
  static let nightSecondary = Color(white: 0.84)
  static let warm = Color(red: 0.94, green: 0.78, blue: 0.64)
  static let avatar = LinearGradient(
    colors: [Color(hex: 0xBAC8EB), Color(hex: 0xDCD0EA), Color(hex: 0xEAD1C8)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
  static let avatarText = Color(hex: 0x514960)
  /// The Home tide chart's point-cloud colors.
  static let tide: [Color] = [
    Color(red: 0.47, green: 0.85, blue: 0.79), Color(red: 0.54, green: 0.73, blue: 0.94),
    Color(red: 0.73, green: 0.63, blue: 0.93), Color(red: 0.90, green: 0.66, blue: 0.79),
    Color(red: 0.95, green: 0.74, blue: 0.55),
  ]
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
  }
}

/// The Mac's shared Inter roles (DESIGN.md → Typography), scaled with Dynamic Type. Reading text is one
/// point larger than the Mac's 14 for phone distances; every other role keeps the Mac's size.
extension Font {
  static func coveMobile(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
    .custom("Inter-Regular", size: size, relativeTo: style).weight(weight)
  }
  static let mobileDisplay = Font.coveMobile(34, weight: .medium, relativeTo: .largeTitle)
  static let mobileTitle = Font.coveMobile(24, weight: .medium, relativeTo: .title2)
  static let mobileDetailTitle = Font.coveMobile(20, weight: .medium, relativeTo: .title3)
  static let mobileSection = Font.coveMobile(16, weight: .medium, relativeTo: .headline)
  static let mobileSubheading = Font.coveMobile(14, weight: .medium, relativeTo: .subheadline)
  static let mobileBody = Font.coveMobile(15, relativeTo: .body)
  static let mobileText = Font.coveMobile(14, relativeTo: .callout)
  static let mobileLabel = Font.coveMobile(13, weight: .medium, relativeTo: .callout)
  static let mobileSecondary = Font.coveMobile(13, relativeTo: .footnote)
  static let mobileControl = Font.coveMobile(13, weight: .medium, relativeTo: .footnote)
  static let mobileMetadata = Font.coveMobile(11, relativeTo: .caption)
  static let mobileCaption = Font.coveMobile(11, weight: .medium, relativeTo: .caption)
}

public enum CoveMobile {
  /// Registers the bundled Inter font. Call once at launch, before the first view renders.
  public static func registerFonts() {
    if let font = Bundle.module.url(forResource: "Inter", withExtension: "ttf") {
      CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
    }
    // Native bars and the tab bar use Inter too, like every surface on the Mac.
    let title = UIFont(name: "Inter-Regular", size: 17).map { UIFontMetrics(forTextStyle: .headline).scaledFont(for: $0) }
    let large = UIFont(name: "Inter-Regular", size: 30).map { UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: $0) }
    let ink = UIColor(red: 0x30 / 255, green: 0x30 / 255, blue: 0x30 / 255, alpha: 1)
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    if let title { bar.titleTextAttributes = [.font: title.withWeight(.medium), .foregroundColor: ink] }
    if let large { bar.largeTitleTextAttributes = [.font: large.withWeight(.medium), .foregroundColor: ink] }
    UINavigationBar.appearance().standardAppearance = bar
    UINavigationBar.appearance().compactAppearance = bar
    UINavigationBar.appearance().scrollEdgeAppearance = bar
  }
}

private extension UIFont {
  func withWeight(_ weight: UIFont.Weight) -> UIFont {
    UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: pointSize)
  }
}

// MARK: Buttons (DESIGN.md: 6-point radii; 44-point touch height on iPhone where the Mac uses 40)

/// Cove's primary action: charcoal fill, white label.
struct MobilePrimaryButton: ButtonStyle {
  var compact = false
  var expands = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.mobileControl)
      .foregroundStyle(enabled ? Color.white : MobilePalette.disabledText)
      .padding(.horizontal, compact ? 12 : 16)
      .frame(maxWidth: expands ? .infinity : nil, minHeight: compact ? 34 : 44)
      .background(!enabled ? MobilePalette.disabled : configuration.isPressed ? MobilePalette.pressed : MobilePalette.ink,
                  in: RoundedRectangle(cornerRadius: 6))
      .contentShape(RoundedRectangle(cornerRadius: 6))
  }
}

/// Cove's outlined secondary action.
struct MobileSecondaryButton: ButtonStyle {
  var compact = false
  var destructive = false
  var expands = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.mobileControl)
      .foregroundStyle(!enabled ? MobilePalette.disabledText : destructive ? MobilePalette.danger : MobilePalette.ink)
      .padding(.horizontal, compact ? 12 : 16)
      .frame(maxWidth: expands ? .infinity : nil, minHeight: compact ? 34 : 44)
      .background(configuration.isPressed ? MobilePalette.selection : MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(enabled ? MobilePalette.inputBorder : MobilePalette.disabled))
      .contentShape(RoundedRectangle(cornerRadius: 6))
  }
}

/// A quiet icon button, as in the Mac's toolbars.
struct MobileIconButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 17, weight: .regular)).foregroundStyle(MobilePalette.ink)
      .frame(minWidth: 40, minHeight: 40)
      .background(configuration.isPressed ? MobilePalette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
  }
}

/// The Mac's text field: white, 1-point outline, charcoal 2-point outline while editing.
struct MobileFieldStyle: TextFieldStyle {
  var font: Font = .mobileBody
  @FocusState private var focused: Bool
  func _body(configuration: TextField<_Label>) -> some View {
    configuration.font(font).focused($focused)
      .foregroundStyle(MobilePalette.ink)
      .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? MobilePalette.ink : MobilePalette.inputBorder,
                                                         lineWidth: focused ? 2 : 1))
  }
}

// MARK: Shared pieces

/// People use the Mac's periwinkle–lavender–peach gradient with dark initials.
struct MobileAvatar: View {
  let name: String
  var size: CGFloat = 36
  init(name: String, size: CGFloat = 36) { self.name = name; self.size = size }
  init(mail: Mail, size: CGFloat = 36) {
    self.init(name: mail.sender.isEmpty ? mail.senderEmail : mail.sender, size: size)
  }
  private var initials: String {
    // An address shows its first letter, not "AE" for alex@example.com.
    if name.contains("@") { return name.first.map { String($0).uppercased() } ?? "?" }
    let letters = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2).compactMap(\.first)
    return letters.isEmpty ? "?" : String(letters).uppercased()
  }
  var body: some View {
    Text(initials).font(.coveMobile(size * 0.36, weight: .medium))
      .foregroundStyle(MobilePalette.avatarText)
      .frame(width: size, height: size)
      .background(MobilePalette.avatar, in: Circle())
      .accessibilityHidden(true)
  }
}

/// The Cove wordmark: the three-wave mark and lowercase "cove".
struct MobileWordmark: View {
  var size: CGFloat = 26
  var body: some View {
    HStack(spacing: size * 0.3) {
      MobileMark().frame(width: size * 1.05, height: size * 0.77)
      Text("cove").font(.coveMobile(size, weight: .semibold))
    }.foregroundStyle(MobilePalette.ink).accessibilityElement(children: .ignore).accessibilityLabel("Cove")
  }
}

/// Cove's three-wave mark, from the app icon, tinted with the current foreground color.
struct MobileMark: View {
  var body: some View {
    if let url = Bundle.module.url(forResource: "cove-mark", withExtension: "png"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image.withRenderingMode(.alwaysTemplate)).resizable().aspectRatio(contentMode: .fit)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "water.waves").resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
    }
  }
}

/// Small rounded tag (labels, "Draft ready", "Inbox").
struct MobileTag: View {
  let text: String
  var systemImage: String?
  var fill: Color = MobilePalette.sidebar
  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
      Text(text).lineLimit(1)
    }
    .font(.mobileCaption).foregroundStyle(MobilePalette.body)
    .padding(.horizontal, 7).padding(.vertical, 4)
    .background(fill, in: RoundedRectangle(cornerRadius: 4))
  }
}

/// Underlined text tabs, as in the Mac's Important / Other filter bar.
struct MobileUnderlineTabs<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(Value, String, Int)]
  var body: some View {
    HStack(spacing: 20) {
      ForEach(options, id: \.0) { value, title, count in
        let selected = selection == value
        Button { selection = value } label: {
          HStack(spacing: 5) {
            Text(title).font(selected ? .mobileSubheading : .coveMobile(14, relativeTo: .subheadline))
            if count > 0 { Text(count > 99 ? "99+" : "\(count)").font(.mobileMetadata).monospacedDigit() }
          }
          .foregroundStyle(selected ? MobilePalette.ink : MobilePalette.muted)
          .padding(.vertical, 8)
          .overlay(alignment: .bottom) { Rectangle().fill(selected ? MobilePalette.ink : .clear).frame(height: 2) }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) unread").accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }
}

/// The Mac's segmented picker: gray track, white selected segment.
struct MobileSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(Value, String)]
  var body: some View {
    HStack(spacing: 4) {
      ForEach(options, id: \.0) { value, title in
        Button { selection = value } label: {
          Text(title).font(.mobileControl)
            .foregroundStyle(selection == value ? MobilePalette.ink : MobilePalette.body)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(selection == value ? MobilePalette.canvas : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if selection == value { RoundedRectangle(cornerRadius: 6).stroke(MobilePalette.line) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
      }
    }.padding(4).background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 8))
  }
}

/// The Mac's toggle: charcoal capsule when on, gray when off.
struct MobileToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 12) {
        configuration.label.font(.mobileLabel).foregroundStyle(MobilePalette.ink).multilineTextAlignment(.leading)
        Spacer(minLength: 12)
        Capsule().fill(configuration.isOn ? MobilePalette.ink : MobilePalette.toggleOff)
          .frame(width: 44, height: 26)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle().fill(MobilePalette.canvas).frame(width: 20, height: 20).padding(3)
          }
      }.frame(minHeight: 44).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.18), value: configuration.isOn)
    .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
  }
}

/// A screen header in the Mac's style: a 24-point title, optional count, and trailing actions.
struct MobileScreenHeader<Trailing: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var trailing: () -> Trailing
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title).font(.mobileTitle).foregroundStyle(MobilePalette.ink).lineLimit(1)
        .accessibilityAddTraits(.isHeader)
      if let detail { Text(detail).font(.mobileSecondary).foregroundStyle(MobilePalette.body).lineLimit(1) }
      Spacer(minLength: 8)
      HStack(spacing: 4) { trailing() }
    }
  }
}

extension MobileScreenHeader where Trailing == EmptyView {
  init(title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// A Settings-style card: white, 1-point line, 10-point corners.
struct MobileCard<Content: View>: View {
  var padding: CGFloat = 16
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content() }
      .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
      .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }
}

/// Section heading with an optional trailing count, as on Home.
struct MobileSectionTitle: View {
  let title: String
  var detail: String?
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.mobileSection).foregroundStyle(MobilePalette.ink).accessibilityAddTraits(.isHeader)
      Spacer()
      if let detail { Text(detail).font(.mobileMetadata).foregroundStyle(MobilePalette.muted) }
    }
  }
}

/// A quiet empty or status message.
struct MobileEmptyState: View {
  let title: String
  var detail: String?
  var systemImage = "tray"
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(MobilePalette.ink)
        .frame(width: 52, height: 52).background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
      Text(title).font(.mobileSection).foregroundStyle(MobilePalette.ink)
      if let detail {
        Text(detail).font(.mobileSecondary).foregroundStyle(MobilePalette.muted).multilineTextAlignment(.center)
      }
    }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
  }
}

enum MobileDates {
  /// The Mac's list date sections: Today, Yesterday, then the full date.
  static func section(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
  static func short(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}
#endif
