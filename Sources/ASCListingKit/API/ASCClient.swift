import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct Sleeper: Sendable {
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    public static let system = Sleeper { try await Task.sleep(for: $0) }
}

public struct ASCClient: Sendable {
    public static let baseURL = "https://api.appstoreconnect.apple.com"
    public static let maxRetries = 4

    private let transport: any Transport
    private let signer: JWTSigner
    private let log: PublishLog
    private let sleeper: Sleeper

    public init(
        transport: any Transport = URLSessionTransport(),
        signer: JWTSigner,
        log: PublishLog = PublishLog(),
        sleeper: Sleeper = .system
    ) {
        self.transport = transport
        self.signer = signer
        self.log = log
        self.sleeper = sleeper
    }

    public func get<A: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        as _: A.Type
    ) async throws -> A {
        let data = try await perform(method: .get, url: url(path: path, query: query))
        return try decode(A.self, from: data)
    }

    public func getAll<R: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        resource _: R.Type
    ) async throws -> (data: [R], included: [IncludedResource]) {
        var items: [R] = []
        var included: [IncludedResource] = []
        var next: URL? = try url(path: path, query: query)
        while let current = next {
            let page = try await decode(CollectionDocument<R>.self, from: perform(method: .get, url: current))
            items += page.data
            included += page.included ?? []
            next = try page.links?.next.map { try absoluteURL($0) }
        }
        return (items, included)
    }

    public func send<A: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        body: some Encodable & Sendable,
        as _: A.Type
    ) async throws -> A {
        let data = try await perform(method: method, url: url(path: path, query: [:]), body: encode(body))
        return try decode(A.self, from: data)
    }

    public func send(_ method: HTTPMethod, _ path: String, body: some Encodable & Sendable) async throws {
        _ = try await perform(method: method, url: url(path: path, query: [:]), body: encode(body))
    }

    public func delete(_ path: String) async throws {
        _ = try await perform(method: .delete, url: url(path: path, query: [:]))
    }

    public func upload(_ operation: UploadOperation, bytes: Data) async throws {
        guard let url = URL(string: operation.url) else { throw ASCError.invalidURL(operation.url) }
        guard operation.offset >= 0, operation.length >= 0, operation.offset + operation.length <= bytes.count else {
            throw ASCError.invalidUploadOperation(
                "range \(operation.offset)..<\(operation.offset + operation.length) is outside \(bytes.count) bytes"
            )
        }
        let start = bytes.startIndex + operation.offset
        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        for header in operation.requestHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = Data(bytes[start ..< start + operation.length])
        _ = try await perform(request, authorized: false)
    }

    private func perform(method: HTTPMethod, url: URL, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await perform(request, authorized: true)
    }

    private func perform(_ request: URLRequest, authorized: Bool) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let replayable = !(authorized && method == HTTPMethod.post.rawValue && Self.singleShotPaths.contains(path))
        var attempt = 0
        while true {
            var attemptRequest = request
            if authorized {
                try await attemptRequest.setValue("Bearer \(signer.token())", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try await send(attemptRequest, attempt: attempt, replayable: replayable) else {
                attempt += 1
                continue
            }
            let status = response.statusCode
            log.debug("\(method) \(path) -> \(status)")
            if (200 ..< 300).contains(status) {
                return data
            }
            if method == HTTPMethod.delete.rawValue, status == 404, attempt > 0 {
                return Data()
            }
            if status == 429 || (status >= 500 && replayable), attempt < Self.maxRetries {
                let wait = delay(for: response, attempt: attempt)
                if status == 429 {
                    log.warn("rate limited, waiting \(Self.wholeSeconds(wait))s")
                }
                try await sleeper.sleep(wait)
                attempt += 1
                continue
            }
            throw authorized
                ? ASCError.api(status: status, errors: Self.errorItems(from: data))
                : ASCError.uploadFailed(status: status, response: Self.responseSummary(data))
        }
    }

    private func send(_ request: URLRequest, attempt: Int, replayable: Bool) async throws -> (Data, HTTPURLResponse)? {
        do {
            return try await transport.send(request)
        } catch let error as URLError where Self.transientNetworkErrors.contains(error.code) {
            guard attempt < Self.maxRetries, replayable || Self.unsentNetworkErrors.contains(error.code) else {
                throw ASCError.transport(error.localizedDescription)
            }
            let wait = Self.backoff(attempt: attempt)
            log.warn("\(request.httpMethod ?? "GET") \(request.url?.path ?? ""): \(error.localizedDescription), retrying in \(Self.wholeSeconds(wait))s")
            try await sleeper.sleep(wait)
            return nil
        } catch let error as ASCError {
            throw error
        } catch {
            throw ASCError.transport(error.localizedDescription)
        }
    }

    static let maxRetryAfter: Duration = .seconds(60)

    private static let singleShotPaths: Set<String> = [
        "/v1/appAssetLibraryPlacements",
        "/v1/appAssetLibraryPlacementOrderingRequests"
    ]

    private static let transientNetworkErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed
    ]

    private static let unsentNetworkErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]

    private func delay(for response: HTTPURLResponse, attempt: Int) -> Duration {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header), seconds >= 0 {
            return min(.seconds(seconds), Self.maxRetryAfter)
        }
        return Self.backoff(attempt: attempt)
    }

    private static func backoff(attempt: Int) -> Duration {
        .seconds(1 << attempt)
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) + (attoseconds > 0 ? 1 : 0)
    }

    static func responseSummary(_ data: Data) -> String? {
        let messages = errorItems(from: data).map(\.message).filter { !$0.isEmpty }
        if !messages.isEmpty {
            return messages.joined(separator: "; ")
        }
        let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }

    private struct ErrorBody: Decodable {
        let errors: [APIErrorItem]
    }

    private static func errorItems(from data: Data) -> [APIErrorItem] {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.errors ?? []
    }

    private func encode(_ body: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw ASCError.decoding("cannot encode the request body: \(error)")
        }
    }

    private func decode<A: Decodable>(_: A.Type, from data: Data) throws -> A {
        do {
            return try JSONDecoder().decode(A.self, from: data)
        } catch {
            throw ASCError.decoding(String(describing: error))
        }
    }

    private func absoluteURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw ASCError.invalidURL(value) }
        return url
    }

    private func url(path: String, query: [String: String]) throws -> URL {
        let full = path.hasPrefix("http") ? path : Self.baseURL + path
        guard var components = URLComponents(string: full) else { throw ASCError.invalidURL(path) }
        if !query.isEmpty {
            components.percentEncodedQuery = query.keys.sorted()
                .map { key in "\(Self.encode(key))=\(Self.encode(query[key] ?? ""))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw ASCError.invalidURL(path) }
        return url
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~,")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
