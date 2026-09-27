import AppKit
import CoreText
import SwiftUI

// Exact sRGB tokens from the user-provided Cove Foundations and Components exports.
enum Palette {
  static let canvas = Color(hex: 0xFFFFFF)
  static let surface = Color(hex: 0xFAFAFA)
  static let sidebar = Color(hex: 0xF0F0F0)
  static let selection = Color(hex: 0xDEDEDE)
  static let muted = Color(hex: 0x737373)
  static let body = Color(hex: 0x4B4B4B)
  static let ink = Color(hex: 0x303030)
  static let line = Color(hex: 0xDEDEDE)
  static let inputBorder = Color(hex: 0xA0A0A0)
  static let toggleOff = Color(hex: 0xBBBBBB)
  static let hover = Color(hex: 0x454545)
  static let pressed = Color(hex: 0x171717)
  static let disabled = Color(hex: 0xE8E8E8)
  static let disabledText = Color(hex: 0x999999)
  static let danger = Color(hex: 0xAD3636)
  static let dangerSurface = Color(hex: 0xFFF5F5)
  static let mailSelection = Color(hex: 0xEBEBEB)
  static let mailHover = Color(hex: 0xEFEFEF)
  static let mailRead = Color(hex: 0xF7F7F7)
  static let mailReadText = Color(hex: 0x646464)
  static let summary = Color(hex: 0xF4F4F4)
  static let assessment = Color(hex: 0xF4F6F8)
  static let assessmentBorder = Color(hex: 0xDEE4E9)
  static let badge = Color(hex: 0xEAE8EE)
  static let badgeText = Color(hex: 0x62576F)
  // #737373 stays on white/FAFAFA; the darker body token maintains contrast on selected fills.
  static let avatar = LinearGradient(
    colors: [Color(hex: 0xBAC8EB), Color(hex: 0xDCD0EA), Color(hex: 0xEAD1C8)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
  static let avatarText = Color(hex: 0x514960)
}
extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, opacity: 1)
  }
}
extension Font {
  static func cove(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("Inter-Regular", fixedSize: size).weight(weight)
  }
  // Shared roles across every destination. Prose, controls and metadata retain distinct sizes.
  static let coveDisplay = Font.cove(size: 42, weight: .medium) // Sign-in artwork only.
  static let coveTitle = Font.cove(size: 24, weight: .medium)
  static let coveDetailTitle = Font.cove(size: 20, weight: .medium)
  static let coveSection = Font.cove(size: 16, weight: .medium)
  static let coveSubheading = Font.cove(size: 14, weight: .medium)
  static let coveBody = Font.cove(size: CoveTypography.bodySize)
  static let coveText = Font.cove(size: 13)
  static let coveLabel = Font.cove(size: 13, weight: .medium)
  static let coveSecondary = Font.cove(size: 12)
  static let coveControl = Font.cove(size: 12, weight: .medium)
  static let coveMetadata = Font.cove(size: 11)
  static let coveCaption = Font.cove(size: 11, weight: .medium)

}
/// Shared metrics for SwiftUI prose and native TextKit editors/previews.
enum CoveTypography {
  static let bodySize: CGFloat = 14
  static let bodyLineSpacing: CGFloat = 6
  static var nativeBody: NSFont {
    NSFont(name: "Inter-Regular", size: bodySize) ?? .systemFont(ofSize: bodySize)
  }
}
enum DesignAssets {
  static let dottedWave: NSImage? = Bundle.module.url(
    forResource: "dotted-wave", withExtension: "jpg"
  )
  .flatMap { NSImage(contentsOf: $0) }
  static func registerFonts() {
    if let font = Bundle.module.url(forResource: "Inter", withExtension: "ttf") {
      CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
    }
  }
}
struct PrimaryButton: ButtonStyle {
  var compact = false
  func makeBody(configuration: Configuration) -> some View {
    CoveButtonSurface(configuration: configuration, secondary: false, compact: compact)
  }
}
struct SecondaryButton: ButtonStyle {
  var compact = false
  func makeBody(configuration: Configuration) -> some View {
    CoveButtonSurface(configuration: configuration, secondary: true, compact: compact)
  }
}
private struct CoveButtonSurface: View {
  let configuration: ButtonStyleConfiguration
  let secondary: Bool
  var compact = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  private var fill: Color {
    if !enabled { return Palette.disabled }
    if secondary {
      return configuration.isPressed
        ? Palette.selection : hovering ? Palette.sidebar : Palette.canvas
    }
    return configuration.isPressed ? Palette.pressed : hovering ? Palette.hover : Palette.ink
  }
  var body: some View {
    configuration.label.font(.coveControl)
      .foregroundStyle(!enabled ? Palette.disabledText : secondary ? Palette.ink : .white)
      .padding(.horizontal, compact ? 12 : 16).frame(minHeight: compact ? 30 : 40)
      .background(fill, in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        if secondary {
          RoundedRectangle(cornerRadius: 6).stroke(
            enabled ? Palette.inputBorder : Palette.disabled, lineWidth: 1)
        }
      }
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: 9).stroke(Palette.ink, lineWidth: 2).padding(-4)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
  }
}
struct CoveFieldStyle: TextFieldStyle {
  @FocusState private var focused: Bool
  var focus: FocusState<Bool>.Binding?
  var font: Font
  init(focus: FocusState<Bool>.Binding? = nil, font: Font = .coveSecondary) {
    self.focus = focus; self.font = font
  }
  @Environment(\.isEnabled) private var enabled
  func _body(configuration: TextField<_Label>) -> some View {
    configuration.font(font).textFieldStyle(.plain).focused(focus ?? $focused)
      .foregroundStyle(Palette.body).padding(.horizontal, 12).padding(.vertical, 10).frame(
        minHeight: 42
      )
      .background(enabled ? Palette.canvas : Palette.surface, in: RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6).stroke(
          (focus?.wrappedValue ?? focused) ? Palette.ink : Palette.inputBorder,
          lineWidth: (focus?.wrappedValue ?? focused) ? 2 : 1))
  }
}
struct CoveAvatar: View {
  let initials: String
  var size: CGFloat = 40
  var body: some View {
    Text(initials).font(.cove(size: size * 0.36, weight: .medium)).foregroundStyle(
      Palette.avatarText
    )
    .frame(width: size, height: size).background(Palette.avatar, in: Circle()).accessibilityHidden(
      true)
  }
}

struct CoveSegmentedPicker: View {
  @Binding var selection: String
  let options: [String]
  var body: some View {
    HStack(spacing: 4) {
      ForEach(options, id: \.self) { option in
        Button {
          selection = option
        } label: {
          Text(option).font(.coveControl).foregroundStyle(
            selection == option ? Palette.ink : Palette.body
          )
          .frame(maxWidth: .infinity, minHeight: 36)
          .background(
            selection == option ? Palette.canvas : .clear, in: RoundedRectangle(cornerRadius: 6)
          )
          .overlay {
            if selection == option { RoundedRectangle(cornerRadius: 6).stroke(Palette.line) }
          }
          .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
      }
    }.padding(4).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
  }
}

/// A full-width disclosure button: labels and whitespace toggle it, not just the chevron.
struct CoveDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack(spacing: 12) {
          configuration.label
          Spacer(minLength: 12)
          Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
            .font(.cove(size: 12, weight: .medium)).foregroundStyle(Palette.body)
            .accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide these settings")
      if configuration.isExpanded {
        configuration.content.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

/// An explicit button keeps the whole field clickable on macOS, including its label.
struct CoveMenuPicker<Selection: Hashable>: View {
  let title: String
  @Binding var selection: Selection
  let options: [(Selection, String)]
  @State private var showingOptions = false

  init(_ title: String, selection: Binding<Selection>, options: [(Selection, String)]) {
    self.title = title
    _selection = selection
    self.options = options
  }

  var body: some View {
    Button { showingOptions.toggle() } label: {
      HStack(spacing: 16) {
        Text(options.first { $0.0 == selection }?.1 ?? title).lineLimit(1)
        Image(systemName: "chevron.down").font(.cove(size: 10, weight: .medium))
          .accessibilityHidden(true)
      }.frame(minWidth: 100, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(SecondaryButton())
      .accessibilityLabel(title)
      .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
      .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.coveMetadata).foregroundStyle(Palette.body).padding(8)
          if options.count > 7 {
            ScrollView { optionRows }.frame(width: 320, height: 300)
          } else {
            optionRows
          }
        }.padding(8).frame(minWidth: 190).fixedSize(horizontal: true, vertical: true)
      }
  }

  private var optionRows: some View {
    VStack(alignment: .leading, spacing: 4) {
          ForEach(options.indices, id: \.self) { index in
            Button {
              selection = options[index].0
              showingOptions = false
            } label: {
              HStack(spacing: 12) {
                Text(options[index].1).lineLimit(1).help(options[index].1)
                Spacer(minLength: 20)
                Image(systemName: "checkmark")
                  .opacity(selection == options[index].0 ? 1 : 0).accessibilityHidden(true)
              }.font(.coveControl).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityAddTraits(selection == options[index].0 ? .isSelected : [])
          }
    }
  }

}

struct CoveToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    CoveToggleSurface(configuration: configuration)
  }
}

private struct CoveToggleSurface: View {
  let configuration: ToggleStyleConfiguration
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool
  @State private var hovering = false

  var body: some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 12) {
        configuration.label.font(.coveLabel).foregroundStyle(
          enabled ? Palette.ink : Palette.disabledText
        )
        .multilineTextAlignment(.leading)
        Spacer(minLength: 12)
        Capsule().fill(
          configuration.isOn ? (hovering ? Palette.hover : Palette.ink) : Palette.toggleOff
        )
        .frame(width: 34, height: 22)
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(Palette.canvas).frame(width: 16, height: 16).padding(3)
        }
        .overlay {
          if focused { Capsule().stroke(Palette.ink, lineWidth: 2).padding(-3) }
        }
        .opacity(enabled ? 1 : 0.5)
      }.frame(minHeight: 40).contentShape(Rectangle())
    }
    .buttonStyle(.plain).focused($focused).onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
    }
  }
}
