import Foundation

public struct LibraryImage: Sendable, Equatable {
    public static let unusableStates: Set<String> = ["AWAITING_UPLOAD", "FAILED", "REJECTED", "ARCHIVED"]

    public let id: String
    public let state: String
    public let specID: String?
    public let category: String?

    public init(id: String, state: String, specID: String? = nil, category: String? = AssetRequests.screenshotCategory) {
        self.id = id
        self.state = state
        self.specID = specID
        self.category = category
    }

    public var isReusable: Bool {
        !Self.unusableStates.contains(state)
    }

    public var isReady: Bool {
        isReusable && state != "UPLOAD_COMPLETE"
    }

    var preference: Int {
        isReady ? 2 : isReusable ? 1 : 0
    }
}

public struct LibraryImageAttributes: Codable, Sendable {
    public var fileName: String?
    public var fileSize: Int?
    public var category: String?
    public var referenceName: String?
    public var state: String?
    public var stateDetails: JSONValue?
    public var specId: String?
    public var uploadOperations: [UploadOperation]?

    public init(fileName: String? = nil, fileSize: Int? = nil, category: String? = nil, referenceName: String? = nil) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.category = category
        self.referenceName = referenceName
    }
}

public struct UploadedAttributes: Codable, Sendable, Equatable {
    public let uploaded: Bool
}

public struct PlacementAttributes: Codable, Sendable {
    public var placementType: String?
    public var placementGroup: String?
}

public struct OrderingAttributes: Codable, Sendable {
    public let placementGroup: String
}

public enum AssetRequests {
    public static let screenshotCategory = "APP_SCREENSHOTS_AND_PREVIEWS"
    public static let creativeCategory = "CREATIVE_ASSETS"

    public static func reserveImage(
        _ file: ScreenshotFile,
        libraryID: String,
        category: String = screenshotCategory
    ) -> RequestBody<LibraryImageAttributes> {
        .create(
            type: "appAssetLibraryImages",
            attributes: LibraryImageAttributes(
                fileName: file.fileName,
                fileSize: file.byteCount,
                category: category,
                referenceName: file.fingerprint
            ),
            relationships: ["assetLibrary": .one(type: "appAssetLibraries", id: libraryID)]
        )
    }

    public static func commitImage(id: String) -> RequestBody<UploadedAttributes> {
        .update(type: "appAssetLibraryImages", id: id, attributes: UploadedAttributes(uploaded: true))
    }

    public static func createPlacement(
        group: String,
        imageID: String,
        localizationID: String,
        placementType: String = PlacementResolver.screenshotPlacementType
    ) -> RequestBody<PlacementAttributes> {
        .create(
            type: "appAssetLibraryPlacements",
            attributes: PlacementAttributes(placementType: placementType, placementGroup: group),
            relationships: [
                "image": .one(type: "appAssetLibraryImages", id: imageID),
                "appStoreVersionLocalization": .one(type: "appStoreVersionLocalizations", id: localizationID)
            ]
        )
    }

    public static func orderPlacements(group: String, placementIDs: [String], localizationID: String) -> RequestBody<OrderingAttributes> {
        .create(
            type: "appAssetLibraryPlacementOrderingRequests",
            attributes: OrderingAttributes(placementGroup: group),
            relationships: [
                "orderedPlacements": .many(type: "appAssetLibraryPlacements", ids: placementIDs),
                "appStoreVersionLocalization": .one(type: "appStoreVersionLocalizations", id: localizationID)
            ]
        )
    }
}

extension JSONValue {
    var summary: String {
        switch self {
        case .null: ""
        case let .bool(value): String(value)
        case let .number(value): String(value)
        case let .string(value): value
        case let .array(values): values.map(\.summary).filter { !$0.isEmpty }.joined(separator: "; ")
        case let .object(fields):
            fields.keys.sorted().compactMap { key in
                let text = fields[key]?.summary ?? ""
                return text.isEmpty ? nil : "\(key): \(text)"
            }.joined(separator: ", ")
        }
    }
}
