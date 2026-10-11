import Foundation

/// A sign-in or verification code found in a new email, so Cove can offer it the moment it arrives
/// (iPhone notification with Copy; Mac notification and menu bar). Deterministic, with no model call:
/// the notification extension has seconds and no AI provider. Only the code itself leaves the email,
/// never the surrounding text, and only for mail that arrived in the last few minutes.
public struct SignInCode: Equatable, Sendable {
  /// As written in the email ("482 913", "K7Q-2PM").
  public var display: String
  /// What Copy puts on the clipboard: digit groups joined ("482913"); letter codes keep their dash.
  public var code: String
  public var mailID: String
  public var threadID: String
  /// The sender's name ("Google"), or its address when it has none.
  public var sender: String
  public var date: Date

  /// Codes older than this are almost always expired: never announced, and taken down after it.
  public static let freshness: TimeInterval = 10 * 60

  public static func detect(in mail: Mail, now: Date = Date()) -> SignInCode? {
    guard mail.labels.isDisjoint(with: ["SENT", "DRAFT", "SPAM", "TRASH"]) else { return nil }
    let age = now.timeIntervalSince(mail.date)
    guard age < freshness, age > -5 * 60 else { return nil }
    let subject = mail.subject == "(No subject)" ? "" : mail.subject
    guard let found = find(subject: subject, body: mail.body) else { return nil }
    return SignInCode(display: found.display, code: found.code, mailID: mail.id, threadID: mail.threadID,
                      sender: mail.sender.isEmpty ? mail.senderEmail : mail.sender, date: mail.date)
  }

  /// The code in an email's subject or text, or nil when the email isn't a sign-in code.
  public static func find(subject: String, body: String) -> (display: String, code: String)? {
    let subject = subject.folding(options: .diacriticInsensitive, locale: nil)
    let body = String(body.prefix(4_000)).folding(options: .diacriticInsensitive, locale: nil)
    let all = subject + "\n" + body
    let text = all as NSString
    // A booking, coupon or parcel email that also says "code" is never a sign-in code.
    if excluded.contains(where: { text.range(of: $0, options: .caseInsensitive).location != NSNotFound }),
      !strong.contains(where: { text.range(of: $0, options: .caseInsensitive).location != NSNotFound })
    { return nil }
    // A meeting invitation's passcode is not a sign-in.
    if meeting.contains(where: { text.range(of: $0, options: .caseInsensitive).location != NSNotFound }) { return nil }
    var anchors: [NSRange] = []
    for phrase in strong { anchors += ranges(of: phrase, in: text) }
    // "Your Slack code", "123456 is your Instagram code": the plain word counts only in a subject
    // that isn't a reply, and only for a code of six or more digits ("Code review for PR 4821" isn't one).
    var subjectAnchors: [NSRange] = []
    let lowered = subject.lowercased()
    if !lowered.hasPrefix("re:"), !lowered.hasPrefix("fwd:"), !lowered.hasPrefix("fw:") {
      for word in weak { subjectAnchors += ranges(of: word, in: subject as NSString) }
    }
    let candidates = tokens(in: all)
    guard !candidates.isEmpty else { return nil }
    // The nearest code after a sign-in phrase wins; a code just before it ("123456 is your code") next.
    func nearest(_ anchors: [NSRange], digitsOnly: Bool) -> Token? {
      var best: (Token, Int)?
      for anchor in anchors {
        for token in candidates where !digitsOnly || (token.digitsOnly && token.code.count >= 6) {
          let distance: Int
          if token.range.location >= NSMaxRange(anchor) { distance = token.range.location - NSMaxRange(anchor) }
          else if NSMaxRange(token.range) <= anchor.location { distance = (anchor.location - NSMaxRange(token.range)) * 2 + 10 }
          else { continue }
          guard distance <= 160, !isAccountFragment(token, in: text) else { continue }
          // Most codes have six or more digits: a shorter number nearby ("4 attempts") yields to one.
          let score = distance + (token.code.count < 6 ? 40 : 0)
          if best == nil || score < best!.1 { best = (token, score) }
        }
      }
      return best?.0
    }
    guard let token = nearest(anchors, digitsOnly: false) ?? nearest(subjectAnchors, digitsOnly: true) else { return nil }
    return (token.display, token.code)
  }

  // MARK: Matching

  /// Phrases that mean "here is a code to sign in or verify" (English and Spanish, accents folded).
  static let strong = [
    "verification code", "verify code", "verification number", "security code", "sign-in code", "sign in code", "signin code",
    "login code", "log-in code", "log in code", "one-time code", "one time code", "one-time passcode", "one-time password",
    "one time password", "passcode", "otp", "2fa", "two-factor", "two factor", "2-step", "two-step", "authentication code",
    "auth code", "confirm your email", "confirm your account", "verify your email", "verify your account", "verify your identity",
    "verify it's you", "verify it’s you", "magic code", "temporary code", "access code", "your code is", "code is:",
    "enter this code", "enter the code", "use this code", "use the code", "following code", "codigo de verificacion",
    "codigo de seguridad", "codigo de acceso", "codigo de inicio de sesion", "codigo para iniciar",
    "codigo de un solo uso", "tu codigo", "su codigo", "clave de acceso", "clave dinamica", "token de acceso",
  ]
  static let weak = ["code", "codigo", "pin"]
  /// Coupons, bookings, parcels and postcodes are never sign-ins. ("Confirmation code" is neither:
  /// Slack's sign-in says it, and so does an airline booking, whose code has letters and so needs a
  /// strong phrase.)
  static let excluded = [
    "booking code", "reservation code", "promo code", "promotional code", "discount code",
    "coupon", "gift card", "zip code", "postal code", "postcode", "tracking number", "tracking code",
    "referral code", "voucher", "codigo de reserva", "codigo promocional", "codigo de descuento", "codigo postal", "cupon",
  ]

  static let meeting = [
    // Invitation phrases, never bare domains: Webex's or Google's own sign-in email names its domain.
    "meeting id", "meeting passcode", "zoom.us/j", "join zoom meeting", "join the meeting", "dial-in", "dial in",
    "conference id", "id de reunion", "unirse a la reunion",
  ]

  struct Token {
    var range: NSRange
    var display: String
    var code: String
    var digitsOnly: Bool
  }

  /// Code-shaped tokens: 4–8 digits, digit groups ("482 913", "482-913"), or 6–8 capital letters and
  /// digits with at least two digits ("K7Q2PM", "K7Q-2PM"). Amounts, dates, times, phone numbers and
  /// years are left out by their neighbors and shape.
  static func tokens(in text: String) -> [Token] {
    let pattern = #"(?<![\p{L}\p{N}$€£¥#+\-/.,:@_])(\d{3,4}[ \-]\d{3,4}|\d{4,8}|[A-Z0-9]{3,4}-[A-Z0-9]{3,4}|[A-Z0-9]{6,8})(?![\p{L}\p{N}\-/%@_]|[.,:]\d)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
      let display = ns.substring(with: match.range)
      let compact = display.filter { $0 != " " && $0 != "-" }
      let digits = compact.filter(\.isASCIIDigit).count
      let digitsOnly = digits == compact.count
      if digitsOnly {
        guard (4...8).contains(compact.count) else { return nil }
        // A year ("2026") or a run of one digit ("0000") isn't a code.
        if compact.count == 4, let year = Int(compact), (1900...2100).contains(year) { return nil }
        if Set(compact).count == 1 { return nil }
        return Token(range: match.range, display: display, code: compact, digitsOnly: true)
      }
      // Letters and digits: needs letters and at least two digits ("ACCOUNT", "COVID19" aren't codes).
      guard digits >= 2, compact.count - digits >= 1, (6...8).contains(compact.count) else { return nil }
      return Token(range: match.range, display: display, code: display.replacingOccurrences(of: " ", with: ""), digitsOnly: false)
    }
  }

  /// "Card ending in 4821", "last 4 digits 4821": part of an account number, not a code.
  private static func isAccountFragment(_ token: Token, in text: NSString) -> Bool {
    let start = max(0, token.range.location - 24)
    let before = text.substring(with: NSRange(location: start, length: token.range.location - start)).lowercased()
    return ["ending in", "ending", "ends in", "last 4", "last four", "terminada en", "termina en", "xxxx", "****", "•••"]
      .contains { before.hasSuffix($0 + " ") || before.hasSuffix($0) || before.hasSuffix($0 + ": ") }
  }

  private static func ranges(of phrase: String, in text: NSString) -> [NSRange] {
    var found: [NSRange] = []
    var search = NSRange(location: 0, length: text.length)
    while search.length > 0 {
      let range = text.range(of: phrase, options: .caseInsensitive, range: search)
      guard range.location != NSNotFound else { break }
      // Whole words only ("otp" inside "potpourri" doesn't count).
      if isWord(range, in: text) { found.append(range) }
      search = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
    }
    return found
  }

  private static func isWord(_ range: NSRange, in text: NSString) -> Bool {
    func letter(at index: Int) -> Bool {
      guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
      return CharacterSet.alphanumerics.contains(scalar)
    }
    return !letter(at: range.location - 1) && !letter(at: NSMaxRange(range))
  }
}

private extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}
