import AppKit
import Observation
import SwiftUI
import CoreText

@MainActor @Observable final class WritingActivity {
  var working = false
  var stage = ""
  var preview: String?
  /// Draft text arriving from the model while it writes; replaced by the finished suggestion.
  var streaming: String?
  var revision = 0
  var previewSelection = NSRange(location: 0, length: 0)
  /// The draft streamed in live, so the finished suggestion appears without replaying an animation.
  var streamed = false
  /// The inline ask line has something to show (a failure) even while collapsed.
  var needsAttention = false
  var focusRequest = 0
  var applyRequest = 0
  var discardRequest = 0
  var rewriteRequest = 0
  func reset() { working = false; stage = ""; preview = nil; streaming = nil; streamed = false; previewSelection = NSRange(location: 0, length: 0) }
}

struct WritingCanvasPreview: View {
  let text: String
  var animated = true
  var onEdit: ((String) -> Void)? = nil
  var onSelection: ((NSRange) -> Void)? = nil
  var selectedRange: NSRange? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Label("Suggestion preview", systemImage: "sparkles")
        .font(.coveMetadata).foregroundStyle(Palette.body)
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
      WritingInkCanvas(text: text, animated: animated && !reduceMotion, onEdit: onEdit, onSelection: onSelection, selectedRange: selectedRange)
      Text(onEdit == nil ? "Review and apply when it feels right." : "Edit here, then apply when you’re ready.").font(.coveMetadata).foregroundStyle(Palette.body)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }.background(Palette.canvas)
  }
}

/// TextKit owns both the final selectable text and the glyph coordinates. There is no
/// second layout that can drift away from the particles' destinations at narrow widths.
struct WritingInkCanvas: NSViewRepresentable {
  let text: String
  var animated: Bool
  var onEdit: ((String) -> Void)? = nil
  var onSelection: ((NSRange) -> Void)? = nil
  var selectedRange: NSRange? = nil
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    scroll.drawsBackground = false; scroll.borderType = .noBorder
    let view = WritingInkTextView(frame: .zero)
    view.isEditable = onEdit != nil; view.isSelectable = true
    view.allowsUndo = true
    view.delegate = context.coordinator
    view.isRichText = false; view.drawsBackground = true; view.backgroundColor = .white
    view.textContainerInset = NSSize(width: 24, height: 4)
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? WritingInkTextView else { return }
    context.coordinator.onEdit = onEdit
    context.coordinator.onSelection = onSelection
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    view.isEditable = onEdit != nil
    view.setSuggestion(text, animated: animated)
    if let selectedRange {
      let safe = Range(selectedRange, in: text) != nil ? selectedRange : NSRange(location: 0, length: 0)
      if view.selectedRange() != safe { view.setSelectedRange(safe) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var onEdit: ((String) -> Void)?
    var onSelection: ((NSRange) -> Void)?
    var updating = false
    func textDidChange(_ notification: Notification) {
      guard !updating, let view = notification.object as? WritingInkTextView else { return }
      view.finishMotion()
      onEdit?(view.string)
      onSelection?(view.selectedRange())
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard !updating, let view = notification.object as? WritingInkTextView else { return }
      onSelection?(view.selectedRange())
    }
  }
  static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
    (view.documentView as? WritingInkTextView)?.finishMotion()
  }
}

@MainActor final class WritingInkTextView: NSTextView {
  struct InkDot {
    let destination: CGPoint
    let order: Double
    let seed: Int
  }
  private(set) var inkDots: [InkDot] = []
  private(set) var motionProgress = 1.0
  private(set) var motionRunning = false
  private var timer: Timer?
  private var startedAt: TimeInterval = 0
  private var hasSuggestion = false
  private var layoutWidth = 0.0
  private var glyphLines: [(rect: CGRect, range: NSRange)] = []
  static let duration = 1.25
  static let maximumDots = 1400

  func setSuggestion(_ text: String, animated: Bool) {
    guard string != text || !hasSuggestion else {
      if !animated { finishMotion() }
      return
    }
    let shouldAnimate = animated && !hasSuggestion && !text.isEmpty
    hasSuggestion = true
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = CoveTypography.bodyLineSpacing
    let font = CoveTypography.nativeBody
    textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: NSColor(srgbRed: 48/255, green: 48/255, blue: 48/255, alpha: 1),
      .paragraphStyle: paragraph,
    ]))
    setAccessibilityLabel("Suggestion preview")
    setAccessibilityValue(text)
    layoutWidth = 0
    needsLayout = true
    if shouldAnimate { startMotion() } else { finishMotion() }
  }

  private func startMotion() {
    timer?.invalidate()
    motionProgress = 0; motionRunning = true
    startedAt = ProcessInfo.processInfo.systemUptime
    // A timer is active for this one finite reveal only, never for a completed preview.
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else { timer.invalidate(); return }
        self.motionProgress = min(1, (ProcessInfo.processInfo.systemUptime - self.startedAt) / Self.duration)
        self.needsDisplay = true
        if self.motionProgress >= 1 { self.finishMotion() }
      }
    }
  }

  func finishMotion() {
    timer?.invalidate(); timer = nil
    motionProgress = 1; motionRunning = false
    needsDisplay = true
  }

  /// Deterministic time sampling of the production renderer, used by native render tests.
  func sampleMotion(at progress: Double) {
    timer?.invalidate(); timer = nil; motionRunning = false
    motionProgress = min(1, max(0, progress)); needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    // Selection is immediately usable; a user never has to wait for the effect.
    finishMotion(); super.mouseDown(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    finishMotion(); super.scrollWheel(with: event)
  }

  override func keyDown(with event: NSEvent) {
    finishMotion(); super.keyDown(with: event)
  }

  override func layout() {
    super.layout()
    if abs(layoutWidth - bounds.width) > 0.5 {
      layoutWidth = bounds.width
      if motionProgress < 1 { rebuildInk() }
    }
  }

  private func rebuildInk() {
    inkDots = []; glyphLines = []
    guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return }
    manager.ensureLayout(for: container)
    let glyphRange = manager.glyphRange(for: container)
    guard glyphRange.length > 0 else { return }
    let inset = textContainerOrigin
    // Only animate the first visible canvas. Long drafts remain cheap and become fully
    // available together; no allocation or per-frame work proportional to the full body.
    let visibleHeight = min(max(180, enclosingScrollView?.contentView.bounds.height ?? 700), 700)
    var candidates: [(CGPoint, Double)] = []
    manager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, used, _, range, stop in
      if used.minY > visibleHeight { stop.pointee = true; return }
      if used.width > 0 { self.glyphLines.append((used.offsetBy(dx: inset.x, dy: inset.y), range)) }
      for index in range.location..<NSMaxRange(range) {
        let charIndex = manager.characterIndexForGlyph(at: index)
        guard charIndex < storage.length,
              let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont else { continue }
        guard let glyph = CGGlyph(exactly: manager.glyph(at: index)),
              let path = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else { continue }
        let offset = manager.location(forGlyphAt: index)
        let origin = CGPoint(x: inset.x + rect.minX + offset.x, y: inset.y + rect.minY + offset.y)
        let box = path.boundingBoxOfPath
        // Sampling the filled outline, rather than its bounding box, makes the dots
        // become the actual counters and stems of each letter (including ligatures).
        for y in stride(from: box.minY + 0.9, through: box.maxY, by: 2.2) {
          for x in stride(from: box.minX + 0.9, through: box.maxX, by: 2.2) {
            let point = CGPoint(x: x, y: y)
            if path.contains(point) {
              let position = CGPoint(x: origin.x + x, y: origin.y - y)
              let order = Double(self.glyphLines.count - 1) + min(1, max(0, (position.x - inset.x) / max(1, used.width)))
              candidates.append((position, order))
            }
          }
        }
      }
    }
    let denominator = max(1, Double(glyphLines.count))
    let strideSize = max(1, Int(ceil(Double(candidates.count) / Double(Self.maximumDots))))
    inkDots = stride(from: 0, to: candidates.count, by: strideSize).enumerated().map { seed, index in
      InkDot(destination: candidates[index].0, order: candidates[index].1 / denominator, seed: seed)
    }
  }

  /// The last frame lands exactly on glyph ink, with curved incoming motion decelerating
  /// into the letter. Dots for subsequent lines leave the source slightly later.
  func position(for dot: InkDot, progress: Double) -> CGPoint {
    let arrival = 0.38 + dot.order * 0.58
    let departure = max(0, arrival - 0.34)
    let t = min(1, max(0, (progress - departure) / (arrival - departure)))
    let travel = 1 - pow(1 - t, 3)
    let origin = CGPoint(x: max(bounds.width - 8, dot.destination.x + 80),
                         y: min(210, max(64, bounds.height * 0.35)) + CGFloat(dot.seed % 31 - 15) * 2.4)
    let arc = CGFloat(dot.seed % 17 - 8) * 3.5
    return CGPoint(x: origin.x + (dot.destination.x - origin.x) * travel,
                   y: origin.y + (dot.destination.y - origin.y) * travel + sin(t * .pi) * arc)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard motionProgress < 1, let manager = layoutManager else {
      super.draw(dirtyRect); return
    }
    if inkDots.isEmpty { rebuildInk() }
    NSColor.white.setFill(); dirtyRect.fill()
    // Reveal follows the same reading-order schedule as particle arrivals. Each clip
    // uncovers native glyph ink exactly where its dots finish, without moving layout.
    for (index, line) in glyphLines.enumerated() {
      let rect = line.rect
      let lineOrder = Double(index) / Double(max(1, glyphLines.count))
      let fraction = min(1, max(0, (motionProgress - 0.38 - lineOrder * 0.58) * Double(glyphLines.count) / 0.58))
      guard fraction > 0 else { continue }
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: CGRect(x: rect.minX - 1, y: rect.minY - 2,
                               width: (rect.width + 2) * fraction, height: rect.height + 4)).addClip()
      manager.drawGlyphs(forGlyphRange: line.range, at: textContainerOrigin)
      NSGraphicsContext.restoreGraphicsState()
    }
    for dot in inkDots {
      let arrival = 0.38 + dot.order * 0.58
      let departure = max(0, arrival - 0.34)
      guard motionProgress >= departure, motionProgress < arrival + 0.055 else { continue }
      let t = min(1, max(0, (motionProgress - departure) / (arrival - departure)))
      let fade = motionProgress < arrival ? min(1, t * 8) : max(0, 1 - (motionProgress - arrival) / 0.055)
      let point = position(for: dot, progress: motionProgress)
      let radius = 0.8 + 0.55 * (1 - t)
      NSColor(srgbRed: 48/255, green: 48/255, blue: 48/255, alpha: fade * 0.78).setFill()
      NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
  }
}


/// A small native indicator and honest phase label; Reduce Motion uses a static symbol.
struct WritingProgressRow: View {
  let stage: String
  let onCancel: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 10) {
      if reduceMotion { Image(systemName: "hourglass").foregroundStyle(Palette.body) }
      else { ProgressView().controlSize(.small).accessibilityLabel("Working") }
      Text(stage.isEmpty ? "Preparing your draft" : stage).font(.coveMetadata)
        .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onCancel) { Image(systemName: "xmark").padding(7).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Palette.body).help("Cancel drafting").accessibilityLabel("Cancel drafting")
    }.frame(minHeight: 36)
  }
}

struct WritingCanvasLoading: View {
  let stage: String
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(stage.isEmpty ? "Preparing your draft" : stage).font(.coveMetadata).foregroundStyle(Palette.body)
      GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 12) {
          RoundedRectangle(cornerRadius: 4).fill(Palette.sidebar).frame(width: 84, height: 9).padding(.bottom, 8)
          ForEach([0.90, 1.0, 0.72], id: \.self) { fraction in
            RoundedRectangle(cornerRadius: 4).fill(Palette.sidebar).frame(width: geometry.size.width * fraction, height: 9)
          }
        }
      }.frame(maxWidth: 420).frame(height: 100).accessibilityHidden(true)
      Spacer(minLength: 0)
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
  }
}


/// The AI is working: the Home chart's point cloud as a slow travelling wave above the ask line,
/// with the truthful stage beside it. Reduce Motion holds the wave still.
struct WritingThinkingBar: View {
  let stage: String
  /// Tests force the Reduce Motion rendering; the app uses the system setting.
  var stillOverride: Bool? = nil
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  private var reduceMotion: Bool { stillOverride ?? systemReduceMotion }
  private static let colors: [Color] = [
    Color(red: 0.47, green: 0.85, blue: 0.79), Color(red: 0.54, green: 0.73, blue: 0.94),
    Color(red: 0.73, green: 0.63, blue: 0.93), Color(red: 0.90, green: 0.66, blue: 0.79),
    Color(red: 0.95, green: 0.74, blue: 0.55),
  ]
  static func dots(width: Double, height: Double, time: Double) -> [[MailTideGeometry.Dot]] {
    guard width > 0, height > 0 else { return [] }
    let columns = max(2, Int(width / 4.2))
    return (0..<8).map { layer in
      let depth = Double(layer) / 7
      return (0..<columns).map { column in
        let x = Double(column) / Double(columns - 1)
        // Two slow travelling waves, like the tide chart's ridge, drifting left to right.
        let wave = 0.6 * sin(x * .pi * 3.2 - time * 1.6) + 0.4 * sin(x * .pi * 7.1 - time * 2.3 + 1.2)
        let ridge = height * (0.46 - 0.30 * wave)
        let y = ridge + depth * (height * 0.95 - ridge) * 0.7
        return .init(x: 2 + x * max(0, width - 4), y: y, radius: layer == 0 ? 0.95 : 0.75,
                     opacity: layer == 0 ? 0.95 : max(0.12, 0.62 * pow(1 - depth, 1.3)))
      }
    }
  }
  var body: some View {
    HStack(spacing: 12) {
      Text(stage.isEmpty ? "Writing…" : stage).font(.coveMetadata).foregroundStyle(Palette.body)
        .lineLimit(1).fixedSize()
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
        let time = reduceMotion ? 0.8 : timeline.date.timeIntervalSinceReferenceDate
        Canvas { context, size in
          for layer in Self.dots(width: size.width, height: size.height, time: time) {
            var path = Path()
            for dot in layer {
              path.addEllipse(in: CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2))
            }
            context.opacity = layer.first?.opacity ?? 1
            context.fill(path, with: .linearGradient(Gradient(colors: Self.colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
          }
        }
      }.frame(height: 26).accessibilityHidden(true)
    }
    .padding(.horizontal, 4).frame(height: 30)
    .accessibilityElement(children: .combine).accessibilityLabel(stage.isEmpty ? "Writing" : stage)
  }
}
