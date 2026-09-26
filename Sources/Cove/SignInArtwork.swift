import SwiftUI

/// Full-height artwork extracted unchanged from the supplied sign-in design.
struct SignInLandscape: View {
  private static let artwork = Bundle.module.url(
    forResource: "sign-in-landscape", withExtension: "jpg"
  )
  .flatMap { NSImage(contentsOf: $0) }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Color(white: 0.067)
        if let artwork = Self.artwork {
          Image(nsImage: artwork).resizable().scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .accessibilityHidden(true)
        }
        // A restrained scrim keeps the small caption readable over the supplied bright dots.
        LinearGradient(
          stops: [.init(color: .clear, location: 0.72), .init(color: .black.opacity(0.8), location: 1)],
          startPoint: .top, endPoint: .bottom
        ).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 15) {
          Text("LESS NOISE. MORE SPACE.").font(.coveCaption)
            .foregroundStyle(Color(white: 0.698))
          Text("Find your focus.\nWe’ll handle the overflow.").font(.cove(size: 32))
            .tracking(-0.6).lineSpacing(2).foregroundStyle(Color(white: 0.957))
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          HStack(alignment: .bottom) {
            Text("A little perspective changes everything.").font(.coveMetadata)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Text("COVE / 001").font(.coveMetadata).fixedSize()
          }.foregroundStyle(.white)
        }
        .padding(.horizontal, geometry.size.width < 640 ? 36 : 52)
        .padding(.top, 58).padding(.bottom, 60)
      }
    }.clipped()
  }
}

/// The supplied onboarding CTA uses the larger 54-point sign-in variant.
struct GmailSignInButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    GmailSignInButtonSurface(configuration: configuration)
  }
}

private struct GmailSignInButtonSurface: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    configuration.label.font(.coveSubheading)
      .foregroundStyle(enabled ? .white : Palette.body)
      .padding(.horizontal, 16).frame(height: 54)
      .background(
        enabled
          ? configuration.isPressed
            ? Palette.pressed : hovering ? Palette.hover : Color(white: 0.161)
          : Palette.disabled,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: 11).stroke(Palette.ink, lineWidth: 2).padding(-4)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
  }
}
