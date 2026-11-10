@testable import ASCListingKit
import Foundation
import Testing

struct AssetUploaderTests {
    private let spec = "bd402f1a-26ee-5b83-9dd7-972c60c43d47"
    private let bytes = Data("0123456789".utf8)

    private func file() throws -> ScreenshotFile {
        let url = try makeTempDirectory().appending(path: "panel-03.png")
        try bytes.write(to: url)
        return ScreenshotFile(
            url: url,
            fileName: "panel-03.png",
            width: 1320,
            height: 2868,
            hasAlpha: false,
            byteCount: bytes.count,
            fingerprint: ScreenshotFile.fingerprint(of: bytes)
        )
    }

    private let operations = """
    [{"method":"PUT","url":"https://upload.example/part-1","length":6,"offset":0,\
    "requestHeaders":[{"name":"Content-Type","value":"image/png"}]},\
    {"method":"PUT","url":"https://upload.example/part-2","length":4,"offset":6,\
    "requestHeaders":[{"name":"Content-Type","value":"image/png"},{"name":"x-part","value":"2"}]}]
    """

    private func uploader(
        _ transport: ScriptedTransport,
        sleeps: SleepRecorder = SleepRecorder(),
        lines: LineRecorder = LineRecorder()
    ) throws -> AssetUploader {
        try AssetUploader(client: makeClient(transport), log: lines.log, sleeper: sleeps.sleeper)
    }

    @Test func `a new image is reserved, uploaded in parts, committed and polled until ready`() async throws {
        let file = try file()
        let transport = ScriptedTransport([
            StubResponse(201, imageResource(id: "img", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img", state: "PREPARE_FOR_SUBMISSION", specID: spec))
        ])
        let sleeps = SleepRecorder()
        let lines = LineRecorder()
        let id = try await uploader(transport, sleeps: sleeps, lines: lines)
            .ensureReady(file, libraryID: "lib", existing: nil, expectedSpecID: spec)
        #expect(id == "img")

        let requests = transport.requests
        #expect(requestLine(requests[0]) == "POST /v1/appAssetLibraryImages")
        let reserve = try requestData(requests[0])
        let attributes = try #require(reserve["attributes"] as? [String: Any])
        #expect(attributes["fileName"] as? String == "panel-03.png")
        #expect(attributes["fileSize"] as? Int == 10)
        #expect(attributes["category"] as? String == "APP_SCREENSHOTS_AND_PREVIEWS")
        #expect(attributes["referenceName"] as? String == file.fingerprint)
        let relationships = try #require(reserve["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["assetLibrary"]?["data"] == ["type": "appAssetLibraries", "id": "lib"])

        let parts = requests[1 ... 2].sorted { ($0.url?.absoluteString ?? "") < ($1.url?.absoluteString ?? "") }
        #expect(parts.map { $0.url?.absoluteString } == ["https://upload.example/part-1", "https://upload.example/part-2"])
        #expect(parts.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(parts.map(\.httpBody) == [Data("012345".utf8), Data("6789".utf8)])
        #expect(parts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(parts[0].value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(parts[1].value(forHTTPHeaderField: "x-part") == "2")

        #expect(requestLine(requests[3]) == "PATCH /v1/appAssetLibraryImages/img")
        let commit = try requestData(requests[3])
        #expect(commit["id"] as? String == "img")
        #expect(try #require(commit["attributes"] as? [String: Bool]) == ["uploaded": true])
        #expect(commit["relationships"] == nil)

        #expect(requests[4...].map(requestLine) == Array(repeating: "GET /v1/appAssetLibraryImages/img", count: 2))
        #expect(sleeps.recorded == [.seconds(2)])
        #expect(lines.lines == ["uploaded panel-03.png"])
    }

    @Test func `a failed image is deleted and reported with its details`() async throws {
        let file = try file()
        let failed = #"{"data":{"type":"appAssetLibraryImages","id":"img","attributes":{"state":"FAILED","#
            + #""stateDetails":{"errors":[{"code":"IMAGE_INCORRECT_DIMENSIONS","message":"bad size"}]}}}}"#
        let transport = ScriptedTransport([
            StubResponse(201, imageResource(id: "img", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img", state: "UPLOAD_COMPLETE")),
            StubResponse(200, failed),
            StubResponse(204, "")
        ])
        do {
            _ = try await uploader(transport).ensureReady(file, libraryID: "lib", existing: nil, expectedSpecID: spec)
            Issue.record("expected an error")
        } catch let ASCError.assetFailed(name, details) {
            #expect(name == "panel-03.png")
            #expect(details?.contains("bad size") == true)
        }
        #expect(transport.requests.last.map(requestLine) == "DELETE /v1/appAssetLibraryImages/img")
    }

    @Test func `a processed image with another spec is refused`() async throws {
        let file = try file()
        let transport = ScriptedTransport([
            StubResponse(201, imageResource(id: "img", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img", state: "PREPARE_FOR_SUBMISSION", specID: "other"))
        ])
        do {
            _ = try await uploader(transport).ensureReady(file, libraryID: "lib", existing: nil, expectedSpecID: spec)
            Issue.record("expected an error")
        } catch let ASCError.specMismatch(name, expected, got) {
            #expect(name == "panel-03.png")
            #expect(expected == spec)
            #expect(got == "other")
        }
    }

    @Test func `a ready image keeps polling until its spec is filled in`() async throws {
        let file = try file()
        let transport = ScriptedTransport([
            StubResponse(201, imageResource(id: "img", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img", state: "PREPARE_FOR_SUBMISSION")),
            StubResponse(200, imageResource(id: "img", state: "PREPARE_FOR_SUBMISSION", specID: spec))
        ])
        let id = try await uploader(transport).ensureReady(file, libraryID: "lib", existing: nil, expectedSpecID: spec)
        #expect(id == "img")
        #expect(transport.requests.count == 6)
    }

    @Test func `a ready library image is reused without any request`() async throws {
        let transport = ScriptedTransport([])
        let id = try await uploader(transport).ensureReady(
            file(),
            libraryID: "lib",
            existing: LibraryImage(id: "kept", state: "APPROVED", specID: spec),
            expectedSpecID: spec
        )
        #expect(id == "kept")
        #expect(transport.requests.isEmpty)
    }

    @Test func `an upload complete image is polled and an awaiting upload leftover is replaced`() async throws {
        let polled = ScriptedTransport([StubResponse(200, imageResource(id: "half", state: "PREPARE_FOR_SUBMISSION", specID: spec))])
        let id = try await uploader(polled).ensureReady(
            file(),
            libraryID: "lib",
            existing: LibraryImage(id: "half", state: "UPLOAD_COMPLETE"),
            expectedSpecID: spec
        )
        #expect(id == "half")
        #expect(polled.requests.map(requestLine) == ["GET /v1/appAssetLibraryImages/half"])

        let replaced = ScriptedTransport([
            StubResponse(204, ""),
            StubResponse(201, imageResource(id: "new", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200),
            StubResponse(200, imageResource(id: "new", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "new", state: "PREPARE_FOR_SUBMISSION", specID: spec))
        ])
        let newID = try await uploader(replaced).ensureReady(
            file(),
            libraryID: "lib",
            existing: LibraryImage(id: "stale", state: "AWAITING_UPLOAD"),
            expectedSpecID: spec
        )
        #expect(newID == "new")
        #expect(replaced.requests.prefix(2).map(requestLine) == ["DELETE /v1/appAssetLibraryImages/stale", "POST /v1/appAssetLibraryImages"])
    }

    @Test func `processing that never finishes times out`() async throws {
        let transport = ScriptedTransport(Array(repeating: StubResponse(200, imageResource(id: "half", state: "UPLOAD_COMPLETE")), count: 4))
        let sleeps = SleepRecorder()
        let uploader = try AssetUploader(
            client: makeClient(transport),
            log: .silent,
            sleeper: sleeps.sleeper,
            pollInterval: .seconds(2),
            timeout: .seconds(6)
        )
        await #expect(throws: ASCError.self) {
            try await uploader.ensureReady(
                file(),
                libraryID: "lib",
                existing: LibraryImage(id: "half", state: "UPLOAD_COMPLETE"),
                expectedSpecID: spec
            )
        }
        #expect(sleeps.recorded.count == 3)
    }
}
