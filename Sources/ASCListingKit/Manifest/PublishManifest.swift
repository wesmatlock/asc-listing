import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case ios = "IOS"
    case macOS = "MAC_OS"
    case tvOS = "TV_OS"
    case visionOS = "VISION_OS"
}

public enum ScreenshotSets: Decodable, Sendable, Equatable {
    case mapping([String: [String]])
    case folders

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "folders" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected an object or the string \"folders\", found \"\(text)\""
                )
            }
            self = .folders
        } else {
            self = try .mapping(container.decode([String: [String]].self))
        }
    }
}

public struct ResolvedScreenshots: Sendable, Equatable {
    public let directory: URL
    public let sets: ScreenshotSets
    public let placementGroups: [String: String]
}

public struct ResolvedCreative: Sendable, Equatable {
    public let directory: URL
    public let sets: ScreenshotSets
    public let placements: [String: String]
}

public struct ResolvedManifest: Sendable, Equatable {
    public let manifestURL: URL
    public let bundleId: String
    public let platform: Platform
    public let version: String?
    public let metadataDirectory: URL?
    public let screenshots: ResolvedScreenshots?
    public let creative: ResolvedCreative?

    public init(
        manifestURL: URL,
        bundleId: String,
        platform: Platform,
        version: String?,
        metadataDirectory: URL?,
        screenshots: ResolvedScreenshots?,
        creative: ResolvedCreative? = nil
    ) {
        self.manifestURL = manifestURL
        self.bundleId = bundleId
        self.platform = platform
        self.version = version
        self.metadataDirectory = metadataDirectory
        self.screenshots = screenshots
        self.creative = creative
    }
}

public enum ManifestError: Error, CustomStringConvertible, Sendable {
    case unreadable(path: String, reason: String)
    case invalid(path: String, codingPath: String, reason: String)
    case unknownPlatform(String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            "Cannot read the manifest at \(path): \(reason)"
        case let .invalid(path, codingPath, reason):
            "Invalid manifest \(path) at \(codingPath): \(reason)"
        case let .unknownPlatform(value):
            "Unknown platform \"\(value)\". Use one of "
                + Platform.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
    }
}

public struct PublishManifest: Decodable, Sendable {
    struct Screenshots: Decodable, Sendable {
        let directory: String
        let sets: ScreenshotSets
        let placementGroups: [String: String]?
    }

    struct Creative: Decodable, Sendable {
        let directory: String
        let sets: ScreenshotSets
        let placements: [String: String]
    }

    let bundleId: String
    let platform: String
    let version: String?
    let metadata: String?
    let screenshots: Screenshots?
    let creative: Creative?

    public static func load(from url: URL) throws -> ResolvedManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        let manifest: PublishManifest
        do {
            manifest = try JSONDecoder().decode(PublishManifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError.invalid(path: url.path, codingPath: codingPath(of: error), reason: reason(of: error))
        } catch {
            throw ManifestError.invalid(path: url.path, codingPath: "(root)", reason: error.localizedDescription)
        }
        guard let platform = Platform(rawValue: manifest.platform) else {
            throw ManifestError.unknownPlatform(manifest.platform)
        }
        if let creative = manifest.creative {
            try checkPlacements(creative.placements, path: url.path)
        }
        let base = url.deletingLastPathComponent()
        return ResolvedManifest(
            manifestURL: url,
            bundleId: manifest.bundleId,
            platform: platform,
            version: manifest.version,
            metadataDirectory: manifest.metadata.map { resolve($0, against: base) },
            screenshots: manifest.screenshots.map {
                ResolvedScreenshots(
                    directory: resolve($0.directory, against: base),
                    sets: $0.sets,
                    placementGroups: $0.placementGroups ?? [:]
                )
            },
            creative: manifest.creative.map {
                ResolvedCreative(directory: resolve($0.directory, against: base), sets: $0.sets, placements: $0.placements)
            }
        )
    }

    private static func checkPlacements(_ placements: [String: String], path: String) throws {
        guard !placements.isEmpty else {
            throw ManifestError.invalid(path: path, codingPath: "creative.placements", reason: "name at least one placement type and its file")
        }
        for (type, file) in placements.sorted(by: { $0.key < $1.key }) {
            let name = file.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw ManifestError.invalid(
                    path: path,
                    codingPath: "creative.placements.\(type)",
                    reason: "expected a file name inside each set folder, found \"\(file)\""
                )
            }
        }
    }

    static func resolve(_ path: String, against base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return base.appending(path: expanded).standardized
    }

    private static func codingPath(of error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case let .typeMismatch(_, value), let .valueNotFound(_, value), let .keyNotFound(_, value), let .dataCorrupted(value):
            context = value
        @unknown default:
            return "(root)"
        }
        var keys = context.codingPath.map(\.stringValue)
        if case let .keyNotFound(key, _) = error {
            keys.append(key.stringValue)
        }
        return keys.isEmpty ? "(root)" : keys.joined(separator: ".")
    }

    private static func reason(of error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, _): "missing key \"\(key.stringValue)\""
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context): context.debugDescription
        @unknown default: "\(error)"
        }
    }
}
