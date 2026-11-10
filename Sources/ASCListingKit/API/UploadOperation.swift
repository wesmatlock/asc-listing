import Foundation

public struct UploadOperation: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let method: String
    public let url: String
    public let length: Int
    public let offset: Int
    public let requestHeaders: [Header]

    public init(method: String, url: String, length: Int, offset: Int, requestHeaders: [Header] = []) {
        self.method = method
        self.url = url
        self.length = length
        self.offset = offset
        self.requestHeaders = requestHeaders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        length = try container.decode(Int.self, forKey: .length)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        requestHeaders = try container.decodeIfPresent([Header].self, forKey: .requestHeaders) ?? []
    }
}
