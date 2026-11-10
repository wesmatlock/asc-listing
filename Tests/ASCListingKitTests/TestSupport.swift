@testable import ASCListingKit
import CryptoKit
import Foundation
import Synchronization
import Testing

struct StubResponse {
    var status: Int
    var body: String
    var headers: [String: String]
    var networkError: URLError.Code?

    init(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    static func dropped(_ code: URLError.Code) -> StubResponse {
        var stub = StubResponse(0, "")
        stub.networkError = code
        return stub
    }
}

final class ScriptedTransport: Transport {
    private struct State {
        var responses: [StubResponse]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ responses: [StubResponse]) {
        state = Mutex(State(responses: responses))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: StubResponse? = state.withLock { state in
            state.requests.append(request)
            return state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        guard let next, let url = request.url else { throw ASCError.transport("script exhausted") }
        if let code = next.networkError {
            throw URLError(code)
        }
        let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)
        guard let response else { throw ASCError.transport("bad response") }
        return (Data(next.body.utf8), response)
    }
}

final class SleepRecorder: Sendable {
    private let durations = Mutex<[Duration]>([])

    var recorded: [Duration] {
        durations.withLock { $0 }
    }

    var sleeper: Sleeper {
        Sleeper { [self] duration in durations.withLock { $0.append(duration) } }
    }
}

final class MutableClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) {
        current = Mutex(start)
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var clock: TokenClock {
        TokenClock { [self] in current.withLock { $0 } }
    }
}

func makeCredentials(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> ASCCredentials {
    ASCCredentials(keyId: "KEY1234567", issuerId: "issuer-uuid", privateKeyPEM: key.pemRepresentation)
}

func makeClient(_ transport: ScriptedTransport, sleeps: SleepRecorder = SleepRecorder()) throws -> ASCClient {
    let signer = try JWTSigner(credentials: makeCredentials())
    return ASCClient(transport: transport, signer: signer, log: .silent, sleeper: sleeps.sleeper)
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    let raw = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
}
