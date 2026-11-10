@testable import ASCListingKit
import Foundation
import Synchronization
import Testing

struct MetadataSyncTests {
    private let context = AppStoreContext(
        app: AppRecord(id: "app", name: "MyApp", bundleId: "com.example.MyApp", primaryLocale: "en-US"),
        version: VersionRecord(id: "ver", versionString: "1.0", state: "PREPARE_FOR_SUBMISSION"),
        appInfo: AppInfoRecord(id: "info", state: "PREPARE_FOR_SUBMISSION")
    )

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let root = try jsonObject(request.httpBody)
        return try #require(root["data"] as? [String: Any])
    }

    @Test func `creates, patches and copyright go out in order with minimal bodies`() async throws {
        let local = LocalMetadata(
            locales: [
                "en-US": [.name: "Table", .subtitle: "Learn", .keywords: "new"],
                "es-MX": [.name: "Mesa", .description: "Hola"]
            ],
            copyright: "2026 Me"
        )
        let info = [LocalizationRecord(id: "li-en", locale: "en-US", fields: [.name: "Table"])]
        let version = [LocalizationRecord(id: "lv-en", locale: "en-US", fields: [.keywords: "old"])]
        let plan = MetadataPlan.make(
            local: local,
            appInfoLocalizations: info,
            versionLocalizations: version,
            remoteCopyright: nil,
            localeFilter: nil
        )
        let okBody = #"{"data":{"type":"x","id":"1"}}"#
        let statuses = [200, 200, 201, 201, 200]
        let transport = ScriptedTransport(statuses.map { StubResponse($0, okBody) })
        let lines = Mutex<[String]>([])
        let log = PublishLog { line in lines.withLock { $0.append(line) } }
        let signer = try JWTSigner(credentials: makeCredentials())
        let client = ASCClient(transport: transport, signer: signer, log: .silent, sleeper: SleepRecorder().sleeper)
        try await MetadataSync(client: client, log: log).apply(
            plan,
            context: context,
            appInfoLocalizations: info,
            versionLocalizations: version
        )

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PATCH /v1/appInfoLocalizations/li-en",
            "PATCH /v1/appStoreVersionLocalizations/lv-en",
            "POST /v1/appInfoLocalizations",
            "POST /v1/appStoreVersionLocalizations",
            "PATCH /v1/appStoreVersions/ver"
        ])
        let infoPatch = try body(requests[0])
        #expect(infoPatch["id"] as? String == "li-en")
        #expect(try #require(infoPatch["attributes"] as? [String: String]) == ["subtitle": "Learn"])
        let versionPatch = try body(requests[1])
        #expect(try #require(versionPatch["attributes"] as? [String: String]) == ["keywords": "new"])
        let infoPost = try body(requests[2])
        #expect(try #require(infoPost["attributes"] as? [String: String]) == ["locale": "es-MX", "name": "Mesa"])
        let relationships = try #require(infoPost["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["appInfo"]?["data"] == ["type": "appInfos", "id": "info"])
        let versionPost = try body(requests[3])
        #expect(try #require(versionPost["attributes"] as? [String: String]) == ["locale": "es-MX", "description": "Hola"])
        #expect(try #require(body(requests[4])["attributes"] as? [String: String]) == ["copyright": "2026 Me"])
        #expect(lines.withLock { $0 }.count == 5)
    }

    @Test func `the first api error stops the run and names the locale and scope`() async throws {
        let local = LocalMetadata(locales: ["es-MX": [.name: "Mesa", .description: "Hola"], "fr": [.name: "Table"]])
        let plan = MetadataPlan.make(local: local, appInfoLocalizations: [], versionLocalizations: [], remoteCopyright: nil, localeFilter: nil)
        let failure = StubResponse(400, #"{"errors":[{"status":"400","code":"ENTITY_ERROR","detail":"bad keywords"}]}"#)
        let transport = ScriptedTransport([StubResponse(201, #"{"data":{"type":"x","id":"1"}}"#), failure])
        let client = try makeClient(transport)
        do {
            try await MetadataSync(client: client, log: .silent).apply(plan, context: context, appInfoLocalizations: [], versionLocalizations: [])
            Issue.record("expected a failure")
        } catch let ASCError.step(label, underlying) {
            #expect(label == "es-MX version localization")
            #expect("\(underlying)".contains("bad keywords"))
        }
        #expect(transport.requests.count == 2)
    }

    @Test func `a conflict on create updates the implicitly created localization`() async throws {
        let local = LocalMetadata(locales: ["es-MX": [.description: "Hola", .keywords: "k"]])
        let plan = MetadataPlan.make(local: local, appInfoLocalizations: [], versionLocalizations: [], remoteCopyright: nil, localeFilter: nil)
        let conflict = StubResponse(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR.ATTRIBUTE.INVALID","detail":"already exists"}]}"#)
        let list = StubResponse(
            200,
            #"{"data":[{"type":"appStoreVersionLocalizations","id":"lv-es","attributes":{"locale":"es-MX","description":"Hola","keywords":"old"}}]}"#
        )
        let transport = ScriptedTransport([conflict, list, StubResponse(200, #"{"data":{"type":"x","id":"1"}}"#)])
        try await MetadataSync(client: makeClient(transport), log: .silent)
            .apply(plan, context: context, appInfoLocalizations: [], versionLocalizations: [])
        let requests = transport.requests
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "GET", "PATCH"])
        #expect(requests[2].url?.path == "/v1/appStoreVersionLocalizations/lv-es")
        #expect(try #require(body(requests[2])["attributes"] as? [String: String]) == ["keywords": "k"])
    }
}
