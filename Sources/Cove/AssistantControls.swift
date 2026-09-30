import SwiftUI

struct AssistantActionButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.coveControl)
      .foregroundStyle(enabled ? Palette.ink : Palette.disabledText)
      .padding(.horizontal, 14).frame(minHeight: 40)
      .background(configuration.isPressed ? Palette.selection : hovering ? Palette.surface : Palette.canvas,
                  in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Palette.ink : Palette.line, lineWidth: focused ? 2 : 1))
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
  }
}

struct AssistantMailSearchStyle: ToggleStyle {
  var compact = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: "globe").font(.cove(size: 13))
        if !compact { configuration.label.font(.coveControl) }
      }
    }.buttonStyle(ChipStyle(on: configuration.isOn && enabled)).focusEffectDisabled()
      .accessibilityLabel("Mail search")
      .accessibilityValue(configuration.isOn ? "On" : "Off")
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
  }

  /// A chip, like other assistants' search toggle: filled and dark when on, quiet when off.
  /// Keyboard focus draws on the chip itself instead of a clipped system ring.
  private struct ChipStyle: ButtonStyle {
    let on: Bool
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(on ? Palette.ink : Palette.muted)
        .background(configuration.isPressed ? Palette.selection : on ? Palette.sidebar : .clear, in: Capsule())
        .overlay { if focused { Capsule().strokeBorder(Palette.ink, lineWidth: 2) } }
        .contentShape(Capsule())
    }
  }
}
