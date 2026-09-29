import XCTest

@testable import CoveCore

final class CloudVoiceSyncTests: XCTestCase {
  private let profile = VoiceProfile(summary: "Warm.", greetings: ["Hi {name},"], learnedAt: Date(timeIntervalSince1970: 1_000),
    sampleCount: 9, model: "m")
  private func remote(_ revision: String, _ profile: VoiceProfile?, _ updated: Double?) -> CloudVoice {
    let json: [String: Any?] = ["revision": revision,
      "profile": profile.map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudVoiceProfile($0))) },
      "updatedAt": updated.map { CloudVoiceSync.iso(Date(timeIntervalSince1970: $0)) }]
    return try! JSONDecoder().decode(CloudVoice.self, from: JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() }))
  }

  func testNewestWinsIncludingForgotten() {
    XCTAssertEqual(CloudVoiceSync.decide(localProfile: nil, localUpdatedAt: nil, remote: remote("0", nil, nil)), .none)
    XCTAssertEqual(CloudVoiceSync.decide(localProfile: profile, localUpdatedAt: profile.learnedAt, remote: remote("0", nil, nil)), .upload)
    // A new Mac with no voice adopts the account's cloud voice.
    guard case .apply(let adopted, _) = CloudVoiceSync.decide(localProfile: nil, localUpdatedAt: nil, remote: remote("3", profile, 1_000))
    else { return XCTFail() }
    XCTAssertEqual(adopted, profile)
    // Forgotten on another Mac later: this Mac drops its copy.
    XCTAssertEqual(CloudVoiceSync.decide(localProfile: profile, localUpdatedAt: profile.learnedAt, remote: remote("4", nil, 2_000)),
      .apply(profile: nil, updatedAt: Date(timeIntervalSince1970: 2_000)))
    // Learned again here after that: upload.
    XCTAssertEqual(CloudVoiceSync.decide(localProfile: profile, localUpdatedAt: Date(timeIntervalSince1970: 3_000),
      remote: remote("4", nil, 2_000)), .upload)
    XCTAssertEqual(CloudVoiceSync.decide(localProfile: profile, localUpdatedAt: profile.learnedAt, remote: remote("5", profile, 1_000)), .none)
  }

  func testWireFormatRoundTripsAndSendsExplicitNullForForgotten() async throws {
    let wire = CloudVoiceProfile(profile)
    XCTAssertEqual(wire.learnedAt, "1970-01-01T00:16:40Z")
    XCTAssertEqual(wire.profile, profile)
    let http = CaptureHTTP()
    let client = try CloudMailClient(baseURL: URL(string: "https://cove.example.run.app")!, transport: http)
    _ = try await client.uploadVoice(nil, updatedAt: Date(timeIntervalSince1970: 0), baseRevision: "2",
      accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, token: "t")
    let bodies = await http.bodies
    let body = try XCTUnwrap(bodies.first)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertTrue(object["profile"] is NSNull)
    XCTAssertEqual(object["baseRevision"] as? String, "2")
    XCTAssertEqual(Set(object.keys), ["accountID", "requestID", "baseRevision", "profile", "updatedAt"])
  }
}

private actor CaptureHTTP: HTTPTransport {
  var bodies: [Data] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    bodies.append(request.httpBody ?? Data())
    return (Data(#"{"revision":"3"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
