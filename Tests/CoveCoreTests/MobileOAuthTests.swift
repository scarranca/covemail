import Foundation
import XCTest

@testable import CoveCore

final class MobileOAuthTests: XCTestCase {
  private final class Transport: HTTPTransport {
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      requests.append(request)
      let body = #"{"access_token":"access","refresh_token":"refresh","expires_in":3599,"scope":"https://www.googleapis.com/auth/gmail.modify openid"}"#
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }

  func testRedirectSchemeIsTheReversedClientID() {
    XCTAssertEqual(OAuthSupport.iOSRedirectScheme(clientID: "123-abc.apps.googleusercontent.com"),
                   "com.googleusercontent.apps.123-abc")
    XCTAssertNil(OAuthSupport.iOSRedirectScheme(clientID: "evil.example.com"))
    XCTAssertNil(OAuthSupport.iOSRedirectScheme(clientID: ".apps.googleusercontent.com"))
  }

  func testCallbackRequiresTheSchemeAndASingleMatchingState() {
    let scheme = "com.googleusercontent.apps.123-abc"
    func parse(_ text: String) -> OAuthResponse? {
      OAuthSupport.response(callbackURL: URL(string: text)!, expectedScheme: scheme, expectedState: "s1")
    }
    XCTAssertEqual(parse("\(scheme):/oauth2redirect?state=s1&code=c1"), .code("c1"))
    XCTAssertEqual(parse("\(scheme):/oauth2redirect?state=s1&error=access_denied"), .denied)
    XCTAssertNil(parse("\(scheme):/oauth2redirect?state=other&code=c1"))
    XCTAssertNil(parse("\(scheme):/oauth2redirect?state=s1&state=s1&code=c1"))
    XCTAssertNil(parse("\(scheme):/oauth2redirect?state=s1&code=c1&code=c2"))
    XCTAssertNil(parse("other.scheme:/oauth2redirect?state=s1&code=c1"))
    XCTAssertNil(parse("\(scheme):/oauth2redirect?state=s1"))
  }

  func testCodeExchangeSendsPKCEWithoutASecretForInstalledApps() async throws {
    let transport = Transport()
    let tokens = try await GoogleTokenClient(transport: transport).exchange(
      code: "c1", verifier: "v1", clientID: "123-abc.apps.googleusercontent.com",
      redirect: "com.googleusercontent.apps.123-abc:/oauth2redirect")
    XCTAssertEqual(tokens.refresh_token, "refresh")
    XCTAssertTrue(tokens.grantedScopes.contains(OAuthSupport.gmailScope))
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
    let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(form.contains("code_verifier=v1"))
    XCTAssertTrue(form.contains("grant_type=authorization_code"))
    XCTAssertFalse(form.contains("client_secret"))
  }
}
