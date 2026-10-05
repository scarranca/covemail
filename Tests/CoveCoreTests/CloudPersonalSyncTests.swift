import XCTest

@testable import CoveCore

final class CloudPersonalSyncTests: XCTestCase {
  private func context(_ role: String, at seconds: Double?) -> PersonalContext {
    var value = PersonalContext()
    value.name = "Ana"; value.role = role; value.signature = "Best,\nAna"
    var project = PersonalContext.Project(name: "Launch", detail: "Q4")
    project.id = UUID(uuidString: "6F1D2C4E-8B1A-4C2E-9F3D-1A2B3C4D5E6F")!
    value.projects = [project]
    value.notes = ["In Mexico City"]
    value.updatedAt = seconds.map { Date(timeIntervalSince1970: $0) }
    return value
  }
  private func remote(_ revision: String, _ value: PersonalContext?, _ seconds: Double?) -> CloudPersonal {
    let json: [String: Any] = ["revision": revision,
      "personal": value.map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudPersonalContext($0))) } ?? NSNull(),
      "updatedAt": seconds.map { CloudVoiceSync.iso(Date(timeIntervalSince1970: $0)) } ?? NSNull()]
    return try! JSONDecoder().decode(CloudPersonal.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func testNewestEditWinsAndANewDeviceAdoptsTheServerCopy() {
    XCTAssertEqual(CloudPersonalSync.decide(local: nil, remote: remote("0", nil, nil)), .none)
    XCTAssertEqual(CloudPersonalSync.decide(local: context("Founder", at: 1_000), remote: remote("0", nil, nil)), .upload)
    // Never edited here (no date): take the server copy, with the server's date.
    XCTAssertEqual(CloudPersonalSync.decide(local: PersonalContext(), remote: remote("2", context("CEO", at: 1_000), 1_000)),
      .apply(context("CEO", at: 1_000)))
    XCTAssertEqual(CloudPersonalSync.decide(local: context("Founder", at: 1_000), remote: remote("2", context("CEO", at: 2_000), 2_000)),
      .apply(context("CEO", at: 2_000)))
    XCTAssertEqual(CloudPersonalSync.decide(local: context("Founder", at: 3_000), remote: remote("2", context("CEO", at: 2_000), 2_000)), .upload)
    // Sub-second local dates match the server's second precision: no ping-pong.
    XCTAssertEqual(CloudPersonalSync.decide(local: context("CEO", at: 2_000.7), remote: remote("2", context("CEO", at: 2_000), 2_000)), .none)
  }

  func testWireFormatIsBoundedLowercaseAndRoundTrips() throws {
    var long = context("Founder", at: 1_000)
    long.about = String(repeating: "a", count: 900)
    long.notes = Array(repeating: "note", count: 30)
    let wire = CloudPersonalContext(long)
    XCTAssertEqual(wire.about.count, 400)
    XCTAssertEqual(wire.notes.count, 20)
    XCTAssertEqual(wire.projects.first?.id, long.projects.first?.id.uuidString.lowercased())
    let back = wire.context(updatedAt: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(back.projects.first?.id, long.projects.first?.id)
    XCTAssertEqual(back.signature, "Best,\nAna")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["name", "role", "company", "about", "projects", "notes", "signature", "enabled"])
  }

  func testSyncUploadsAppliesAndRetriesOnceAfterARace() async throws {
    let server = FakePersonalServer()
    let client = try CloudMailClient(baseURL: URL(string: "https://cove.example.run.app")!, transport: server)
    // First device uploads.
    var outcome = try await CloudPersonalSync.sync(local: context("Founder", at: 1_000), state: PersonalSyncState(),
      client: client, token: { "t" })
    XCTAssertNil(outcome.apply)
    XCTAssertEqual(outcome.state.revision, "1")
    // A second device that never edited adopts it.
    outcome = try await CloudPersonalSync.sync(local: nil, state: PersonalSyncState(), client: client, token: { "t" })
    XCTAssertEqual(outcome.apply?.role, "Founder")
    XCTAssertEqual(outcome.state.revision, "1")
    // Another device writes between our read and write: re-decided against the newer copy.
    await server.raceNextWrite(role: "CEO", at: 5_000)
    outcome = try await CloudPersonalSync.sync(local: context("Founder", at: 2_000), state: outcome.state, client: client, token: { "t" })
    XCTAssertEqual(outcome.apply?.role, "CEO")
    let writes = await server.writes
    XCTAssertEqual(writes, 1, "the stale edit is not written over the newer one")
  }
}

private actor FakePersonalServer: HTTPTransport {
  var revision = 0
  var stored: [String: Any]?
  var updatedAt: String?
  var writes = 0
  var race: (String, Double)?

  func raceNextWrite(role: String, at seconds: Double) { race = (role, seconds) }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    func reply(_ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
      (try! JSONSerialization.data(withJSONObject: object),
       HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    if request.httpMethod == "PUT" {
      if let (role, seconds) = race {
        race = nil
        revision += 1
        var other = (stored ?? [:]); other["role"] = role
        stored = other; updatedAt = CloudVoiceSync.iso(Date(timeIntervalSince1970: seconds))
      }
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
      guard body["baseRevision"] as? String == String(revision) else { return reply(409, ["error": "personal_conflict"]) }
      revision += 1; writes += 1
      stored = body["personal"] as? [String: Any]; updatedAt = body["updatedAt"] as? String
      return reply(200, ["revision": String(revision)])
    }
    let personal: Any = stored ?? NSNull()
    let date: Any = updatedAt ?? NSNull()
    return reply(200, ["revision": String(revision), "personal": personal, "updatedAt": date])
  }
}
