import AppKit
import CoveCore
import SwiftUI
import WebKit

struct EmailBodyView: View {
  let store: AppStore
  let mail: Mail
  @State private var inlineImages: [String: String] = [:]
  @State private var height: CGFloat = 80
  @AppStorage("reading.textOnly") private var textOnly = false
  @AppStorage("reading.externalImages") private var automaticImages = false
  @State private var plainTextOverride: Bool?
  @State private var loadImages = false
  @State private var renderingFailed = false
  private var showPlainText: Bool { plainTextOverride ?? textOnly }
  /// Spam never loads remote images: they can confirm to a sender that the address is read.
  private var isSpam: Bool { mail.labels.contains("SPAM") }
  private var imagesAllowed: Bool { !isSpam && (automaticImages || loadImages) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { sourceHeading; Spacer(minLength: 12); readingModes }
        VStack(alignment: .leading, spacing: 12) { sourceHeading; readingModes }
      }
      if let html = mail.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if isSpam {
          Label("In Spam · images stay off and links may be unsafe", systemImage: "xmark.octagon")
            .font(.coveSecondary).foregroundStyle(Palette.body)
        } else if !showPlainText && !renderingFailed && !imagesAllowed {
          Button("Load external images") { loadImages = true }
            .help(
              "HTTPS images load directly from the sender’s servers for this message; they may reveal that you opened it."
            )
            .buttonStyle(SecondaryButton(compact: true))
        }
        if showPlainText || renderingFailed {
          if renderingFailed && !showPlainText {
            Text("Formatting couldn’t load. Showing plain text.")
              .font(.coveMetadata).foregroundStyle(Palette.muted)
          }
          plainText
        } else {
          FormattedEmailView(
            html: html, loadImages: imagesAllowed, inlineImages: inlineImages, height: $height,
            failed: $renderingFailed
          ).frame(height: height)
        }
      } else {
        plainText
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      // utf8.count is O(1) for native strings; hashing the whole HTML re-ran on every render.
      .task(id: "\(mail.id):\(showPlainText):\(mail.htmlBody?.utf8.count ?? 0)") {
        guard !showPlainText else { inlineImages = [:]; return }
        let images = await store.inlineEmailImages(for: mail)
        guard !Task.isCancelled else { return }
        inlineImages = images
      }
      .onChange(of: mail.id) { _, _ in
        plainTextOverride = nil
        loadImages = false
        inlineImages = [:]
      }
      .onChange(of: textOnly) { _, _ in plainTextOverride = nil }
      .onChange(of: mail.htmlBody) { _, _ in
        renderingFailed = false
        height = 80
      }
  }

  private var sourceHeading: some View {
    Label("Original email", systemImage: "envelope").font(.coveSubheading).fixedSize()
  }
  @ViewBuilder private var readingModes: some View {
    if let html = mail.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      HStack(spacing: 3) {
        readingMode("Formatted", plain: false)
        readingMode("Text only", plain: true)
      }.padding(3).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Email reading format")
    } else {
      Text("Text only").font(.coveSecondary).foregroundStyle(Palette.muted)
        .help("This email has no formatted version")
    }
  }
  private func readingMode(_ title: String, plain: Bool) -> some View {
    let selected = plain == (showPlainText || renderingFailed)
    return Button {
      renderingFailed = false
      plainTextOverride = plain
    } label: {
      Text(title).font(.coveControl).foregroundStyle(selected ? Palette.ink : Palette.body)
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Palette.canvas : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityLabel("\(title) email")
  }

  private var plainText: some View {
    Text(mail.body).font(.coveBody).foregroundStyle(Palette.body).lineSpacing(CoveTypography.bodyLineSpacing)
      .textSelection(.enabled).frame(maxWidth: 660, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A separate, ephemeral document contains only the selected message. Email scripts,
/// forms, frames, remote styles, and automatic navigation are never enabled.
struct FormattedEmailView: NSViewRepresentable {
  let html: String
  let loadImages: Bool
  var inlineImages: [String: String] = [:]
  @Binding var height: CGFloat
  @Binding var failed: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> WKWebView {
    let view = EmailWebViewPool.shared.take()
    EmailWebViewPool.shared.attach(context.coordinator, to: view)
    view.navigationDelegate = context.coordinator
    view.setAccessibilityLabel("Formatted email")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard
      coordinator.html != html || coordinator.loadImages != loadImages
        || coordinator.inlineImages != inlineImages
    else { return }
    coordinator.html = html
    coordinator.loadImages = loadImages
    coordinator.inlineImages = inlineImages
    coordinator.generation = UUID().uuidString
    coordinator.navigation = view.loadHTMLString(
      Self.document(loadImages: loadImages), baseURL: nil)
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.generation = ""
    coordinator.html = nil
    if let web = view as? EmailWebView { EmailWebViewPool.shared.give(back: web, from: coordinator) }
    else { view.stopLoading(); view.navigationDelegate = nil }
  }

  static func document(loadImages: Bool) -> String {
    let imageSources = loadImages ? "data: https:" : "data:"
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="referrer" content="no-referrer">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(imageSources); font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
      :root { color-scheme: light; }
      html { margin: 0; padding: 0; overflow-y: auto; }
      body { margin: 0; padding: 0; color: #4b4b4b; background: #fff;
        font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
      #cove-email { display: flow-root; min-width: 0; }
      img, table { max-width: 100% !important; }
      img { object-fit: contain; }
      pre { white-space: pre-wrap; overflow-wrap: anywhere; }
      blockquote { margin-left: 0; padding-left: 16px; border-left: 2px solid #dedede; }
      a { color: #3568a8; }
      </style></head><body><main id="cove-email"></main></body></html>
      """
  }

  // Parse inertly, retaining email styles and layout while removing interactive content.
  // The app's script executes in its isolated content world; message scripts cannot run.
  static let renderScript = #"""
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    parsed.querySelectorAll('script,iframe,frame,frameset,object,embed,applet,base,meta,link,form,input,button,textarea,select,audio,video,source,track,svg,math').forEach(node => node.remove());
    for (const img of parsed.querySelectorAll('img[src]')) {
      if (/^cid:/i.test(img.getAttribute('src'))) {
        let id = img.getAttribute('src').slice(4);
        try { id = decodeURIComponent(id); } catch (_) {}
        if (inlineImages[id]) img.setAttribute('src', inlineImages[id]);
      }
    }
    for (const node of parsed.querySelectorAll('*')) {
      for (const attr of [...node.attributes]) {
        const name = attr.name.toLowerCase();
        if (name.startsWith('on') || ['srcdoc','srcset','ping','action','formaction','background'].includes(name)) {
          node.removeAttribute(attr.name);
        } else if (['src','href','xlink:href','poster'].includes(name)) {
          const value = attr.value.trim();
          const link = node.tagName === 'A' && name === 'href' && /^(https?:|mailto:|#)/i.test(value);
          const image = node.tagName === 'IMG' && name === 'src' && /^(https?:|data:image\/(png|gif|jpeg|webp);base64,)/i.test(value);
          if (!link && !image) node.removeAttribute(attr.name);
        }
      }
    }
    const content = document.getElementById('cove-email');
    content.replaceChildren();
    for (const style of [...parsed.head.querySelectorAll('style')]) content.appendChild(document.importNode(style, true));
    const body = document.importNode(parsed.body, true);
    const wrapper = document.createElement('div');
    for (const attr of [...body.attributes]) wrapper.setAttribute(attr.name, attr.value);
    while (body.firstChild) wrapper.appendChild(body.firstChild);
    content.appendChild(wrapper);
    let previous = '';
    const reportHeight = () => {
      const height = Math.ceil(Math.max(content.getBoundingClientRect().height, content.scrollHeight));
      const offset = window.scrollY;
      const overflow = Math.max(document.documentElement.scrollHeight - window.innerHeight, 0);
      const measurement = `${height}:${offset}:${overflow}`;
      if (measurement !== previous) {
        previous = measurement;
        window.webkit.messageHandlers.emailHeight.postMessage({height, offset, overflow, generation});
      }
    };
    const observer = new ResizeObserver(reportHeight);
    observer.observe(content);
    document.addEventListener('load', reportHeight, true);
    window.addEventListener('scroll', reportHeight, {passive: true});
    window.addEventListener('resize', reportHeight);
    reportHeight();
    """#

  final class Coordinator: NSObject, WKNavigationDelegate, EmailHeightReceiver {
    var parent: FormattedEmailView
    var html: String?
    var loadImages = false
    var inlineImages: [String: String] = [:]
    var generation = ""
    var navigation: WKNavigation?
    init(_ parent: FormattedEmailView) { self.parent = parent }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard navigation === self.navigation else { return }
      let generation = generation
      let html = html ?? ""
      let inlineImages = inlineImages
      Task { @MainActor [weak self, weak webView] in
        // A view that went back to the pool (or moved to another email) must not render this document.
        guard let webView, let self, self.generation == generation else { return }
        do {
          _ = try await webView.callAsyncJavaScript(
            FormattedEmailView.renderScript,
            arguments: ["html": html, "generation": generation, "inlineImages": inlineImages],
            in: nil, contentWorld: .defaultClient)
        } catch {
          guard self.generation == generation else { return }
          self.parent.failed = true
        }
      }
    }

    func receiveHeight(_ message: WKScriptMessage) {
      guard let values = message.body as? [String: Any],
        values["generation"] as? String == generation,
        let height = values["height"] as? Double, height.isFinite
      else { return }
      if let web = message.webView as? EmailWebView {
        web.innerScrollOffset = max(0, values["offset"] as? Double ?? 0)
        web.innerScrollRange = max(0, values["overflow"] as? Double ?? 0)
      }
      let measuredHeight = max(40, min(CGFloat(height), 20_000))
      parent.height = measuredHeight
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated,
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
      {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      } else if url.absoluteString == "about:blank" && navigationAction.navigationType == .other {
        decisionHandler(.allow)
      } else if url.scheme == "about", url.fragment != nil,
        navigationAction.navigationType == .linkActivated
      {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      parent.failed = true
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      if (error as NSError).code != NSURLErrorCancelled { parent.failed = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      (webView as? EmailWebView)?.isPoolable = false  // a crashed view is never reused
      parent.failed = true
    }
  }
}

/// The document expands to its content height inside the native reader scroll view.
/// Route its wheel gestures to that reader instead of trapping them in WebKit.
final class EmailWebView: WKWebView {
  var innerScrollOffset: Double = 0
  var innerScrollRange: Double = 0
  /// False once the web content process has crashed: such a view is dropped, not reused.
  var isPoolable = true

  override func scrollWheel(with event: NSEvent) {
    // Very long messages retain an inner scroll range once the layout safety cap is
    // reached. Let WebKit reveal that content before forwarding at its boundaries.
    let canScrollInside = event.scrollingDeltaY < 0
      ? innerScrollOffset < innerScrollRange - 1 : innerScrollOffset > 1
    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      super.scrollWheel(with: event)
    } else if canScrollInside {
      let offset = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
      // The email is inert; only this app-owned isolated-world scroll command runs.
      Task { @MainActor [weak self] in
        _ = try? await self?.callAsyncJavaScript(
          "window.scrollBy(0, offset)", arguments: ["offset": offset],
          in: nil, contentWorld: .defaultClient)
      }
    } else if let scrollView = enclosingScrollView {
      scrollView.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}


/// Receives the height reports of the one email view it is attached to.
@MainActor protocol EmailHeightReceiver: AnyObject {
  func receiveHeight(_ message: WKScriptMessage)
}

/// Creating a `WKWebView` (and its web content process, configuration and data store) is the slow part of
/// opening an HTML email, so Cove keeps one shared configuration and a few blank views to reuse.
///
/// Privacy is unchanged by sharing: the configuration has JavaScript off for message content, a
/// non-persistent data store (nothing is written to disk and nothing survives the app), and no other
/// handler than the app's own `emailHeight` in its isolated content world. A view returns to the pool
/// only after it has stopped loading and navigated to a blank page, so one message's document, cookies
/// and scroll state never reach the next. The coordinator is detached first, so a late height report
/// from an old document is dropped (and its generation would not match anyway).
@MainActor final class EmailWebViewPool: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  static let shared = EmailWebViewPool()
  static let capacity = 3

  /// How many views were created (for measuring reuse).
  private(set) var created = 0
  /// Blank and ready to hand out.
  private var idle: [EmailWebView] = []
  /// Returned, but still showing the last email until its blank page commits: never handed out, so a
  /// message can't flash the previous one's content or race a script against its replacement.
  private var parking: [EmailWebView] = []
  private var receivers: [ObjectIdentifier: WeakReceiver] = [:]
  private struct WeakReceiver { weak var value: EmailHeightReceiver? }

  private lazy var configuration: WKWebViewConfiguration = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.userContentController.add(self, contentWorld: .defaultClient, name: "emailHeight")
    return configuration
  }()

  var idleCount: Int { idle.count }

  func take() -> EmailWebView {
    if let view = idle.popLast() { return view }
    created += 1
    return EmailWebView(frame: .zero, configuration: configuration)
  }

  /// Creates blank views ahead of the first email (up to the pool's capacity).
  func warm(_ count: Int = 1) {
    while idle.count < min(count, Self.capacity) {
      created += 1
      idle.append(EmailWebView(frame: .zero, configuration: configuration))
    }
  }

  func attach(_ receiver: EmailHeightReceiver, to view: EmailWebView) {
    receivers[ObjectIdentifier(view)] = WeakReceiver(value: receiver)
  }

  /// Detaches the email and keeps the blank view for the next one (or lets it go if the pool is full).
  func give(back view: EmailWebView, from coordinator: AnyObject) {
    receivers[ObjectIdentifier(view)] = nil
    view.stopLoading()
    view.navigationDelegate = nil
    view.innerScrollOffset = 0
    view.innerScrollRange = 0
    guard view.isPoolable, idle.count + parking.count < Self.capacity,
      !idle.contains(where: { $0 === view }), !parking.contains(where: { $0 === view })
    else { return }
    view.navigationDelegate = self
    view.load(URLRequest(url: URL(string: "about:blank")!))
    parking.append(view)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let index = parking.firstIndex(where: { $0 === webView }) else { return }
    let view = parking.remove(at: index)
    view.navigationDelegate = nil
    idle.append(view)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { drop(webView) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { drop(webView) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { drop(webView) }
  private func drop(_ webView: WKWebView) {
    parking.removeAll { $0 === webView }
    webView.navigationDelegate = nil
  }

  nonisolated func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    MainActor.assumeIsolated {
      guard let view = message.webView, let receiver = receivers[ObjectIdentifier(view)]?.value else { return }
      receiver.receiveHeight(message)
    }
  }
}
