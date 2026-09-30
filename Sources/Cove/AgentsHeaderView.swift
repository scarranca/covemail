import CoveCore
import SwiftUI

/// A face drawn only with dots, lit like a relief: the agents' portrait on the Agents screen.
/// The shape is a height field (head, brow, eyes, nose, lips, chin) shaded by one light.
enum AgentFaceGeometry {
  struct Dot { let x: Double; let y: Double; let lit: Double; let accent: Double; let edge: Double }
  private static func gauss(_ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> Double {
    exp(-(x * x) / (2 * sx * sx) - (y * y) / (2 * sy * sy))
  }
  // Features sit slightly right of center, so the head reads as turned three-quarters.
  private static let turn = 0.13
  private static func height(_ x: Double, _ y: Double) -> Double {
    let e = (x / 0.66) * (x / 0.66) + ((y - 0.02) / 0.9) * ((y - 0.02) / 0.9)
    guard e < 1 else { return 0 }
    let fx = x - turn
    var h = sqrt(1 - e)
    h += 0.08 * gauss(fx, y + 0.27, 0.38, 0.06)                       // brow
    h -= 0.12 * (gauss(fx - 0.25, y + 0.13, 0.10, 0.05) + gauss(fx + 0.23, y + 0.13, 0.09, 0.05)) // eyes
    h += 0.22 * gauss(fx + 0.01, y - 0.06, 0.06, 0.17)                // nose bridge
    h += 0.18 * gauss(fx + 0.02, y - 0.22, 0.08, 0.06)                 // nose tip
    h += 0.07 * (gauss(fx - 0.36, y - 0.08, 0.11, 0.12) + gauss(fx + 0.33, y - 0.08, 0.10, 0.12)) // cheeks
    h += 0.09 * gauss(fx, y - 0.43, 0.17, 0.045)                       // lips
    h -= 0.07 * gauss(fx, y - 0.44, 0.15, 0.012)                       // mouth line
    h += 0.08 * gauss(fx - 0.01, y - 0.70, 0.17, 0.09)                 // chin
    return h
  }
  /// Dots for a canvas of this size; the face fills its height, centered at `centerX` (0–1).
  static func dots(width: Double, height canvasHeight: Double, spacing: Double = 5, centerX: Double = 0.5) -> [Dot] {
    guard width > 0, canvasHeight > 0 else { return [] }
    let scale = canvasHeight * 0.56
    let cx = width * centerX, cy = canvasHeight * 0.52
    let light = { () -> (Double, Double, Double) in
      let v = (-0.3, -0.4, 0.87); let n = sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2); return (v.0 / n, v.1 / n, v.2 / n)
    }()
    var result: [Dot] = []
    var row = 0
    var py = spacing / 2
    while py < canvasHeight {
      var px = spacing / 2 + (row.isMultiple(of: 2) ? 0 : spacing / 2)
      while px < width {
        let x = (px - cx) / scale, y = (py - cy) / scale
        let e = (x / 0.66) * (x / 0.66) + ((y - 0.02) / 0.9) * ((y - 0.02) / 0.9)
        if e < 1.0 {
          let d = 0.012
          let gx = 0.42 * (Self.height(x + d, y) - Self.height(x - d, y)) / (2 * d)
          let gy = 0.42 * (Self.height(x, y + d) - Self.height(x, y - d)) / (2 * d)
          let n = sqrt(gx * gx + gy * gy + 1)
          let lambert = max(0, (-gx * light.0 - gy * light.1 + light.2) / n)
          let shade = max(0.22, min(1, 0.2 + (lambert - 0.5) / 0.55)) * (1 - 0.6 * max(0, (e - 0.78) / 0.22))
          let fx = x - turn
          let accent = max(gauss(fx - 0.25, y + 0.12, 0.05, 0.03), gauss(fx + 0.23, y + 0.12, 0.045, 0.03), gauss(fx, y - 0.43, 0.12, 0.028))
          let edge = max(0, min(1, (e - 0.72) / 0.28))
          result.append(Dot(x: px, y: py, lit: shade, accent: accent, edge: edge))
        } else if e < 1.9, (row + Int(px / spacing)) % 3 == 0 {
          // A faint halo around the head keeps the silhouette soft, like the reference.
          result.append(Dot(x: px, y: py, lit: 0.12 * (1.9 - e), accent: 0, edge: 1))
        }
        px += spacing
      }
      py += spacing * 0.9
      row += 1
    }
    return result
  }
}

/// Draws the dot face with a slow reading line passing over it; Reduce Motion keeps it still.
struct AgentFaceView: View {
  var previewTime: Double?
  var active = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var cache: (size: CGSize, dots: [AgentFaceGeometry.Dot]) = (.zero, [])
  private var animated: Bool { previewTime == nil && !reduceMotion && scenePhase == .active && active }
  static let accent = Color(red: 0.93, green: 0.52, blue: 0.42)
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animated)) { timeline in
      let time = previewTime ?? (animated ? timeline.date.timeIntervalSinceReferenceDate : 0)
      Canvas { context, size in
        let dots = cache.size == size ? cache.dots : AgentFaceGeometry.dots(width: size.width, height: size.height, spacing: max(3.4, size.height / 72), centerX: 0.5)
        // The reading line travels down the face every 9 seconds.
        let scan = (time.truncatingRemainder(dividingBy: 9) / 9) * (size.height * 1.4) - size.height * 0.2
        // Eight tones, drawn as one path each, keep the shading smooth without per-dot fills.
        var tones = Array(repeating: Path(), count: 8)
        var warm = Path()
        for dot in dots {
          let near = exp(-pow((dot.y - scan) / 14, 2))
          let breathe = 0.05 * sin(time * 0.7 + dot.x * 0.02)
          let lit = min(1, max(0, dot.lit + near * 0.3 * (1 - dot.edge * 0.7) + breathe * (1 - dot.edge)))
          let radius = 0.5 + 1.05 * lit
          let rect = CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)
          if dot.accent > 0.5 { warm.addEllipse(in: rect) }
          else { tones[min(7, Int(lit * 8))].addEllipse(in: rect) }
        }
        for (index, path) in tones.enumerated() {
          context.fill(path, with: .color(Color(white: 0.72 + 0.03 * Double(index)).opacity(0.18 + 0.1 * Double(index))))
        }
        context.fill(warm, with: .color(Self.accent.opacity(0.9)))
      }
    }
    .background(GeometryReader { geometry in
      Color.clear.onAppear { refresh(geometry.size) }.onChange(of: geometry.size) { _, size in refresh(size) }
    })
    .accessibilityHidden(true)
  }
  private func refresh(_ size: CGSize) {
    guard size != cache.size else { return }
    cache = (size, AgentFaceGeometry.dots(width: size.width, height: size.height, spacing: max(3.4, size.height / 72), centerX: 0.5))
  }
}

/// One line of what agents did, like live captions over the portrait: the newest in the accent color.
struct AgentCaptions: View {
  let lines: [String]
  var previewIndex: Int?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var index = 0
  var body: some View {
    let current = previewIndex ?? index
    VStack(alignment: .leading, spacing: 6) {
      if !lines.isEmpty {
        Text(lines[current % lines.count]).font(.coveLabel).foregroundStyle(AgentFaceView.accent)
          .lineLimit(1).id("now-\(current)")
          .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        if lines.count > 1 {
          Text(lines[(current + 1) % lines.count]).font(.coveSecondary).foregroundStyle(Color(white: 0.62))
            .lineLimit(1).id("next-\(current)").transition(.opacity)
        }
      }
    }
    .animation(.easeOut(duration: 0.6), value: current)
    .task(id: lines) {
      guard previewIndex == nil, !reduceMotion, lines.count > 1 else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3.6))
        if Task.isCancelled { break }
        index += 1
      }
    }
  }
}

/// The Agents screen's header: why agents exist, what yours have done, and the portrait.
struct AgentsHeader: View {
  @Bindable var store: AppStore
  var compact = false
  var previewTime: Double?
  private var active: Int { store.customAgents.agents.filter { $0.status == .active }.count }
  private var repliesWaiting: [CustomAgentRun] {
    store.customAgents.runs.filter { $0.replySuggestion != nil && $0.replyApplied != true }
  }
  private var labeledThisWeek: Int {
    let since = Date().addingTimeInterval(-7 * 86_400)
    return store.customAgents.runs.filter { $0.appliedLabel != nil && $0.date >= since }.count
  }
  /// Real recent work when there is some; otherwise, clearly marked examples of what agents do.
  private var captions: (lines: [String], examples: Bool) {
    let names = Dictionary(store.customAgents.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let recent = store.customAgents.runs.filter { $0.error == nil && ($0.appliedLabel != nil || $0.replySuggestion != nil) }
      .sorted { $0.date > $1.date }.prefix(6)
    let lines = recent.map { run -> String in
      let subject = run.subject.isEmpty ? "an email" : "“\(run.subject)”"
      let name = names[run.agentID] ?? "An agent"
      if run.replySuggestion != nil { return "\(name) drafted a reply to \(subject)" }
      return "\(name) filed \(subject) under \(run.appliedLabel ?? "")"
    }
    if !lines.isEmpty { return (lines, false) }
    return ([
      "Invoice #2048 from Acme → Finance / Invoices",
      "Client asks about next week’s delivery → reply drafted",
      "“Can we find 30 minutes?” → reply drafted",
      "Flight confirmation → Travel",
    ], true)
  }
  var body: some View {
    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .center, spacing: 28))
    layout {
      VStack(alignment: .leading, spacing: 14) {
        Text("Agents work your inbox for you").font(.coveTitle).foregroundStyle(Color(white: 0.96))
          .fixedSize(horizontal: false, vertical: true)
        Text("Give each one a job. When new mail fits, it files it, drafts a reply for you to review, or tells you. Nothing is ever sent for you.")
          .font(.coveText).foregroundStyle(Color(white: 0.84)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          tag(active == 0 ? "No agents on yet" : "\(active) on")
          if labeledThisWeek > 0 { tag("\(labeledThisWeek) filed this week") }
          if let first = repliesWaiting.first {
            Button { store.agentActivityID = first.agentID } label: {
              tag("\(repliesWaiting.count) \(repliesWaiting.count == 1 ? "reply" : "replies") to review", warm: true)
            }.buttonStyle(.plain).help("Open the agent’s activity to review its replies")
          }
        }
        Button { store.newCustomAgent() } label: { Label("Create agent", systemImage: "plus") }
          .buttonStyle(SecondaryButton(compact: true)).frame(height: 36).padding(.top, 2)
      }.frame(maxWidth: compact ? .infinity : 400, alignment: .leading)
      ZStack(alignment: .bottomLeading) {
        AgentFaceView(previewTime: previewTime).frame(height: 250)
        VStack(alignment: .leading, spacing: 6) {
          if captions.examples {
            Text("For example").font(.coveMetadata).foregroundStyle(Color(white: 0.6))
          }
          AgentCaptions(lines: captions.lines, previewIndex: previewTime == nil ? nil : 0)
        }.padding(.horizontal, 6).padding(.vertical, 8)
          .background(Color(red: 0.114, green: 0.125, blue: 0.165).opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
          .accessibilityElement(children: .combine)
          .accessibilityLabel(captions.examples ? "Examples of what agents do" : "Recent agent activity")
      }.frame(maxWidth: .infinity)
    }
    .padding(26).frame(minHeight: 280)
    .background(Color(red: 0.114, green: 0.125, blue: 0.165), in: RoundedRectangle(cornerRadius: 10))
  }
  private func tag(_ text: String, warm: Bool = false) -> some View {
    Text(text).font(.coveCaption)
      .foregroundStyle(warm ? Color(red: 0.94, green: 0.78, blue: 0.64) : Color(white: 0.87))
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
  }
}

/// Ready-made agents, so the screen shows what agents are for before anyone writes a rule.
struct AgentTemplateGallery: View {
  @Bindable var store: AppStore
  var title = "Start from an idea"
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.coveSection).accessibilityAddTraits(.isHeader)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
        ForEach(CustomAgentTemplate.all) { template in
          AgentTemplateCard(template: template) { store.agentEditor = template.make(); store.agentActivityID = nil }
        }
      }
    }
  }
}

private struct AgentTemplateCard: View {
  let template: CustomAgentTemplate
  let open: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: template.symbol).font(.cove(size: 15)).frame(width: 32, height: 32)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
          Spacer()
          Image(systemName: "arrow.right").font(.cove(size: 12)).foregroundStyle(Palette.body)
            .opacity(hovering ? 1 : 0)
        }
        Text(template.title).font(.coveSubheading)
        Text(template.pitch).font(.coveSecondary).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if template.labels { chip("Labels", "tag") }
          if template.drafts { chip("Drafts replies", "square.and.pencil") }
        }
      }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(hovering ? Palette.surface : Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Palette.inputBorder : Palette.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).onHover { hovering = $0 }
      .accessibilityLabel("\(template.title) agent. \(template.pitch)")
      .accessibilityHint("Opens it as a draft to review before turning it on")
  }
  private func chip(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).font(.coveMetadata).foregroundStyle(Palette.body)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
  }
}
