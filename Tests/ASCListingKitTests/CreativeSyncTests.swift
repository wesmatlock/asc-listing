@testable import ASCListingKit
import Foundation
import Testing

struct CreativeSyncTests {
    private let context = AppStoreContext(
        app: AppRecord(id: "app", name: "MyApp", bundleId: "com.example.MyApp", primaryLocale: "en-US"),
        version: VersionRecord(id: "ver", versionString: "1.0", state: "PREPARE_FOR_SUBMISSION"),
        appInfo: AppInfoRecord(id: "info", state: "PREPARE_FOR_SUBMISSION")
    )

    private func universalFile() throws -> ScreenshotFile {
        let bytes = Data("universal bytes".utf8)
        let url = try makeTempDirectory().appending(path: "universal.png")
        try bytes.write(to: url)
        return ScreenshotFile(
            url: url,
            fileName: "universal.png",
            width: 5244,
            height: 2950,
            hasAlpha: false,
            byteCount: bytes.count,
            fingerprint: ScreenshotFile.fingerprint(of: bytes),
            mimeType: "image/png"
        )
    }

    private func both(_ file: ScreenshotFile) -> [CreativeAsset] {
        [CreativeAsset(placementType: headerType, file: file), CreativeAsset(placementType: searchType, file: file)]
    }

    private func expectBodies(_ requests: [URLRequest], fingerprint: String) throws {
        let reserve = try #require(requestData(requests[0])["attributes"] as? [String: Any])
        #expect(reserve["category"] as? String == "CREATIVE_ASSETS")
        #expect(reserve["fileName"] as? String == "universal.png")
        #expect(reserve["referenceName"] as? String == fingerprint)

        for (index, type) in [(4, headerType), (6, searchType)] {
            let body = try requestData(requests[index])
            #expect(try #require(body["attributes"] as? [String: String]) == ["placementType": type, "placementGroup": "DEFAULT_PROFILE"])
            let links = try #require(body["relationships"] as? [String: [String: [String: String]]])
            #expect(links["image"]?["data"] == ["type": "appAssetLibraryImages", "id": "img-u"])
            #expect(links["appStoreVersionLocalization"]?["data"] == ["type": "appStoreVersionLocalizations", "id": "loc-en"])
            let query = requests[index + 1].url?.query(percentEncoded: false) ?? ""
            #expect(query.contains("filter[placementType]=\(type)"))
            #expect(query.contains("filter[placementGroup]=DEFAULT_PROFILE"))
            #expect(query.contains("include=image"))
        }
    }

    @Test func `one upload backs the header and the search placements with no ordering request`() async throws {
        let file = try universalFile()
        let plan = try ScreenshotPlan.makeCreative(
            desired: ["en-US": both(file)],
            refData: fixtureRefData(),
            current: ["en-US": CurrentLocaleState(localizationID: "loc-en")],
            library: [:],
            libraryID: "lib"
        )
        let operations = #"[{"method":"PUT","url":"https://upload.example/one","length":15,"offset":0}]"#
        let placedHeader = placementList([PlacedImage("pl-h", "img-u", file.fingerprint)])
        let placedSearch = placementList([PlacedImage("pl-s", "img-u", file.fingerprint)])
        let transport = ScriptedTransport([
            StubResponse(201, imageResource(id: "img-u", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img-u", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img-u", state: "PREPARE_FOR_SUBMISSION", specID: universalSpec)),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-h"}}"#),
            StubResponse(200, placedHeader),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-s"}}"#),
            StubResponse(200, placedSearch)
        ])
        let lines = LineRecorder()
        let client = try makeClient(transport)
        let uploader = AssetUploader(client: client, log: lines.log, sleeper: SleepRecorder().sleeper)
        try await ScreenshotSync(client: client, log: lines.log, uploader: uploader, sleeper: SleepRecorder().sleeper).apply(plan, context: context)

        let requests = transport.requests
        #expect(requests.map(requestLine) == [
            "POST /v1/appAssetLibraryImages",
            "PUT /one",
            "PATCH /v1/appAssetLibraryImages/img-u",
            "GET /v1/appAssetLibraryImages/img-u",
            "POST /v1/appAssetLibraryPlacements",
            "GET /v1/appStoreVersionLocalizations/loc-en/placements",
            "POST /v1/appAssetLibraryPlacements",
            "GET /v1/appStoreVersionLocalizations/loc-en/placements"
        ])
        try expectBodies(requests, fingerprint: file.fingerprint)
        #expect(lines.lines == [
            "uploaded universal.png",
            "en-US \(headerType): 1 placed",
            "en-US \(searchType): 1 placed"
        ])
    }

    @Test func `an existing placement is deleted first and a failure is reported per placement`() async throws {
        let file = try universalFile()
        let old = [CurrentPlacement(id: "old-h", imageReferenceName: "sha256:old")]
        let plan = try ScreenshotPlan.makeCreative(
            desired: ["en-US": both(file)],
            refData: fixtureRefData(),
            current: ["en-US": CurrentLocaleState(
                localizationID: "loc-en",
                placements: [PlacementSlot(placementType: headerType, group: "DEFAULT_PROFILE"): old]
            )],
            library: [file.fingerprint: LibraryImage(id: "img-u", state: "APPROVED", specID: universalSpec, category: "CREATIVE_ASSETS")],
            libraryID: "lib"
        )
        let transport = ScriptedTransport([
            StubResponse(204, ""),
            StubResponse(500, #"{"errors":[{"status":"500","code":"UNEXPECTED_ERROR","detail":"boom"}]}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-s"}}"#),
            StubResponse(200, placementList([PlacedImage("pl-s", "img-u", file.fingerprint)]))
        ])
        let lines = LineRecorder()
        let client = try makeClient(transport)
        let sync = ScreenshotSync(client: client, log: lines.log, uploader: AssetUploader(client: client, log: lines.log))
        do {
            try await sync.apply(plan, context: context)
            Issue.record("expected an error")
        } catch let error as ASCError {
            guard case let .creativePlacementsFailed(failed) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(failed == ["en-US \(headerType)"])
            #expect(error.description.hasPrefix("1 creative placement failed"))
        }
        #expect(transport.requests.map(requestLine) == [
            "DELETE /v1/appAssetLibraryPlacements/old-h",
            "POST /v1/appAssetLibraryPlacements",
            "POST /v1/appAssetLibraryPlacements",
            "GET /v1/appStoreVersionLocalizations/loc-en/placements"
        ])
        #expect(lines.lines == ["en-US \(headerType): FAILED — 500 UNEXPECTED_ERROR: boom", "en-US \(searchType): 1 placed"])
    }

    @Test func `a placement that never shows is reported as not visible`() async throws {
        let file = try universalFile()
        let plan = try ScreenshotPlan.makeCreative(
            desired: ["en-US": [CreativeAsset(placementType: headerType, file: file)]],
            refData: fixtureRefData(),
            current: ["en-US": CurrentLocaleState(localizationID: "loc-en")],
            library: [file.fingerprint: LibraryImage(id: "img-u", state: "APPROVED", specID: universalSpec, category: "CREATIVE_ASSETS")],
            libraryID: "lib"
        )
        let empty = StubResponse(200, #"{"data":[]}"#)
        let transport = ScriptedTransport([StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-h"}}"#)] + Array(repeating: empty, count: 5))
        let lines = LineRecorder()
        let client = try makeClient(transport)
        let sync = ScreenshotSync(client: client, log: lines.log, uploader: AssetUploader(client: client, log: lines.log), sleeper: SleepRecorder().sleeper)
        await #expect(throws: ASCError.self) { try await sync.apply(plan, context: context) }
        #expect(lines.lines.first?.contains("the placed image does not show on App Store Connect") == true)
    }
}

struct CreativeReadTests {
    private func fixtureBody() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "refdata", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func libraryBody(_ fingerprint: String) -> String {
        """
        {"data":[
        {"type":"appAssetLibraryImages","id":"shot","attributes":{"referenceName":"\(fingerprint)","state":"APPROVED","category":"APP_SCREENSHOTS_AND_PREVIEWS"}},
        {"type":"appAssetLibraryImages","id":"art","attributes":{"referenceName":"\(fingerprint)","state":"APPROVED",\
        "category":"CREATIVE_ASSETS","specId":"\(universalSpec)"}}
        ]}
        """
    }

    @Test func `library reads keep only the requested category`() async throws {
        let transport = ScriptedTransport([StubResponse(200, libraryBody("sha256:x")), StubResponse(200, libraryBody("sha256:x"))])
        let reader = try ScreenshotStateReader(client: makeClient(transport))
        let creative = try await reader.libraryImages(libraryID: "lib", category: "CREATIVE_ASSETS")
        #expect(creative["sha256:x"] == LibraryImage(id: "art", state: "APPROVED", specID: universalSpec, category: "CREATIVE_ASSETS"))
        let screenshots = try await reader.libraryImages(libraryID: "lib")
        #expect(screenshots["sha256:x"]?.id == "shot")
    }

    @Test func `a dry run of the creative block only reads`() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImageFixture.writePNG(width: 5244, height: 2950, to: root.appending(path: "creative/en/universal.png"))
        let file = try ScreenshotFile.read(root.appending(path: "creative/en/universal.png"))
        let manifest = ResolvedManifest(
            manifestURL: root.appending(path: "asc-listing.json"),
            bundleId: "com.example.MyApp",
            platform: .ios,
            version: "1.0",
            metadataDirectory: nil,
            screenshots: nil,
            creative: ResolvedCreative(
                directory: root.appending(path: "creative"),
                sets: .mapping(["en": ["en-US"]]),
                placements: [headerType: "universal.png", searchType: "universal.png"]
            )
        )
        let app = #"{"data":[{"type":"apps","id":"app","attributes":{"name":"MyApp","bundleId":"com.example.MyApp","primaryLocale":"en-US"}}]}"#
        let version = #"{"data":[{"type":"appStoreVersions","id":"ver","attributes":{"versionString":"1.0","appVersionState":"PREPARE_FOR_SUBMISSION"}}]}"#
        let info = #"{"data":[{"type":"appInfos","id":"info","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#
        let localizations = #"{"data":[{"type":"appStoreVersionLocalizations","id":"loc-en","attributes":{"locale":"en-US"}}]}"#
        let transport = try ScriptedTransport([
            StubResponse(200, app),
            StubResponse(200, version),
            StubResponse(200, info),
            StubResponse(200, fixtureBody()),
            StubResponse(200, #"{"data":{"type":"appAssetLibraries","id":"lib"}}"#),
            StubResponse(200, libraryBody(file.fingerprint)),
            StubResponse(200, localizations),
            StubResponse(200, placementList([PlacedImage("pl-s", "art", file.fingerprint)])),
            StubResponse(200, #"{"data":[]}"#)
        ])
        let lines = LineRecorder()
        let session = try PublishSession(manifest: manifest, client: makeClient(transport), log: lines.log)
        let output = LineRecorder()
        try await PublishRun(session: session, emit: { output.log.info($0) }).run([.creative], options: PublishOptions(version: "1.0"))

        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(transport.requests.count == 9)
        let placementQueries = transport.requests.suffix(2).map { $0.url?.query(percentEncoded: false) ?? "" }
        #expect(placementQueries[0].contains("filter[placementType]=\(searchType)"))
        #expect(placementQueries[1].contains("filter[placementType]=\(headerType)"))
        let text = output.lines.joined(separator: "\n")
        #expect(text.contains("en-US* | APP_STORE_SEARCH_RESULTS_ASSET | universal.png | unchanged"))
        #expect(text.contains("en-US* | PRODUCT_PAGE_HEADER_ASSET      | universal.png | replace (0 → 1)"))
        #expect(text.contains("0 files to upload, 1 already in the asset library, 0 localizations to create"))
        #expect(output.lines.last == PublishRun.dryRunNotice)
        #expect(lines.lines.isEmpty)
    }

    @Test func `publish skips a manifest without a creative block and the creative command requires one`() async throws {
        let manifest = ResolvedManifest(
            manifestURL: URL(fileURLWithPath: "/tmp/m.json"),
            bundleId: "a.b",
            platform: .ios,
            version: "1.0",
            metadataDirectory: nil,
            screenshots: nil
        )
        let lines = LineRecorder()
        let session = try PublishSession(manifest: manifest, client: makeClient(ScriptedTransport([])), log: lines.log)
        let run = PublishRun(session: session, emit: { _ in })
        try await run.run([.creative], options: PublishOptions(version: "1.0"), skipUnconfigured: true)
        #expect(lines.lines == ["skipping creative: the manifest has no \"creative\" section"])
        await #expect {
            try await run.run([.creative], options: PublishOptions(version: "1.0"))
        } throws: { error in
            "\(error)" == "The manifest has no \"creative\" section."
        }
    }
}
