import CoveCore
import SwiftUI

/// The Pen point-cloud treatment, shaped by the seven daily counts instead of sample geometry.
enum MailTideGeometry {
  struct Dot { let x: Double; let y: Double; let radius: Double; let opacity: Double }
  static func shouldAnimate(reduceMotion: Bool, active: Bool, visible: Bool, total: Int) -> Bool {
    !reduceMotion && active && visible && total > 0
  }
  static func dots(counts: [Int], width: Double, height: Double, time: Double) -> [[Dot]] {
    guard width > 0, height > 0, !counts.isEmpty else { return [] }
    let maximum = Double(max(counts.max() ?? 0, 1))
    let empty = counts.allSatisfy { $0 == 0 }
    let columns = max(2, Int(width / 3.7))
    return (0..<(empty ? 1 : 14)).map { layer in
      let depth = Double(layer) / 13
      return (0..<columns).map { column in
        let x = Double(column) / Double(columns - 1)
        // Day values sit at the centers of equal-width columns below the field.
        let position = min(Double(counts.count - 1), max(0, x * Double(counts.count) - 0.5))
        let index = min(counts.count - 1, Int(position))
        let next = min(counts.count - 1, index + 1)
        let fraction = position - Double(index)
        let smooth = fraction * fraction * (3 - 2 * fraction)
        let volume = (Double(counts[index]) * (1 - smooth) + Double(counts[next]) * smooth) / maximum
        // A slow 14-second ripple is at most 1.6 pt. Values and daily positions stay fixed.
        let ripple = empty ? 0 : sin(x * .pi * 5 - time * .pi / 7 + depth * 2.4) * 1.6
        let ridge = height * (0.82 - volume * 0.63)
        let y = ridge + depth * (height * 0.90 - ridge) * 0.64 + ripple
        return Dot(x: 2 + x * max(0, width - 4), y: y, radius: layer == 0 ? 0.82 : 0.65,
                   opacity: layer == 0 ? 0.95 : max(0.1, 0.66 * pow(1 - depth, 1.3)))
      }
    }
  }
}

struct MailTideView: View {
  let tide: MailTide
  var labels: [(name: String, count: Int)] = []
  var viewportHeight: CGFloat = 1000
  /// Fixed phase for offscreen previews and image comparisons.
  var previewTime: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var visible = false
  @State private var selectedDay: Date?
  private static let colors: [Color] = [
    Color(red: 0.47, green: 0.85, blue: 0.79), Color(red: 0.54, green: 0.73, blue: 0.94),
    Color(red: 0.73, green: 0.63, blue: 0.93), Color(red: 0.90, green: 0.66, blue: 0.79),
    Color(red: 0.95, green: 0.74, blue: 0.55),
  ]
  private var animated: Bool {
    previewTime == nil && MailTideGeometry.shouldAnimate(reduceMotion: reduceMotion, active: scenePhase == .active, visible: visible, total: tide.total)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack { heading; Spacer(minLength: 12); dateRange }
        VStack(alignment: .leading, spacing: 5) { heading; dateRange }
      }
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
        let time = previewTime ?? (animated ? context.date.timeIntervalSinceReferenceDate : 0)
        Canvas { context, size in
          for layer in MailTideGeometry.dots(counts: tide.days.map(\.count), width: size.width, height: size.height, time: time) {
            var path = Path()
            for dot in layer {
              path.addEllipse(in: CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2))
            }
            context.opacity = layer.first?.opacity ?? 1
            context.fill(path, with: .linearGradient(Gradient(colors: Self.colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
          }
        }
      }.frame(height: 128).accessibilityHidden(true)
        .background {
          GeometryReader { geometry in
            let frame = geometry.frame(in: .named("hub-scroll"))
            Color.clear.preference(key: TideVisibilityKey.self, value: frame.maxY > 0 && frame.minY < viewportHeight)
          }
        }.onPreferenceChange(TideVisibilityKey.self) { visible = $0 }
        .onDisappear { visible = false }
      HStack(spacing: 0) {
        ForEach(tide.days) { day in
          Button { selectedDay = selectedDay == day.date ? nil : day.date } label: {
            VStack(spacing: 4) {
              Text("\(day.count)").font(.coveCaption).monospacedDigit()
              Text(day.date, format: .dateTime.weekday(.abbreviated)).font(.coveMetadata).foregroundStyle(Color(white: 0.83))
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
              .background(selectedDay == day.date ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
          }.buttonStyle(.plain)
            .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)): \(day.count) received emails in downloaded mail")
            .help("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.count) received emails in downloaded mail")
        }
      }
      Divider().overlay(.white.opacity(0.14))
      if let day = tide.days.first(where: { $0.date == selectedDay }) {
        Text("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.count) received in downloaded mail")
          .font(.coveMetadata).foregroundStyle(Color(white: 0.83))
      } else if labels.isEmpty {
        Text("Downloaded mail · last 7 days").font(.coveMetadata).foregroundStyle(Color(white: 0.83))
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { legend }
          Text("Downloaded mail · \(labels.count) agent categories").font(.coveMetadata)
        }.foregroundStyle(Color(white: 0.83))
      }
    }.foregroundStyle(Color(white: 0.96))
  }
  private var heading: some View {
    Text("\(tide.total) emails received").font(.coveSubheading)
      .help("Received messages downloaded to Cove in the last seven days. Sent mail, drafts, spam, and trash are excluded; this is not a complete Gmail total.")
  }
  private var dateRange: some View {
    Text("\(tide.days.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")–\(tide.days.last?.date.formatted(.dateTime.day()) ?? "") · downloaded")
      .font(.coveMetadata).foregroundStyle(Color(white: 0.83))
  }
  private var legend: some View {
    ForEach(Array(labels.prefix(4).enumerated()), id: \.offset) { index, label in
      HStack(spacing: 4) {
        Circle().fill(Self.colors[index]).frame(width: 4, height: 4)
        Text("\(label.name) \(label.count)").font(.coveMetadata).lineLimit(1)
      }.help("\(label.count) received emails with agent label \(label.name). An email can have multiple labels.")
    }
  }
}

private struct TideVisibilityKey: PreferenceKey {
  static var defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
