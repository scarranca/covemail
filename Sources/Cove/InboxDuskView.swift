import CoveCore
import SwiftUI

/// The empty Important inbox: a sunset drawn in dots, a sea that shimmers, and a few birds flying home.
/// Slow and quiet, like the Home tide; Reduce Motion (or an inactive window) keeps it still.
enum DuskGeometry {
  struct Dot: Equatable {
    var x: CGFloat, y: CGFloat, r: CGFloat
    /// 0 = sea teal … 1 = sunset peach, along Cove's tide colors; nil = ink (birds).
    var hue: Double?
    var alpha: Double
  }

  static func horizon(_ size: CGSize) -> CGFloat { size.height * 0.64 }

  static func dots(size: CGSize, time: Double) -> [Dot] {
    var dots: [Dot] = []
    let w = size.width, h = size.height, horizon = horizon(size)
    let center = w / 2, radius = min(w * 0.24, horizon * 0.78)

    // The sun: a dot grid inside a half disc, warmer and larger toward the horizon, with the low bands
    // cut away like a setting sun.
    let step: CGFloat = 6
    var y = horizon - step / 2
    var row = 0
    while y > horizon - radius {
      let depth = (horizon - y) / radius        // 0 at the horizon, 1 at the top
      let band = depth < 0.42 && row % 3 == 1   // gaps that thicken toward the water
      if !band {
        let half = sqrt(max(0, radius * radius - (horizon - y) * (horizon - y)))
        var x = center - half + (half.truncatingRemainder(dividingBy: step)) / 2
        while x <= center + half {
          let edge = 1 - min(1, abs(x - center) / max(half, 1))
          dots.append(Dot(x: x, y: y, r: 1.15 + 0.75 * (1 - depth), hue: 0.95 - depth * 0.35,
                          alpha: 0.55 + 0.4 * (1 - depth) * (0.6 + 0.4 * edge)))
          x += step
        }
      }
      y -= step; row += 1
    }

    // A few faint stars of dust in the sky, twinkling slowly.
    for index in 0..<18 {
      let seed = Double(index) * 12.9898
      let sx = CGFloat((sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)).magnitude * w
      let sy = CGFloat((sin(seed * 1.7) * 23421.631).truncatingRemainder(dividingBy: 1)).magnitude * horizon * 0.7
      if abs(sx - center) < radius * 1.05 && sy > horizon - radius * 1.05 { continue }
      dots.append(Dot(x: sx, y: sy, r: 0.8, hue: 0.55, alpha: 0.18 + 0.14 * (0.5 + 0.5 * sin(time * 0.6 + seed))))
    }

    // The sea: rows that spread apart toward the viewer, drifting sideways, with the sun's reflection
    // as a warm column that narrows into the distance.
    var rowY = horizon + 5
    var gap: CGFloat = 4
    var seaRow = 0
    while rowY < h - 2 {
      let near = (rowY - horizon) / max(h - horizon, 1)     // 0 far … 1 near
      let spacing = 5 + near * 5
      let drift = CGFloat(sin(time * 0.35 + Double(seaRow) * 0.9)) * (2 + near * 4)
      var x = (drift.truncatingRemainder(dividingBy: spacing)) - spacing
      let reflection = radius * (0.9 - near * 0.35)
      while x < w + spacing {
        let fromCenter = abs(x - center)
        let warm = fromCenter < reflection
        let shimmer = 0.5 + 0.5 * sin(time * 1.1 + Double(x) * 0.07 + Double(seaRow) * 1.3)
        if warm {
          // Broken reflection: some dots drop out as the light moves.
          if shimmer > 0.32 {
            dots.append(Dot(x: x, y: rowY, r: 0.9 + near * 0.8, hue: 0.9 - Double(fromCenter / reflection) * 0.2,
                            alpha: (0.35 + 0.45 * shimmer) * (1 - Double(fromCenter / reflection) * 0.6)))
          }
        } else {
          dots.append(Dot(x: x, y: rowY, r: 0.7 + near * 0.7, hue: 0.05 + Double(x / w) * 0.25,
                          alpha: (0.16 + 0.3 * near) * (0.7 + 0.3 * shimmer)))
        }
        x += spacing
      }
      rowY += gap; gap += 1.1; seaRow += 1
    }

    // Birds: each a pair of dotted wings that flap, drifting slowly across and wrapping around.
    let birds: [(lane: CGFloat, speed: Double, scale: CGFloat, phase: Double)] = [
      (0.20, 9, 1.0, 0.0), (0.28, 9, 0.85, 1.7), (0.13, 9, 0.75, 3.1), (0.38, 7, 0.65, 4.4),
    ]
    let travel = w + 80
    for (index, bird) in birds.enumerated() {
      let offset = Double(index) * 0.21
      let progress = (time / (travel / bird.speed) + offset + bird.phase * 0.05).truncatingRemainder(dividingBy: 1)
      let bx = CGFloat(progress) * travel - 40
      let by = h * bird.lane + CGFloat(sin(time * 0.8 + bird.phase)) * 3
      let flap = sin(time * 3.2 + bird.phase)          // -1 … 1
      let span = 17 * bird.scale
      for side in [-1.0, 1.0] {
        for k in 1...4 {
          let t = Double(k) / 4
          // The wing bends at the elbow: the inner half lifts with the flap, the tip lags behind it.
          let lift = flap * (t < 0.5 ? t * 2 : 1) * 0.55 + (t > 0.5 ? (t - 0.5) * 0.6 * -flap : 0)
          let px = bx + CGFloat(side * t) * span
          let py = by - CGFloat(lift) * span * 0.6 + CGFloat(t * t) * span * 0.18
          dots.append(Dot(x: px, y: py, r: 1.0 * bird.scale + 0.45, hue: nil, alpha: 0.8 - t * 0.2))
        }
      }
      dots.append(Dot(x: bx, y: by + 0.5, r: 1.3 * bird.scale + 0.35, hue: nil, alpha: 0.85))
    }
    return dots
  }
}

struct InboxDuskView: View {
  let title: String
  let detail: String
  var previewTime: Double? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private static let tide: [(Double, Double, Double)] = [
    (0.47, 0.85, 0.79), (0.54, 0.73, 0.94), (0.73, 0.63, 0.93), (0.90, 0.66, 0.79), (0.95, 0.74, 0.55),
  ]
  private static func color(_ hue: Double) -> Color {
    let x = min(0.999, max(0, hue)) * Double(tide.count - 1)
    let i = Int(x), f = x - Double(i)
    let a = tide[i], b = tide[i + 1]
    return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
  }

  var body: some View {
    VStack(spacing: 18) {
      TimelineView(.animation(minimumInterval: 1 / 24, paused: previewTime != nil || reduceMotion || scenePhase != .active)) { timeline in
        let time = previewTime ?? (reduceMotion ? 4 : timeline.date.timeIntervalSinceReferenceDate)
        Canvas { context, size in
          for dot in DuskGeometry.dots(size: size, time: time) {
            let rect = CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2)
            context.fill(Path(ellipseIn: rect), with: .color((dot.hue.map(Self.color) ?? Palette.ink).opacity(dot.alpha)))
          }
        }
      }
      .frame(width: 300, height: 190)
      .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title).font(.coveSubheading).foregroundStyle(Palette.ink)
        Text(detail).font(.coveSecondary).foregroundStyle(Palette.body).multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 24)
    .accessibilityElement(children: .combine)
  }
}
