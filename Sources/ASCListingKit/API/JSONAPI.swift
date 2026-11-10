import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}

public struct ResourceIdentifier: Codable, Sendable, Equatable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

public enum RelationshipData: Codable, Sendable, Equatable {
    case none
    case one(ResourceIdentifier)
    case many([ResourceIdentifier])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let many = try? container.decode([ResourceIdentifier].self) {
            self = .many(many)
        } else {
            self = try .one(container.decode(ResourceIdentifier.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encodeNil()
        case let .one(value): try container.encode(value)
        case let .many(value): try container.encode(value)
        }
    }
}

public struct Relationship: Codable, Sendable, Equatable {
    public let data: RelationshipData?

    public init(data: RelationshipData?) {
        self.data = data
    }

    public static func one(type: String, id: String) -> Relationship {
        Relationship(data: .one(ResourceIdentifier(type: type, id: id)))
    }

    public static func many(type: String, ids: [String]) -> Relationship {
        Relationship(data: .many(ids.map { ResourceIdentifier(type: type, id: $0) }))
    }
}

public struct Resource<Attributes: Codable & Sendable>: Codable, Sendable {
    public let type: String
    public let id: String
    public let attributes: Attributes?
    public let relationships: [String: Relationship]?

    public init(type: String, id: String, attributes: Attributes? = nil, relationships: [String: Relationship]? = nil) {
        self.type = type
        self.id = id
        self.attributes = attributes
        self.relationships = relationships
    }
}

public struct IncludedResource: Codable, Sendable, Equatable {
    public let type: String
    public let id: String
    public let attributes: [String: JSONValue]

    public init(type: String, id: String, attributes: [String: JSONValue] = [:]) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, attributes
    }
}

public struct Links: Codable, Sendable, Equatable {
    public let next: String?
}

public struct Paging: Codable, Sendable, Equatable {
    public let total: Int?
    public let limit: Int?
}

public struct DocumentMeta: Codable, Sendable, Equatable {
    public let paging: Paging?
}

public struct Document<Resource: Decodable & Sendable>: Decodable, Sendable {
    public let data: Resource
    public let included: [IncludedResource]?
    public let meta: DocumentMeta?
}

public struct CollectionDocument<Resource: Decodable & Sendable>: Decodable, Sendable {
    public let data: [Resource]
    public let included: [IncludedResource]?
    public let links: Links?
    public let meta: DocumentMeta?
}

public struct EmptyAttributes: Codable, Sendable, Equatable {}

public struct RequestResource<Attributes: Encodable & Sendable>: Encodable, Sendable {
    public let type: String
    public let id: String?
    public let attributes: Attributes?
    public let relationships: [String: Relationship]?

    public init(type: String, id: String? = nil, attributes: Attributes? = nil, relationships: [String: Relationship]? = nil) {
        self.type = type
        self.id = id
        self.attributes = attributes
        self.relationships = relationships
    }
}

public struct RequestBody<Attributes: Encodable & Sendable>: Encodable, Sendable {
    public let data: RequestResource<Attributes>

    public init(data: RequestResource<Attributes>) {
        self.data = data
    }

    public static func create(
        type: String,
        attributes: Attributes? = nil,
        relationships: [String: Relationship]? = nil
    ) -> RequestBody {
        RequestBody(data: RequestResource(type: type, attributes: attributes, relationships: relationships))
    }

    public static func update(type: String, id: String, attributes: Attributes) -> RequestBody {
        RequestBody(data: RequestResource(type: type, id: id, attributes: attributes))
    }
}
