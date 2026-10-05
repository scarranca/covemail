#if os(iOS)
import CoveCore
import SwiftUI

/// The writing voice on iPhone: the same `VoiceProfile` the Mac learns from the user's own sent mail
/// (style only, never bodies), kept in this iPhone's Keychain.
enum MobileVoice {
  private static let key = "voiceProfile.shared"

  static func load() -> VoiceProfile? {
    guard let text = try? MobileKeychain.read(key) else { return nil }
    return try? JSONDecoder.voice.decode(VoiceProfile.self, from: Data(text.utf8))
  }
  static func save(_ profile: VoiceProfile) throws {
    try MobileKeychain.save(String(decoding: try JSONEncoder.voice.encode(profile), as: UTF8.self), name: key)
  }
  static func forget() throws { try MobileKeychain.delete(key) }

  /// Learns the voice like the Mac's `learnVoice`: bounded, quote-stripped excerpts of the user's own
  /// sent mail go to the chosen model, which returns style traits only.
  @MainActor
  static func learn(mailbox: MobileMailbox, ai: MobileAI) async throws -> VoiceProfile {
    let samples = try await mailbox.sentSamples()
    guard samples.count >= 3 else {
      throw CoveError.message("Cove needs at least three emails you wrote in Sent to learn your voice.")
    }
    let prompt = try AIPrompt(intent: .learnVoice, instruction: "Describe my writing voice from these \(samples.count) emails I sent.",
                              mails: samples, limits: ai.provider.isAppleIntelligence ? .onDevice : .standard)
    let text = try await ai.complete(prompt)
    let profile = try VoiceProfile.parse(text, sampleCount: samples.count, model: ai.modelLabel(ai.model(ai.provider), provider: ai.provider))
    try save(profile)
    return profile
  }
}

private extension JSONDecoder {
  static var voice: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
private extension JSONEncoder {
  static var voice: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

/// What a writing request knows besides the user's words, as the Mac's `ComposeSuggestion.instruction`:
/// who is writing, to whom, the subject, the learned voice, and the rules that keep a draft sendable.
enum MobileWritingContext {
  static func instruction(_ request: String, from sender: (name: String, email: String), to: String, cc: String,
                          subject: String, replying: Bool, voice: VoiceProfile?, personal: String? = nil) -> String {
    var parts = ["Current user request:\n" + request,
                 "Writing voice: natural. Preserve facts, names, dates, and commitments."]
    if let voice { parts.append(voice.promptText) }
    // Who the user is and what they're working on (Settings → About you), in their own words.
    if let personal { parts.append(personal) }
    var facts = ["You are writing as \(sender.name.isEmpty ? sender.email : "\(sender.name) <\(sender.email)>")."]
    let recipients = ContactDirectory.addresses(to + (cc.isEmpty ? "" : ", " + cc))
    if !recipients.isEmpty {
      facts.append("Recipients: " + recipients.map { $0.name.isEmpty || $0.name == $0.email ? $0.email : "\($0.name) <\($0.email)>" }
        .joined(separator: ", ") + ". Greet them by first name when a name is known.")
    }
    if !subject.trimmingCharacters(in: .whitespaces).isEmpty { facts.append("Subject: \(subject).") }
    if replying { facts.append("This is a reply in the supplied conversation.") }
    facts.append("Return only the email body. Never include a Subject line. Never use placeholders such as [Name], [Recipient's Name] or [Your Name]: use the real names above, or leave the name out. Sign with the sender's first name when a sign-off fits.")
    parts.append(facts.joined(separator: "\n"))
    return parts.joined(separator: "\n\n")
  }

  /// Small models sometimes add a "Subject:" line anyway; take it out (and offer it as the subject).
  static func clean(_ text: String) -> (body: String, subject: String?) {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
    var subject: String?
    if let first = lines.first, first.lowercased().hasPrefix("subject:") {
      subject = first.dropFirst("subject:".count).trimmingCharacters(in: .whitespaces)
      lines.removeFirst()
      while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    }
    return (lines.joined(separator: "\n"), subject)
  }
}

// MARK: Motion (DESIGN.md: the Mac's WritingThinkingBar and finite returned-text reveal)

/// The Home tide's point cloud as a slow travelling wave above the real stage text. Reduce Motion
/// keeps it still.
struct MobileThinkingBar: View {
  let stage: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
        let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        Canvas { context, size in
          let columns = max(2, Int(size.width / 4))
          for layer in 0..<4 {
            var path = Path()
            let depth = Double(layer) / 3
            for column in 0..<columns {
              let x = Double(column) / Double(columns - 1)
              let wave = sin(x * .pi * 4 - time * 1.4 + depth * 1.2)
              let y = size.height / 2 + wave * (size.height * 0.32) * (1 - depth * 0.35)
              let r = layer == 0 ? 1.1 : 0.8
              path.addEllipse(in: CGRect(x: 2 + x * (size.width - 4) - r, y: y - r, width: r * 2, height: r * 2))
            }
            context.opacity = layer == 0 ? 0.9 : 0.5 - depth * 0.3
            context.fill(path, with: .linearGradient(Gradient(colors: MobilePalette.tide), startPoint: .zero,
                                                     endPoint: CGPoint(x: size.width, y: 0)))
          }
        }
      }
      .frame(height: 18).accessibilityHidden(true)
      Text(stage).font(.mobileSecondary).foregroundStyle(MobilePalette.body)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Returned text appears word by word over 1.25 seconds, once. A tap finishes it; Reduce Motion and
/// streamed text skip it.
struct MobileRevealText: View {
  let text: String
  let animate: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date()
  @State private var finished = false

  var body: some View {
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    TimelineView(.animation(paused: finished || !animate || reduceMotion)) { context in
      let progress = finished || !animate || reduceMotion ? 1 : min(1, context.date.timeIntervalSince(start) / 1.25)
      let shown = Int((Double(words.count) * progress).rounded(.up))
      let visible = words.prefix(shown).joined(separator: " ")
      let hidden = words.dropFirst(shown).joined(separator: " ")
      (Text(visible).foregroundStyle(MobilePalette.ink)
        + Text(hidden.isEmpty ? "" : " " + hidden).foregroundStyle(MobilePalette.ink.opacity(0.08)))
        .font(.mobileBody).lineSpacing(6)
        .onChange(of: progress >= 1) { _, done in if done { finished = true } }
    }
    .contentShape(Rectangle())
    .onTapGesture { finished = true }
    .onChange(of: text) { _, _ in if !animate { finished = true } }
    .textSelection(.enabled)
  }
}
#endif
