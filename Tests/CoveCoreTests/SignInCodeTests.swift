import XCTest
@testable import CoveCore

final class SignInCodeTests: XCTestCase {
  private func code(_ subject: String, _ body: String = "") -> String? { SignInCode.find(subject: subject, body: body)?.code }

  func testFindsCommonSignInCodes() {
    XCTAssertEqual(code("Google verification code", "Your verification code is\n\n482913\n\nDon't share it."), "482913")
    XCTAssertEqual(code("482913 is your Instagram code", "Someone tried to log in."), "482913")
    XCTAssertEqual(code("Slack confirmation code: 482-913", ""), "482913", "Slack's subject is a sign-in code despite the word")
    XCTAssertEqual(code("Your Slack code", "Your login code is 482 913"), "482913")
    XCTAssertEqual(code("Sign in to Linear", "Enter this code to sign in: K7Q-2PM"), "K7Q-2PM")
    XCTAssertEqual(code("Verify your email", "Use the code below to verify your email.\nABC123\nIt expires in 10 minutes."), "ABC123")
    XCTAssertEqual(code("Microsoft account security code", "Security code: 7051\nIf you didn't request this code…"), "7051")
    XCTAssertEqual(code("Tu código de verificación", "Tu código es 905114. Vence en 10 minutos."), "905114")
    XCTAssertEqual(code("Código de acceso", "Ingresa el siguiente código de acceso: 3381 2290"), "33812290")
    XCTAssertEqual(code("Your one-time password", "Password: 661029 (valid 5 minutes)"), "661029")
    XCTAssertEqual(code("Your Webex verification code", "Your verification code is 482913.\n\nCisco Webex · webex.com · Privacy"), "482913",
                   "a service's own domain in the footer isn't a meeting invitation")
    XCTAssertEqual(code("Confirm it's you", "Your verification code for the card ending in 4821 is 905114."), "905114")
    XCTAssertEqual(code("Bank security code", "Security code: 3 attempts left. Your code is 77 1203… use 771203"), "771203")
  }

  func testIgnoresMailThatOnlyLooksLikeIt() {
    XCTAssertNil(code("Your order #482913 has shipped", "Tracking number 1Z999AA10123456784"))
    XCTAssertNil(code("Receipt from Acme", "Total $1,234.00 · Order 482913 · Paid with Visa 4242"))
    XCTAssertNil(code("Your flight confirmation code", "Confirmation code: HM7Q2X. Seat 14C. Departs 10:45."))
    XCTAssertNil(code("Save 20% today", "Use promo code SAVE2026 at checkout. Your verification… just kidding."), "coupon")
    XCTAssertNil(code("Team sync", "Join Zoom Meeting https://zoom.us/j/8123456789\nMeeting ID: 812 345 6789\nPasscode: 482913"))
    XCTAssertNil(code("Quarterly plan", "We grew 2026 revenue by 18% and ship 4 releases. Code freeze is Friday."))
    XCTAssertNil(code("Call me", "My number is (555) 123-4567, any time after 2:30."))
    XCTAssertNil(code("Code review for PR 4821", "Can you look at the diff?"), "the plain word “code” needs six digits")
    XCTAssertNil(code("Re: your code", "Sure, the build number is 48213901 — let me know."), "a reply is a conversation")
  }

  func testNotifiesOnlyFreshIncomingMail() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var mail = Mail(id: "m1", threadID: "t1", sender: "Google", senderEmail: "no-reply@accounts.google.com",
                    subject: "Google verification code", body: "Your verification code is 482913", labels: ["INBOX", "UNREAD"])
    mail.date = now.addingTimeInterval(-60)
    let found = SignInCode.detect(in: mail, now: now)
    XCTAssertEqual(found?.code, "482913")
    XCTAssertEqual(found?.sender, "Google")
    mail.date = now.addingTimeInterval(-SignInCode.freshness - 1)
    XCTAssertNil(SignInCode.detect(in: mail, now: now), "an old code has expired")
    mail.date = now
    mail.labels = ["SPAM"]
    XCTAssertNil(SignInCode.detect(in: mail, now: now))
  }

  func testCodeAlertNotifiesUnderImportantButHidesTheCodeWithoutPreviews() throws {
    let now = Date()
    let mail = Mail(id: "m1", threadID: "t1", sender: "Linear", senderEmail: "no-reply@linear.example", subject: "Your Linear sign-in code",
                    body: "Enter this code to sign in: 482913. Private footer.", date: now, labels: ["INBOX", "UNREAD"], isBulkOrAutomated: true)
    XCTAssertNil(NewMailAlert.make(for: mail, accountEmail: "me@example.com", scope: .important, showPreview: true),
                 "an automated sender is Other, so the usual alert stays quiet")
    let alert = try XCTUnwrap(NewMailAlert.signInCode(for: mail, accountEmail: "me@example.com", showPreview: true, now: now))
    XCTAssertEqual(alert.title, "482913")
    XCTAssertEqual(alert.code, "482913")
    XCTAssertEqual(alert.body, "Sign-in code from Linear")
    XCTAssertFalse((alert.title + alert.body).contains("Private"))
    let hidden = try XCTUnwrap(NewMailAlert.signInCode(for: mail, accountEmail: "me@example.com", showPreview: false, now: now))
    XCTAssertNil(hidden.code)
    XCTAssertFalse((hidden.title + hidden.body).contains("482913"))
    XCTAssertNil(NewMailAlert.signInCode(for: mail, accountEmail: "me@example.com", showPreview: true, muted: ["no-reply@linear.example"], now: now))
    var read = mail
    read.labels = ["INBOX"]
    XCTAssertNil(NewMailAlert.signInCode(for: read, accountEmail: "me@example.com", showPreview: true, now: now), "already read elsewhere")
  }
}
