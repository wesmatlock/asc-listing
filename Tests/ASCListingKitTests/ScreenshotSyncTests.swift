@testable import ASCListingKit
import Foundation
import Testing

struct ScreenshotSyncTests {
    private let group = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"
    private let spec = "bd402f1a-26ee-5b83-9dd7-972c60c43d47"
    private let context = AppStoreContext(
        app: AppRecord(id: "app", name: "MyApp", bundleId: "com.example.MyApp", primaryLocale: "en-US"),
        version: VersionRecord(id: "ver", versionString: "1.0", state: "PREPARE_FOR_SUBMISSION"),
        appInfo: AppInfoRecord(id: "info", state: "PREPARE_FOR_SUBMISSION")
    )

    private func newFile() throws -> ScreenshotFile {
        let bytes = Data("panel two bytes".utf8)
        let url = try makeTempDirectory().appending(path: "panel-02.png")
        try bytes.write(to: url)
        return ScreenshotFile(
            url: url,
            fileName: "panel-02.png",
            width: 1320,
            height: 2868,
            hasAlpha: false,
            byteCount: bytes.count,
            fingerprint: ScreenshotFile.fingerprint(of: bytes)
        )
    }

    private func makePlan(_ files: [ScreenshotFile], reused: ScreenshotFile) throws -> ScreenshotPlan {
        try ScreenshotPlan.make(
            desired: ["es-MX": files],
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: ["es-MX": CurrentLocaleState(localizationID: nil)],
            library: [reused.fingerprint: LibraryImage(id: "img-1", state: "PREPARE_FOR_SUBMISSION", specID: spec)],
            libraryID: "lib"
        )
    }

    private func sync(
        _ transport: ScriptedTransport,
        lines: LineRecorder = LineRecorder(),
        orderSleeps: SleepRecorder = SleepRecorder()
    ) throws -> ScreenshotSync {
        let client = try makeClient(transport)
        let log = lines.log
        return ScreenshotSync(
            client: client,
            log: log,
            uploader: AssetUploader(client: client, log: log, sleeper: SleepRecorder().sleeper),
            sleeper: orderSleeps.sleeper
        )
    }

    private func existingPlan(_ files: [String: [ScreenshotFile]], current: [String: [CurrentPlacement]] = [:]) throws -> ScreenshotPlan {
        let all = files.values.flatMap(\.self)
        return try ScreenshotPlan.make(
            desired: files,
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: Dictionary(uniqueKeysWithValues: files.keys.map { locale in
                (locale, CurrentLocaleState(localizationID: "loc-\(locale)", groups: [group: current[locale] ?? []]))
            }),
            library: Dictionary(
                all.map { ($0.fingerprint, LibraryImage(id: "img-\($0.fileName)", state: "APPROVED", specID: spec)) },
                uniquingKeysWith: { first, _ in first }
            ),
            libraryID: "lib"
        )
    }

    private func expectPlacementBodies(_ requests: [URLRequest]) throws {
        let first = try requestData(requests[5])
        #expect(try #require(first["attributes"] as? [String: String]) == ["placementType": "APP_SCREENSHOT", "placementGroup": group])
        let firstLinks = try #require(first["relationships"] as? [String: [String: [String: String]]])
        #expect(firstLinks["image"]?["data"] == ["type": "appAssetLibraryImages", "id": "img-1"])
        #expect(firstLinks["appStoreVersionLocalization"]?["data"] == ["type": "appStoreVersionLocalizations", "id": "loc-es"])
        let second = try #require(requestData(requests[6])["relationships"] as? [String: [String: [String: String]]])
        #expect(second["image"]?["data"]?["id"] == "img-2")

        let ordering = try requestData(requests[7])
        #expect(try #require(ordering["attributes"] as? [String: String]) == ["placementGroup": group])
        let orderLinks = try #require(ordering["relationships"] as? [String: [String: Any]])
        let ordered = try #require(orderLinks["orderedPlacements"]?["data"] as? [[String: String]])
        #expect(ordered.map { $0["id"] } == ["pl-1", "pl-2"])
        #expect(ordered.allSatisfy { $0["type"] == "appAssetLibraryPlacements" })
    }

    @Test func `a new locale gets its localization, its uploads, placements in order and a verified read`() async throws {
        let reused = screenshot("panel-01.png")
        let fresh = try newFile()
        let plan = try makePlan([reused, fresh], reused: reused)
        let operations = #"[{"method":"PUT","url":"https://upload.example/one","length":15,"offset":0}]"#
        let transport = ScriptedTransport([
            StubResponse(201, #"{"data":{"type":"appStoreVersionLocalizations","id":"loc-es"}}"#),
            StubResponse(201, imageResource(id: "img-2", state: "AWAITING_UPLOAD", operations: operations)),
            StubResponse(200),
            StubResponse(200, imageResource(id: "img-2", state: "UPLOAD_COMPLETE")),
            StubResponse(200, imageResource(id: "img-2", state: "PREPARE_FOR_SUBMISSION", specID: spec)),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-1"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-2"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacementOrderingRequests","id":"ord"}}"#),
            StubResponse(200, placementList([PlacedImage("pl-1", "img-1", reused.fingerprint), PlacedImage("pl-2", "img-2", fresh.fingerprint)]))
        ])
        let lines = LineRecorder()
        try await sync(transport, lines: lines).apply(plan, context: context)

        let requests = transport.requests
        #expect(requests.map(requestLine) == [
            "POST /v1/appStoreVersionLocalizations",
            "POST /v1/appAssetLibraryImages",
            "PUT /one",
            "PATCH /v1/appAssetLibraryImages/img-2",
            "GET /v1/appAssetLibraryImages/img-2",
            "POST /v1/appAssetLibraryPlacements",
            "POST /v1/appAssetLibraryPlacements",
            "POST /v1/appAssetLibraryPlacementOrderingRequests",
            "GET /v1/appStoreVersionLocalizations/loc-es/placements"
        ])
        let localization = try requestData(requests[0])
        #expect(try #require(localization["attributes"] as? [String: String]) == ["locale": "es-MX"])

        try expectPlacementBodies(requests)

        let query = requests[8].url?.query(percentEncoded: false) ?? ""
        #expect(query.contains("filter[placementGroup]=\(group)"))
        #expect(query.contains("sort=placementGroupPosition"))
        #expect(query.contains("include=image"))
        #expect(lines.lines == [
            "created es-MX version localization",
            "uploaded panel-02.png",
            "es-MX \(group): 2 placed"
        ])
    }

    @Test func `existing placements are deleted first and a wrong order after five reads fails the group`() async throws {
        let one = screenshot("panel-01.png")
        let two = screenshot("panel-02.png")
        let plan = try existingPlan(["en-US": [one, two]], current: ["en-US": [CurrentPlacement(id: "old-1", imageReferenceName: two.fingerprint)]])
        let wrong = StubResponse(200, placementList([PlacedImage("pl-2", "img-2", two.fingerprint), PlacedImage("pl-1", "img-1", one.fingerprint)]))
        let transport = ScriptedTransport([
            StubResponse(204, ""),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-1"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-2"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacementOrderingRequests","id":"ord"}}"#)
        ] + Array(repeating: wrong, count: 5))
        let lines = LineRecorder()
        let orderSleeps = SleepRecorder()
        do {
            try await sync(transport, lines: lines, orderSleeps: orderSleeps).apply(plan, context: context)
            Issue.record("expected an error")
        } catch let ASCError.screenshotGroupsFailed(groups) {
            #expect(groups == ["en-US \(group)"])
        }
        #expect(transport.requests.first.map(requestLine) == "DELETE /v1/appAssetLibraryPlacements/old-1")
        #expect(transport.requests.count { requestLine($0) == "GET /v1/appStoreVersionLocalizations/loc-en-US/placements" } == 5)
        #expect(orderSleeps.recorded == Array(repeating: .seconds(2), count: 4))
        #expect(lines.lines.count == 1)
        #expect(lines.lines.first?.hasPrefix("en-US \(group): FAILED — ") == true)
        #expect(lines.lines.first?.contains("not in the requested order") == true)
    }

    @Test func `a conflict creating the localization adopts the existing one`() async throws {
        let one = screenshot("panel-01.png")
        let plan = try ScreenshotPlan.make(
            desired: ["es-MX": [one]],
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: [:],
            library: [one.fingerprint: LibraryImage(id: "img-1", state: "APPROVED", specID: spec)],
            libraryID: "lib"
        )
        let transport = ScriptedTransport([
            StubResponse(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"already exists"}]}"#),
            StubResponse(200, #"{"data":[{"type":"appStoreVersionLocalizations","id":"loc-es","attributes":{"locale":"es-MX"}}]}"#),
            StubResponse(200, placementList([PlacedImage("stale", "img-9", "sha256:stale")])),
            StubResponse(204, ""),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-1"}}"#),
            StubResponse(200, placementList([PlacedImage("pl-1", "img-1", one.fingerprint)]))
        ])
        let lines = LineRecorder()
        try await sync(transport, lines: lines).apply(plan, context: context)
        let requests = transport.requests
        #expect(requests.map(requestLine) == [
            "POST /v1/appStoreVersionLocalizations",
            "GET /v1/appStoreVersions/ver/appStoreVersionLocalizations",
            "GET /v1/appStoreVersionLocalizations/loc-es/placements",
            "DELETE /v1/appAssetLibraryPlacements/stale",
            "POST /v1/appAssetLibraryPlacements",
            "GET /v1/appStoreVersionLocalizations/loc-es/placements"
        ])
        let links = try #require(requestData(requests[4])["relationships"] as? [String: [String: [String: String]]])
        #expect(links["appStoreVersionLocalization"]?["data"]?["id"] == "loc-es")
        #expect(lines.lines.first == "es-MX version localization already existed")
    }

    @Test func `an adopted localization that already shows the screenshots is left alone`() async throws {
        let one = screenshot("panel-01.png")
        let plan = try ScreenshotPlan.make(
            desired: ["es-MX": [one]],
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: [:],
            library: [one.fingerprint: LibraryImage(id: "img-1", state: "APPROVED", specID: spec)],
            libraryID: "lib"
        )
        let transport = ScriptedTransport([
            StubResponse(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"already exists"}]}"#),
            StubResponse(200, #"{"data":[{"type":"appStoreVersionLocalizations","id":"loc-es","attributes":{"locale":"es-MX"}}]}"#),
            StubResponse(200, placementList([PlacedImage("pl-1", "img-1", one.fingerprint)]))
        ])
        let lines = LineRecorder()
        try await sync(transport, lines: lines).apply(plan, context: context)
        #expect(transport.requests.count == 3)
        #expect(lines.lines == ["es-MX version localization already existed", "es-MX \(group): already in place"])
    }
}

extension ScreenshotSyncTests {
    @Test func `an order that settles on a later read passes`() async throws {
        let one = screenshot("panel-01.png")
        let two = screenshot("panel-02.png")
        let plan = try existingPlan(["en-US": [one, two]])
        let transport = ScriptedTransport([
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-1"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-2"}}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacementOrderingRequests","id":"ord"}}"#),
            StubResponse(200, placementList([PlacedImage("pl-2", "img-2", two.fingerprint), PlacedImage("pl-1", "img-1", one.fingerprint)])),
            StubResponse(200, placementList([PlacedImage("pl-2", "img-2", two.fingerprint), PlacedImage("pl-1", "img-1", one.fingerprint)])),
            StubResponse(200, placementList([PlacedImage("pl-1", "img-1", one.fingerprint), PlacedImage("pl-2", "img-2", two.fingerprint)]))
        ])
        let lines = LineRecorder()
        let orderSleeps = SleepRecorder()
        try await sync(transport, lines: lines, orderSleeps: orderSleeps).apply(plan, context: context)
        #expect(orderSleeps.recorded == [.seconds(2), .seconds(2)])
        #expect(lines.lines == ["en-US \(group): 2 placed"])
    }

    @Test func `a failed group is reported and the next group still runs`() async throws {
        let one = screenshot("panel-01.png")
        let plan = try existingPlan(["en-US": [one], "es-MX": [one]])
        let transport = ScriptedTransport([
            StubResponse(500, #"{"errors":[{"status":"500","code":"UNEXPECTED_ERROR","detail":"boom"}]}"#),
            StubResponse(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"pl-es"}}"#),
            StubResponse(200, placementList([PlacedImage("pl-es", "img-panel-01.png", one.fingerprint)]))
        ])
        let lines = LineRecorder()
        do {
            try await sync(transport, lines: lines).apply(plan, context: context)
            Issue.record("expected an error")
        } catch let error as ASCError {
            guard case let .screenshotGroupsFailed(groups) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(groups == ["en-US \(group)"])
            #expect(error.description.contains("en-US \(group)"))
            #expect(error.description.contains("re-run the same command: it re-plans from what is live and only redoes these"))
        }
        #expect(transport.requests.map(requestLine) == [
            "POST /v1/appAssetLibraryPlacements",
            "POST /v1/appAssetLibraryPlacements",
            "GET /v1/appStoreVersionLocalizations/loc-es-MX/placements"
        ])
        #expect(lines.lines == ["en-US \(group): FAILED — 500 UNEXPECTED_ERROR: boom", "es-MX \(group): 1 placed"])
    }

    @Test func `an asset that fails to upload stops the run before any placement is touched`() async throws {
        let fresh = try newFile()
        let plan = try ScreenshotPlan.make(
            desired: ["en-US": [fresh]],
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: ["en-US": CurrentLocaleState(localizationID: "loc-en", groups: [group: [CurrentPlacement(id: "old", imageReferenceName: "sha256:old")]])],
            library: [:],
            libraryID: "lib"
        )
        let transport = ScriptedTransport([StubResponse(400, #"{"errors":[{"status":"400","code":"BAD"}]}"#)])
        do {
            try await sync(transport).apply(plan, context: context)
            Issue.record("expected an error")
        } catch let ASCError.step(label, _) {
            #expect(label == "panel-02.png")
        }
        #expect(transport.requests.map(requestLine) == ["POST /v1/appAssetLibraryImages"])
    }
}

struct ScreenshotStateReaderTests {
    @Test func `placements carry their image reference names in display order`() async throws {
        let transport = ScriptedTransport([
            StubResponse(200, placementList([PlacedImage("p2", "i2", "sha256:b"), PlacedImage("p1", "i1", "sha256:a")]))
        ])
        let placed = try await ScreenshotStateReader(client: makeClient(transport)).placements(localizationID: "loc", group: "G")
        #expect(placed == [CurrentPlacement(id: "p2", imageReferenceName: "sha256:b"), CurrentPlacement(id: "p1", imageReferenceName: "sha256:a")])
    }

    @Test func `library images prefer a ready duplicate`() async throws {
        let body = """
        {"data":[
        {"type":"appAssetLibraryImages","id":"a","attributes":{"referenceName":"sha256:x","state":"FAILED","category":"APP_SCREENSHOTS_AND_PREVIEWS"}},
        {"type":"appAssetLibraryImages","id":"b","attributes":{"referenceName":"sha256:x","state":"APPROVED","specId":"s","category":"APP_SCREENSHOTS_AND_PREVIEWS"}},
        {"type":"appAssetLibraryImages","id":"c","attributes":{"referenceName":"sha256:x","state":"UPLOAD_COMPLETE","category":"APP_SCREENSHOTS_AND_PREVIEWS"}},
        {"type":"appAssetLibraryImages","id":"d","attributes":{"referenceName":"sha256:y","state":"AWAITING_UPLOAD","category":"APP_SCREENSHOTS_AND_PREVIEWS"}}
        ]}
        """
        let transport = ScriptedTransport([StubResponse(200, body)])
        let images = try await ScreenshotStateReader(client: makeClient(transport)).libraryImages(libraryID: "lib")
        #expect(images["sha256:x"] == LibraryImage(id: "b", state: "APPROVED", specID: "s"))
        #expect(images["sha256:y"]?.id == "d")
        #expect(transport.requests.first.map(requestLine) == "GET /v1/appAssetLibraries/lib/images")
    }
}
