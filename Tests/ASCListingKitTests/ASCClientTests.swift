@testable import ASCListingKit
import Foundation
import Testing

struct ASCClientTests {
    struct Attributes: Codable, Sendable {
        let name: String?
    }

    typealias Item = Resource<Attributes>

    @Test func `api calls carry authorization and uploads do not`() async throws {
        let transport = ScriptedTransport([
            StubResponse(200, #"{"data":{"type":"apps","id":"1","attributes":{"name":"A"}}}"#),
            StubResponse(200, "")
        ])
        let client = try makeClient(transport)

        let document = try await client.get("/v1/apps/1", as: Document<Item>.self)
        #expect(document.data.attributes?.name == "A")

        let operation = UploadOperation(
            method: "PUT",
            url: "https://upload.example.com/part",
            length: 3,
            offset: 2,
            requestHeaders: [.init(name: "Content-Type", value: "image/png")]
        )
        try await client.upload(operation, bytes: Data([0, 1, 2, 3, 4, 5]))

        let requests = transport.requests
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].httpBody == Data([2, 3, 4]))
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "image/png")
    }

    @Test func `upload rejects an out of range operation`() async throws {
        let client = try makeClient(ScriptedTransport([]))
        let operation = UploadOperation(method: "PUT", url: "https://upload.example.com/p", length: 10, offset: 0)
        await #expect(throws: ASCError.self) { try await client.upload(operation, bytes: Data([1])) }
    }

    @Test func `query values are percent encoded`() async throws {
        let transport = ScriptedTransport([StubResponse(200, #"{"data":[]}"#)])
        let client = try makeClient(transport)
        _ = try await client.get(
            "/v1/apps",
            query: ["filter[bundleId]": "com.example.My App&x"],
            as: CollectionDocument<Item>.self
        )
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url == "https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=com.example.My%20App%26x")
    }

    @Test func `non ascii and reserved characters are percent encoded`() async throws {
        let transport = ScriptedTransport([StubResponse(200, #"{"data":[]}"#)])
        let client = try makeClient(transport)
        _ = try await client.get("/v1/apps", query: ["q": "é:a"], as: CollectionDocument<Item>.self)
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url == "https://api.appstoreconnect.apple.com/v1/apps?q=%C3%A9%3Aa")
    }

    @Test func `get all follows next links and collects included`() async throws {
        let transport = ScriptedTransport([
            StubResponse(200, """
            {"data":[{"type":"t","id":"1"}],
             "included":[{"type":"appAssetLibraryImages","id":"i1","attributes":{"referenceName":"sha256:aa"}}],
             "links":{"next":"https://api.appstoreconnect.apple.com/v1/things?cursor=2"}}
            """),
            StubResponse(200, """
            {"data":[{"type":"t","id":"2"}],
             "links":{"next":"https://api.appstoreconnect.apple.com/v1/things?cursor=3"}}
            """),
            StubResponse(200, #"{"data":[{"type":"t","id":"3"}]}"#)
        ])
        let client = try makeClient(transport)

        let result = try await client.getAll("/v1/things", resource: Item.self)
        #expect(result.data.map(\.id) == ["1", "2", "3"])
        #expect(result.included.count == 1)
        #expect(result.included.first?.attributes["referenceName"]?.stringValue == "sha256:aa")
        let urls = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.last == "https://api.appstoreconnect.apple.com/v1/things?cursor=3")
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != nil })
    }

    @Test func `retries after A too many requests response`() async throws {
        let transport = ScriptedTransport([
            StubResponse(429, "{}", headers: ["Retry-After": "7"]),
            StubResponse(200, #"{"data":{"type":"apps","id":"1"}}"#)
        ])
        let sleeps = SleepRecorder()
        let client = try makeClient(transport, sleeps: sleeps)

        let document = try await client.get("/v1/apps/1", as: Document<Item>.self)
        #expect(document.data.id == "1")
        #expect(transport.requests.count == 2)
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func `gives up after five server errors`() async throws {
        let body = #"{"errors":[{"status":"500","code":"UNEXPECTED_ERROR","title":"Boom","detail":"try later"}]}"#
        let transport = ScriptedTransport(Array(repeating: StubResponse(500, body), count: 5))
        let sleeps = SleepRecorder()
        let client = try makeClient(transport, sleeps: sleeps)

        do {
            _ = try await client.get("/v1/apps/1", as: Document<Item>.self)
            Issue.record("expected a throw")
        } catch let ASCError.api(status, errors) {
            #expect(status == 500)
            #expect(errors.first?.message == "500 UNEXPECTED_ERROR: try later")
        }
        #expect(transport.requests.count == 5)
        #expect(sleeps.recorded == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func `error body becomes A formatted api error`() async throws {
        let body = #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"Conflict"}]}"#
        let client = try makeClient(ScriptedTransport([StubResponse(409, body)]))
        do {
            _ = try await client.get("/v1/apps/1", as: Document<Item>.self)
            Issue.record("expected a throw")
        } catch let error as ASCError {
            #expect(error.description == "409 ENTITY_ERROR: Conflict")
        }
    }

    @Test func `forbidden mentions the required role`() async throws {
        let body = #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"Forbidden","detail":"not allowed"}]}"#
        let client = try makeClient(ScriptedTransport([StubResponse(403, body)]))
        do {
            _ = try await client.get("/v1/apps/1", as: Document<Item>.self)
            Issue.record("expected a throw")
        } catch let error as ASCError {
            #expect(error.description.contains("App Manager"))
            #expect(error.description.contains("403 FORBIDDEN_ERROR: not allowed"))
        }
    }

    @Test func `send encodes AJSONAPI body and delete succeeds on empty responses`() async throws {
        let transport = ScriptedTransport([
            StubResponse(200, #"{"data":{"type":"appStoreVersions","id":"9"}}"#),
            StubResponse(204, "")
        ])
        let client = try makeClient(transport)

        let body = RequestBody<[String: String]>.update(type: "appStoreVersions", id: "9", attributes: ["copyright": "2026 X"])
        _ = try await client.send(.patch, "/v1/appStoreVersions/9", body: body, as: Document<Item>.self)
        try await client.delete("/v1/appAssetLibraryPlacements/5")

        let sent = try #require(transport.requests[0].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: [String: Any]])
        #expect(object["data"]?["type"] as? String == "appStoreVersions")
        #expect(object["data"]?["id"] as? String == "9")
        #expect((object["data"]?["attributes"] as? [String: String]) == ["copyright": "2026 X"])
        #expect(transport.requests[0].httpMethod == "PATCH")
        #expect(transport.requests[1].httpMethod == "DELETE")
    }

    @Test func `create body carries relationships and no id`() throws {
        let body = RequestBody<[String: String]>.create(
            type: "appInfoLocalizations",
            attributes: ["locale": "fr"],
            relationships: ["appInfo": .one(type: "appInfos", id: "7")]
        )
        let data = try JSONEncoder().encode(body)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let resource = try #require(object["data"])
        #expect(resource["id"] == nil)
        let relationships = try #require(resource["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["appInfo"]?["data"] == ["type": "appInfos", "id": "7"])
    }
}
