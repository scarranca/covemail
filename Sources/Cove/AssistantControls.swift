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
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.cove(size: 14))
        if !compact { configuration.label.font(.coveSecondary) }
        Capsule().fill(configuration.isOn && enabled ? Palette.ink : Palette.toggleOff)
          .frame(width: 30, height: 18)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle().fill(.white).frame(width: 14, height: 14).padding(2)
          }
      }.padding(.horizontal, 10).frame(height: 32)
        .foregroundStyle(enabled ? Palette.body : Palette.muted)
        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).accessibilityLabel("Mail search")
      .accessibilityValue(configuration.isOn ? "On" : "Off")
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
  }
}
