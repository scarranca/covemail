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
  private var imagesAllowed: Bool { automaticImages || loadImages }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { sourceHeading; Spacer(minLength: 12); readingModes }
        VStack(alignment: .leading, spacing: 12) { sourceHeading; readingModes }
      }
      if let html = mail.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if !showPlainText && !renderingFailed && !imagesAllowed {
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
      .task(id: "\(mail.id):\(showPlainText):\(mail.htmlBody?.hashValue ?? 0)") {
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
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.userContentController.add(
      context.coordinator, contentWorld: .defaultClient, name: "emailHeight")
    let view = EmailWebView(frame: .zero, configuration: configuration)
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
    view.stopLoading()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(
      forName: "emailHeight", contentWorld: .defaultClient)
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

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
        guard let webView else { return }
        do {
          _ = try await webView.callAsyncJavaScript(
            FormattedEmailView.renderScript,
            arguments: ["html": html, "generation": generation, "inlineImages": inlineImages],
            in: nil, contentWorld: .defaultClient)
        } catch {
          guard let self, self.generation == generation else { return }
          self.parent.failed = true
        }
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
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
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.failed = true }
  }
}

/// The document expands to its content height inside the native reader scroll view.
/// Route its wheel gestures to that reader instead of trapping them in WebKit.
final class EmailWebView: WKWebView {
  var innerScrollOffset: Double = 0
  var innerScrollRange: Double = 0

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
