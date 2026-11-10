@testable import ASCListingKit
import Foundation
import Testing

struct ASCClientRetryTests {
    typealias Item = Resource<EmptyAttributes>

    private let created = StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl"}}"#)
    private let body = RequestBody<EmptyAttributes>.create(type: "appAssetLibraryPlacements")

    private func client(_ transport: ScriptedTransport, sleeps: SleepRecorder, lines: LineRecorder = LineRecorder()) throws -> ASCClient {
        try ASCClient(transport: transport, signer: JWTSigner(credentials: makeCredentials()), log: lines.log, sleeper: sleeps.sleeper)
    }

    @Test(arguments: [
        URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed
    ])
    func `a transient network error is retried with backoff`(code: URLError.Code) async throws {
        let transport = ScriptedTransport([.dropped(code), .dropped(code), StubResponse(200, #"{"data":{"type":"apps","id":"1"}}"#)])
        let sleeps = SleepRecorder()
        let lines = LineRecorder()
        let document = try await client(transport, sleeps: sleeps, lines: lines).get("/v1/apps/1", as: Document<Item>.self)
        #expect(document.data.id == "1")
        #expect(transport.requests.count == 3)
        #expect(sleeps.recorded == [.seconds(1), .seconds(2)])
        #expect(lines.lines.count == 2)
        #expect(lines.lines.allSatisfy { $0.hasPrefix("warning: GET /v1/apps/1: ") })
    }

    @Test func `a dropped connection gives up after the same cap as server errors`() async throws {
        let transport = ScriptedTransport(Array(repeating: .dropped(.networkConnectionLost), count: 5))
        let sleeps = SleepRecorder()
        await #expect(throws: ASCError.self) {
            try await client(transport, sleeps: sleeps).get("/v1/apps/1", as: Document<Item>.self)
        }
        #expect(transport.requests.count == 5)
        #expect(sleeps.recorded == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func `a cancelled request is not retried`() async throws {
        let transport = ScriptedTransport([.dropped(.cancelled)])
        let sleeps = SleepRecorder()
        await #expect(throws: ASCError.self) {
            try await client(transport, sleeps: sleeps).get("/v1/apps/1", as: Document<Item>.self)
        }
        #expect(transport.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func `an upload part is retried after a dropped connection`() async throws {
        let transport = ScriptedTransport([.dropped(.networkConnectionLost), StubResponse(200, "")])
        let sleeps = SleepRecorder()
        let operation = UploadOperation(method: "PUT", url: "https://upload.example.com/part", length: 2, offset: 1)
        try await client(transport, sleeps: sleeps).upload(operation, bytes: Data([0, 1, 2]))
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.httpBody == Data([1, 2]) })
        #expect(sleeps.recorded == [.seconds(1)])
    }

    @Test func `a delete that finds nothing on a retry counts as done`() async throws {
        let transport = ScriptedTransport([.dropped(.timedOut), StubResponse(404, #"{"errors":[{"status":"404"}]}"#)])
        try await client(transport, sleeps: SleepRecorder()).delete("/v1/appAssetLibraryPlacements/p")
        #expect(transport.requests.count == 2)
    }

    @Test func `a delete that finds nothing on the first attempt still fails`() async throws {
        let transport = ScriptedTransport([StubResponse(404, #"{"errors":[{"status":"404","code":"NOT_FOUND"}]}"#)])
        do {
            try await client(transport, sleeps: SleepRecorder()).delete("/v1/appAssetLibraryPlacements/p")
            Issue.record("expected a throw")
        } catch let ASCError.api(status, _) {
            #expect(status == 404)
        }
    }

    @Test(arguments: ["/v1/appAssetLibraryPlacements", "/v1/appAssetLibraryPlacementOrderingRequests"])
    func `placement and ordering posts are not replayed after a server error or a dropped connection`(path: String) async throws {
        for failure in [StubResponse(500, #"{"errors":[{"status":"500"}]}"#), .dropped(.networkConnectionLost), .dropped(.timedOut)] {
            let transport = ScriptedTransport([failure, created])
            let sleeps = SleepRecorder()
            await #expect(throws: ASCError.self) {
                try await client(transport, sleeps: sleeps).send(.post, path, body: body)
            }
            #expect(transport.requests.count == 1)
            #expect(sleeps.recorded.isEmpty)
        }
    }

    @Test func `a placement post is retried when it was rate limited or never left the Mac`() async throws {
        for failure in [StubResponse(429), .dropped(.cannotConnectToHost), .dropped(.dnsLookupFailed)] {
            let transport = ScriptedTransport([failure, created])
            try await client(transport, sleeps: SleepRecorder()).send(.post, "/v1/appAssetLibraryPlacements", body: body)
            #expect(transport.requests.count == 2)
        }
    }

    @Test func `other posts are still retried after a server error`() async throws {
        let transport = ScriptedTransport([StubResponse(503), created])
        try await client(transport, sleeps: SleepRecorder()).send(.post, "/v1/appAssetLibraryImages", body: body)
        #expect(transport.requests.count == 2)
    }

    @Test func `a long retry after is capped at a minute and logged`() async throws {
        let transport = ScriptedTransport([
            StubResponse(429, "{}", headers: ["Retry-After": "3600"]),
            StubResponse(200, #"{"data":{"type":"apps","id":"1"}}"#)
        ])
        let sleeps = SleepRecorder()
        let lines = LineRecorder()
        _ = try await client(transport, sleeps: sleeps, lines: lines).get("/v1/apps/1", as: Document<Item>.self)
        #expect(sleeps.recorded == [.seconds(60)])
        #expect(lines.lines == ["warning: rate limited, waiting 60s"])
    }

    @Test func `a failed upload keeps a summary of the response body`() async throws {
        let xml = "<Error><Code>AccessDenied</Code>" + String(repeating: "x", count: 400) + "</Error>"
        let operation = UploadOperation(method: "PUT", url: "https://upload.example.com/part", length: 1, offset: 0)
        do {
            try await client(ScriptedTransport([StubResponse(403, xml)]), sleeps: SleepRecorder()).upload(operation, bytes: Data([1]))
            Issue.record("expected a throw")
        } catch let ASCError.uploadFailed(status, response) {
            #expect(status == 403)
            #expect(response == String(xml.prefix(300)))
        }
        let json = #"{"errors":[{"status":"400","code":"BAD","detail":"wrong length"}]}"#
        do {
            try await client(ScriptedTransport([StubResponse(400, json)]), sleeps: SleepRecorder()).upload(operation, bytes: Data([1]))
            Issue.record("expected a throw")
        } catch let error as ASCError {
            #expect(error.description == "Asset upload failed with HTTP status 400: 400 BAD: wrong length")
        }
    }

    @Test func `unauthorized suggests the key, the issuer and the clock`() async throws {
        let body = #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","detail":"Authentication credentials are missing or invalid."}]}"#
        do {
            _ = try await client(ScriptedTransport([StubResponse(401, body)]), sleeps: SleepRecorder()).get("/v1/apps", as: Document<Item>.self)
            Issue.record("expected a throw")
        } catch let error as ASCError {
            #expect(error.description.contains("check the key id, issuer id and that the key isn't revoked; also check the Mac's clock"))
        }
    }
}
