@testable import ASCListingKit
import Foundation
import Testing

struct AppStoreLookupTests {
    private let manifest = ResolvedManifest(
        manifestURL: URL(fileURLWithPath: "/tmp/m.json"),
        bundleId: "com.example.MyApp",
        platform: .ios,
        version: "1.0",
        metadataDirectory: nil,
        screenshots: nil
    )

    private let appResponse = StubResponse(
        200,
        #"{"data":[{"type":"apps","id":"1234567890","attributes":{"name":"MyApp","bundleId":"com.example.MyApp","primaryLocale":"en-US"}}]}"#
    )

    private func versions(_ entries: [(String, String)]) -> StubResponse {
        let items = entries.map {
            #"{"type":"appStoreVersions","id":"v-\#($0.0)","attributes":{"versionString":"\#($0.0)","appVersionState":"\#($0.1)","copyright":null}}"#
        }
        return StubResponse(200, #"{"data":[\#(items.joined(separator: ","))]}"#)
    }

    private func appInfos(_ states: [String]) -> StubResponse {
        let items = states.enumerated().map {
            #"{"type":"appInfos","id":"info-\#($0.offset)","attributes":{"state":"\#($0.element)","appStoreState":"\#($0.element)"}}"#
        }
        return StubResponse(200, #"{"data":[\#(items.joined(separator: ","))]}"#)
    }

    @Test func `the editable version and app info are found`() async throws {
        let transport = ScriptedTransport([
            appResponse,
            versions([("1.0", "PREPARE_FOR_SUBMISSION")]),
            appInfos(["READY_FOR_SALE", "PREPARE_FOR_SUBMISSION"])
        ])
        let context = try await AppStoreLookup(client: makeClient(transport))
            .context(manifest: manifest, version: "1.0", createVersion: false)
        #expect(context.app.id == "1234567890")
        #expect(context.app.primaryLocale == "en-US")
        #expect(context.version.id == "v-1.0")
        #expect(context.appInfo.id == "info-1")
        let url = try #require(transport.requests[1].url?.absoluteString)
        #expect(url.contains("filter%5Bplatform%5D=IOS"))
        #expect(url.contains("filter%5BversionString%5D=1.0"))
    }

    @Test func `a missing version lists the available ones`() async throws {
        let transport = ScriptedTransport([
            appResponse,
            StubResponse(200, #"{"data":[]}"#),
            versions([("0.9", "READY_FOR_SALE"), ("0.8", "READY_FOR_SALE")])
        ])
        do {
            _ = try await AppStoreLookup(client: makeClient(transport)).context(manifest: manifest, version: "1.0", createVersion: false)
            Issue.record("expected versionNotFound")
        } catch let ASCError.versionNotFound(version, available) {
            #expect(version == "1.0")
            #expect(available == ["0.9", "0.8"])
        }
    }

    @Test func `create version posts the right body`() async throws {
        let created = StubResponse(
            201,
            #"{"data":{"type":"appStoreVersions","id":"new","attributes":{"versionString":"1.1","appVersionState":"PREPARE_FOR_SUBMISSION"}}}"#
        )
        let transport = ScriptedTransport([appResponse, StubResponse(200, #"{"data":[]}"#), appInfos(["PREPARE_FOR_SUBMISSION"]), created])
        let context = try await AppStoreLookup(client: makeClient(transport))
            .context(manifest: manifest, version: "1.1", createVersion: true)
        #expect(context.version.id == "new")
        #expect(context.appInfo.id == "info-0")
        let post = transport.requests[3]
        #expect(post.httpMethod == "POST")
        #expect(post.url?.path == "/v1/appStoreVersions")
        let body = try jsonObject(post.httpBody)
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["type"] as? String == "appStoreVersions")
        let attributes = try #require(data["attributes"] as? [String: String])
        #expect(attributes == ["platform": "IOS", "versionString": "1.1"])
        let relationships = try #require(data["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["app"]?["data"] == ["type": "apps", "id": "1234567890"])
    }

    @Test func `a version in review is not editable but still readable`() async throws {
        let responses = {
            [appResponse, versions([("1.0", "WAITING_FOR_REVIEW")]), appInfos(["PREPARE_FOR_SUBMISSION"])]
        }
        let lookup = try AppStoreLookup(client: makeClient(ScriptedTransport(responses())))
        do {
            _ = try await lookup.context(manifest: manifest, version: "1.0", createVersion: false)
            Issue.record("expected notEditable")
        } catch let ASCError.notEditable(what, state) {
            #expect(what.contains("1.0"))
            #expect(state == "WAITING_FOR_REVIEW")
        }
        let read = try await AppStoreLookup(client: makeClient(ScriptedTransport(responses())))
            .readContext(manifest: manifest, version: "1.0")
        #expect(read.version.state == "WAITING_FOR_REVIEW")
    }

    @Test func `no version is created while the app info is not editable`() async throws {
        let transport = ScriptedTransport([appResponse, StubResponse(200, #"{"data":[]}"#), appInfos(["READY_FOR_SALE"])])
        do {
            _ = try await AppStoreLookup(client: makeClient(transport)).context(manifest: manifest, version: "1.1", createVersion: true)
            Issue.record("expected notEditable")
        } catch let ASCError.notEditable(what, state) {
            #expect(what == "app info")
            #expect(state == "READY_FOR_SALE")
        }
        #expect(!transport.requests.contains { $0.httpMethod == "POST" })
    }

    @Test func `no editable app info is refused`() async throws {
        let transport = ScriptedTransport([appResponse, versions([("1.0", "PREPARE_FOR_SUBMISSION")]), appInfos(["READY_FOR_SALE"])])
        await #expect(throws: ASCError.self) {
            try await AppStoreLookup(client: makeClient(transport)).context(manifest: manifest, version: "1.0", createVersion: false)
        }
    }

    @Test func `an unknown app is reported`() async throws {
        let transport = ScriptedTransport([StubResponse(200, #"{"data":[]}"#)])
        do {
            _ = try await AppStoreLookup(client: makeClient(transport)).app(bundleId: "x.y")
            Issue.record("expected appNotFound")
        } catch let ASCError.appNotFound(bundleId) {
            #expect(bundleId == "x.y")
        }
    }

    @Test func `localizations keep only non null fields`() async throws {
        let transport = ScriptedTransport([
            StubResponse(200, #"{"data":[{"type":"appInfoLocalizations","id":"l1","attributes":{"locale":"ja","name":"名","subtitle":null,"privacyPolicyUrl":null}}]}"#),
            StubResponse(200, #"{"data":[{"type":"appStoreVersionLocalizations","id":"l2","attributes":{"locale":"ja","keywords":"k","whatsNew":null}}]}"#)
        ])
        let lookup = try AppStoreLookup(client: makeClient(transport))
        let info = try await lookup.appInfoLocalizations(appInfoID: "i")
        let version = try await lookup.versionLocalizations(versionID: "v")
        #expect(info == [LocalizationRecord(id: "l1", locale: "ja", fields: [.name: "名"])])
        #expect(version == [LocalizationRecord(id: "l2", locale: "ja", fields: [.keywords: "k"])])
    }
}
