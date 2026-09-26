import SwiftUI

/// Scannable section headers with a full-size keyboard and pointer target.
struct SettingsSectionDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack(spacing: 16) {
          configuration.label
          Spacer(minLength: 0)
          Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
            .font(.coveControl).foregroundStyle(Palette.body)
            .accessibilityHidden(true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(SettingsSectionButtonStyle())
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide these settings")
      if configuration.isExpanded {
        Divider().padding(.horizontal, 22)
        configuration.content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
          .disclosureGroupStyle(CoveDisclosureStyle())
      }
    }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
  }
}

struct SettingsSectionHeading: View {
  let title: String
  let subtitle: String
  let icon: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon).font(.cove(size: 18)).frame(width: 24, height: 24)
        .foregroundStyle(Palette.body).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.coveSection).foregroundStyle(Palette.ink)
        Text(subtitle).font(.coveSecondary).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct SettingsSectionButtonStyle: ButtonStyle {
  @State private var hovering = false
  @Environment(\.isFocused) private var focused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Palette.sidebar : hovering ? Palette.surface : Palette.canvas,
        in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.ink : .clear, lineWidth: 2))
      .onHover { hovering = $0 }
  }
}
