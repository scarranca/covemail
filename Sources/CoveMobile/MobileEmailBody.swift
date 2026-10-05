#if os(iOS)
import CoveCore
import SwiftUI
import WebKit

/// "Original email" with the Mac's Formatted / Text only switch (`EmailBodyView`). Formatted mail is
/// rendered exactly as on the Mac: an ephemeral web view with JavaScript off for the message, a strict
/// Content-Security-Policy, and an inert parse that removes scripts, forms, frames and remote styles.
/// Remote images load only after "Load external images" (or the saved preference), never in Spam.
struct MobileEmailBody: View {
  let mail: Mail
  var heading = true
  @AppStorage("reading.textOnly") private var textOnly = false
  @AppStorage("reading.externalImages") private var automaticImages = false
  @State private var plainTextOverride: Bool?
  @State private var loadImages = false
  @State private var failed = false
  @State private var height: CGFloat = 80

  private var html: String? {
    guard let html = mail.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return html
  }
  private var showPlainText: Bool { plainTextOverride ?? textOnly }
  private var isSpam: Bool { mail.labels.contains("SPAM") }
  private var imagesAllowed: Bool { !isSpam && (automaticImages || loadImages) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if heading {
        HStack(spacing: 10) {
          Label("Original email", systemImage: "envelope").font(.mobileSection).foregroundStyle(MobilePalette.ink)
          Spacer(minLength: 8)
          if html != nil { modes } else {
            Text("Text only").font(.mobileSecondary).foregroundStyle(MobilePalette.muted)
          }
        }
      }
      if let html {
        if isSpam {
          Label("In Spam · images stay off and links may be unsafe", systemImage: "xmark.octagon")
            .font(.mobileSecondary).foregroundStyle(MobilePalette.body)
        } else if !showPlainText && !failed && !imagesAllowed {
          Button("Load external images") { loadImages = true }.buttonStyle(MobileSecondaryButton(compact: true))
        }
        if showPlainText || failed {
          if failed && !showPlainText {
            Text("Formatting couldn’t load. Showing plain text.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
          }
          MobileMessageBody(mail: mail)
        } else {
          MobileFormattedEmail(html: html, loadImages: imagesAllowed, height: $height, failed: $failed)
            .frame(height: height)
        }
      } else {
        MobileMessageBody(mail: mail)
      }
    }
    .onChange(of: mail.id) { _, _ in
      plainTextOverride = nil
      loadImages = false
      failed = false
      height = 80
    }
  }

  private var modes: some View {
    HStack(spacing: 3) {
      mode("Formatted", plain: false)
      mode("Text only", plain: true)
    }.padding(3).background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
      .accessibilityLabel("Email reading format")
  }

  private func mode(_ title: String, plain: Bool) -> some View {
    let selected = plain == (showPlainText || failed)
    return Button {
      failed = false
      plainTextOverride = plain
    } label: {
      Text(title).font(.mobileControl).foregroundStyle(selected ? MobilePalette.ink : MobilePalette.body)
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? MobilePalette.canvas : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The Mac's `FormattedEmailView` on iPhone. The document grows to its content height inside the
/// reader's scroll view; links open in the browser only when tapped.
struct MobileFormattedEmail: UIViewRepresentable {
  let html: String
  let loadImages: Bool
  @Binding var height: CGFloat
  @Binding var failed: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.dataDetectorTypes = []
    configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "emailHeight")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isOpaque = false
    view.backgroundColor = .white
    view.scrollView.isScrollEnabled = false
    view.scrollView.bounces = false
    view.accessibilityLabel = "Formatted email"
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard coordinator.html != html || coordinator.loadImages != loadImages else { return }
    coordinator.html = html
    coordinator.loadImages = loadImages
    coordinator.generation = UUID().uuidString
    coordinator.navigation = view.loadHTMLString(Self.document(loadImages: loadImages), baseURL: nil)
  }

  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "emailHeight", contentWorld: .defaultClient)
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
      html { margin: 0; padding: 0; -webkit-text-size-adjust: 100%; }
      body { margin: 0; padding: 0; color: #4b4b4b; background: #fff;
        font: 15px/1.6 -apple-system, sans-serif; overflow-wrap: anywhere; }
      #cove-email { display: flow-root; min-width: 0; }
      img, table { max-width: 100% !important; height: auto; }
      img { object-fit: contain; }
      pre { white-space: pre-wrap; overflow-wrap: anywhere; }
      blockquote { margin-left: 0; padding-left: 16px; border-left: 2px solid #dedede; }
      a { color: #3568a8; }
      </style></head><body><main id="cove-email"></main></body></html>
      """
  }

  /// Identical to the Mac's render script: parse inertly, keep the sender's styles and layout, remove
  /// interactive content. It runs in the app's isolated content world; message scripts never run.
  /// Inline (cid:) images aren't downloaded on iPhone yet, so they stay blank.
  static let renderScript = #"""
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    parsed.querySelectorAll('script,iframe,frame,frameset,object,embed,applet,base,meta,link,form,input,button,textarea,select,audio,video,source,track,svg,math').forEach(node => node.remove());
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
    let previous = 0;
    const reportHeight = () => {
      const height = Math.ceil(Math.max(content.getBoundingClientRect().height, content.scrollHeight, document.documentElement.scrollHeight));
      if (height !== previous) {
        previous = height;
        window.webkit.messageHandlers.emailHeight.postMessage({height, generation});
      }
    };
    new ResizeObserver(reportHeight).observe(content);
    document.addEventListener('load', reportHeight, true);
    window.addEventListener('resize', reportHeight);
    reportHeight();
    """#

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var parent: MobileFormattedEmail
    var html: String?
    var loadImages = false
    var generation = ""
    var navigation: WKNavigation?
    init(_ parent: MobileFormattedEmail) { self.parent = parent }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard navigation === self.navigation else { return }
      let generation = generation
      let html = html ?? ""
      Task { @MainActor [weak self, weak webView] in
        guard let webView else { return }
        do {
          _ = try await webView.callAsyncJavaScript(MobileFormattedEmail.renderScript,
            arguments: ["html": html, "generation": generation], in: nil, contentWorld: .defaultClient)
        } catch {
          guard let self, self.generation == generation else { return }
          self.parent.failed = true
        }
      }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let values = message.body as? [String: Any], values["generation"] as? String == generation,
            let height = values["height"] as? Double, height.isFinite else { return }
      parent.height = max(40, min(CGFloat(height), 30_000))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
      guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
      if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
      } else if url.absoluteString == "about:blank" && navigationAction.navigationType == .other {
        decisionHandler(.allow)
      } else if url.scheme == "about", url.fragment != nil, navigationAction.navigationType == .linkActivated {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      if (error as NSError).code != NSURLErrorCancelled { parent.failed = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.failed = true }
  }
}
#endif
