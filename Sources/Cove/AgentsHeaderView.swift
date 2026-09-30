import CoveCore
import ImageIO
import SwiftUI

/// A face painted only by its shadows: dots gather where the head turns from the light and along its outline,
/// and the lit side stays open, like a charcoal study. The shape is a height field (tapered head, brow, eye
/// sockets, nose, lips, chin) lit from the upper left.
enum AgentFaceGeometry {
  /// `ink` is how much shadow a dot carries (0 is lit, 1 is deepest).
  struct Dot { let x: Double; let y: Double; let ink: Double; let accent: Double }
  private static func gauss(_ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> Double {
    exp(-(x * x) / (2 * sx * sx) - (y * y) / (2 * sy * sy))
  }
  // Features sit right of center, so the head reads as turned three-quarters.
  private static let turn = 0.12
  /// The head narrows from the cheekbones into the jaw and chin.
  private static func extent(_ x: Double, _ y: Double) -> Double {
    let taper = y > 0.1 ? 0.62 - 0.2 * pow(min(1, (y - 0.1) / 0.8), 1.8) : 0.62
    return (x / taper) * (x / taper) + ((y - 0.02) / 0.9) * ((y - 0.02) / 0.9)
  }
  private static func height(_ x: Double, _ y: Double) -> Double {
    let e = extent(x, y)
    guard e < 1 else { return 0 }
    let fx = x - turn
    var h = 0.7 * sqrt(1 - e)
    h += 0.07 * gauss(fx, y + 0.26, 0.36, 0.05)                                           // brow
    h -= 0.10 * (gauss(fx - 0.23, y + 0.12, 0.09, 0.045) + gauss(fx + 0.21, y + 0.12, 0.08, 0.045)) // eye sockets
    h += 0.20 * gauss(fx + 0.01, y - 0.05, 0.05, 0.16)                                    // nose bridge
    h += 0.14 * gauss(fx + 0.02, y - 0.2, 0.07, 0.05)                                     // nose tip
    h += 0.06 * (gauss(fx - 0.34, y - 0.06, 0.1, 0.11) + gauss(fx + 0.3, y - 0.06, 0.09, 0.11)) // cheekbones
    h += 0.06 * gauss(fx, y - 0.4, 0.15, 0.04)                                            // lips
    h += 0.06 * gauss(fx - 0.01, y - 0.66, 0.15, 0.08)                                    // chin
    return h
  }
  /// Soft shadow the light alone can't make: under the brow, beside the nose, under the lip and the jaw.
  private static func occlusion(_ x: Double, _ y: Double) -> Double {
    let fx = x - turn
    return 0.55 * (gauss(fx - 0.23, y + 0.1, 0.08, 0.03) + gauss(fx + 0.21, y + 0.1, 0.07, 0.03))
      + 0.45 * gauss(fx - 0.07, y - 0.12, 0.035, 0.12)
      + 0.4 * gauss(fx + 0.01, y - 0.27, 0.07, 0.02)
      + 0.35 * gauss(fx, y - 0.405, 0.12, 0.012)
      + 0.3 * gauss(fx, y - 0.52, 0.09, 0.025)
  }
  /// Strokes a painter adds on top of the shading: brows, lids, irises, nostrils and the mouth line.
  private static func strokes(_ x: Double, _ y: Double) -> Double {
    let fx = x - turn
    func arc(_ cx: Double, _ cy: Double, _ half: Double, _ bend: Double, _ thick: Double) -> Double {
      let t = (fx - cx) / half
      guard abs(t) < 1.15 else { return 0 }
      let curve = cy - bend * (1 - t * t)
      return exp(-pow((y - curve) / thick, 2)) * (1 - 0.5 * t * t)
    }
    let brows = 0.75 * (arc(-0.24, -0.25, 0.15, 0.04, 0.03) + arc(0.21, -0.25, 0.12, 0.035, 0.028))
    let lids = 0.6 * (arc(-0.23, -0.115, 0.085, 0.03, 0.02) + arc(0.21, -0.115, 0.07, 0.026, 0.02))
    let irises = 0.35 * (gauss(fx - 0.225, y + 0.1, 0.03, 0.028) + gauss(fx + 0.205, y + 0.1, 0.027, 0.028))
    let nostrils = 0.55 * (gauss(fx - 0.05, y - 0.235, 0.03, 0.02) + gauss(fx + 0.065, y - 0.235, 0.026, 0.02))
    let mouth = 0.8 * arc(0.0, 0.405, 0.14, -0.015, 0.02)
    return brows + lids + irises + nostrils + mouth
  }
  /// Dots for a canvas of this size; the face fills its height, centered at `centerX` (0–1).
  static func dots(width: Double, height canvasHeight: Double, spacing: Double = 5, centerX: Double = 0.5) -> [Dot] {
    guard width > 0, canvasHeight > 0 else { return [] }
    let scale = canvasHeight * 0.56
    let cx = width * centerX, cy = canvasHeight * 0.52
    let light = { () -> (Double, Double, Double) in
      let v = (-0.6, -0.22, 0.77); let n = sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2); return (v.0 / n, v.1 / n, v.2 / n)
    }()
    var result: [Dot] = []
    var row = 0
    var py = spacing / 2
    while py < canvasHeight {
      var px = spacing / 2 + (row.isMultiple(of: 2) ? 0 : spacing / 2)
      while px < width {
        let x = (px - cx) / scale, y = (py - cy) / scale
        let e = extent(x, y)
        if e < 1.0 {
          let d = 0.012
          let gx = 0.9 * (height(x + d, y) - height(x - d, y)) / (2 * d)
          let gy = 0.9 * (height(x, y + d) - height(x, y - d)) / (2 * d)
          let n = sqrt(gx * gx + gy * gy + 1)
          let lambert = max(0, (-gx * light.0 - gy * light.1 + light.2) / n)
          let shadow = 0.7 * pow(max(0, min(1, (0.97 - lambert) / 0.8)), 1.3)
          // The outline: a thin line on the lit side, a wider falloff on the shadow side.
          let rim = pow(max(0, (e - 0.82) / 0.18), 2) * (x < 0 ? 0.4 : 0.35)
          let ink = min(1, shadow + 0.8 * occlusion(x, y) + strokes(x, y) + rim)
          if ink > 0.08 {
            let fx = x - turn
            result.append(Dot(x: px, y: py, ink: ink, accent: gauss(fx, y - 0.4, 0.12, 0.03)))
          }
        }
        px += spacing
      }
      py += spacing * 0.9
      row += 1
    }
    return result
  }
}

/// Halftones a real portrait: each dot's size follows how dark the photo is under it, so a light-background
/// portrait with strong side light becomes a face painted by its shadows.
enum AgentPortrait {
  static let image: CGImage? = {
    guard let url = Bundle.module.url(forResource: "agent-portrait", withExtension: "jpg") ?? Bundle.module.url(forResource: "agent-portrait", withExtension: "png"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }()
  /// The portrait fills the canvas height, centered at `centerX`; light areas give no dots.
  static func dots(_ image: CGImage, width: Double, height: Double, spacing: Double, centerX: Double = 0.5) -> [AgentFaceGeometry.Dot] {
    let columns = max(1, Int(width.rounded())), rows = max(1, Int(height.rounded()))
    guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
    let drawnHeight = Double(rows)
    let drawnWidth = drawnHeight * Double(image.width) / Double(max(image.height, 1))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: width * centerX - drawnWidth / 2, y: 0, width: drawnWidth, height: drawnHeight))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
    var result: [AgentFaceGeometry.Dot] = []
    var row = 0
    var py = spacing / 2
    while py < height {
      var px = spacing / 2 + (row.isMultiple(of: 2) ? 0 : spacing / 2)
      while px < width {
        // Average a small patch so dots follow tone, not film grain.
        var total = 0.0, count = 0.0
        let radius = max(1, Int(spacing / 2))
        for dy in -radius...radius {
          for dx in -radius...radius {
            let sx = Int(px) + dx, sy = Int(py) + dy
            guard sx >= 0, sx < columns, sy >= 0, sy < rows else { continue }
            total += Double(data[sy * columns + sx]) / 255; count += 1
          }
        }
        let luminance = count > 0 ? total / count : 1
        let ink = max(0, min(1, (0.93 - luminance) / 0.78))
        if ink > 0.07 { result.append(AgentFaceGeometry.Dot(x: px, y: py, ink: ink, accent: 0)) }
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
        let dots = cache.size == size ? cache.dots : Self.makeDots(size)
        // The reading line travels down the face every 9 seconds.
        let scan = (time.truncatingRemainder(dividingBy: 9) / 9) * (size.height * 1.4) - size.height * 0.2
        // Eight tones, drawn as one path each, keep the shading smooth without per-dot fills.
        var tones = Array(repeating: Path(), count: 8)
        var warm = Path()
        for dot in dots {
          let near = exp(-pow((dot.y - scan) / 16, 2))
          let breathe = 0.04 * sin(time * 0.7 + dot.x * 0.02)
          let ink = min(1, max(0, dot.ink + near * 0.18 + breathe))
          let radius = 0.3 + 1.1 * ink
          let rect = CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)
          if dot.accent > 0.5 { warm.addEllipse(in: rect) }
          else { tones[min(7, Int(ink * 8))].addEllipse(in: rect) }
        }
        for (index, path) in tones.enumerated() {
          context.fill(path, with: .color(Color(white: 0.7 + 0.035 * Double(index)).opacity(0.1 + 0.085 * Double(index))))
        }
        context.fill(warm, with: .color(Self.accent.opacity(0.55)))
      }
    }
    .background(GeometryReader { geometry in
      Color.clear.onAppear { refresh(geometry.size) }.onChange(of: geometry.size) { _, size in refresh(size) }
    })
    .accessibilityHidden(true)
  }
  private static func makeDots(_ size: CGSize) -> [AgentFaceGeometry.Dot] {
    let spacing = max(3.4, size.height / 72)
    if let image = AgentPortrait.image {
      return AgentPortrait.dots(image, width: size.width, height: size.height, spacing: spacing)
    }
    return AgentFaceGeometry.dots(width: size.width, height: size.height, spacing: spacing, centerX: 0.5)
  }
  private func refresh(_ size: CGSize) {
    guard size != cache.size else { return }
    cache = (size, Self.makeDots(size))
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
