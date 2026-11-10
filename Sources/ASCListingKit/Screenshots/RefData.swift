import Foundation

public struct RefData: Codable, Sendable {
    public struct Feature: Codable, Sendable {
        public let featureId: String
        public let placementPolicies: [PlacementPolicy]?
    }

    public struct PlacementPolicy: Codable, Sendable {
        public let placementType: String
        public let groupLimits: [GroupLimit]?
    }

    public struct GroupLimit: Codable, Sendable {
        public let groupIds: [String]
        public let maxCount: Int?
    }

    public struct ProfileGroup: Codable, Sendable {
        public let placementProfileGroupId: String
        public let platform: String?
        public let displayClassId: String?
    }

    public struct Dimensions: Codable, Sendable {
        public let minWidth: Int
        public let maxWidth: Int
        public let minHeight: Int
        public let maxHeight: Int

        public func contains(width: Int, height: Int) -> Bool {
            minWidth <= width && width <= maxWidth && minHeight <= height && height <= maxHeight
        }

        public var isExact: Bool {
            minWidth == maxWidth && minHeight == maxHeight
        }
    }

    public struct ImageSpec: Codable, Sendable {
        public let specId: String
        public let shortName: String?
        public let dimensions: Dimensions
        public let aspectRatio: String?
        public let compatiblePlacementTypes: [String]?
        public let alphaAllowed: Bool?
        public let fileExtensions: [String]?
        public let mimeTypes: [String]?
        public let maxFileSize: Int?
        public let universalAsset: Bool?

        public var name: String {
            shortName ?? specId
        }

        public func accepts(width: Int, height: Int) -> Bool {
            guard dimensions.contains(width: width, height: height) else { return false }
            guard !dimensions.isExact, let ratio = aspectRatio.flatMap(AspectRatio.init) else { return true }
            return ratio.matches(width: width, height: height)
        }
    }

    public struct AspectRatio: Sendable, Equatable {
        public let width: Int
        public let height: Int

        public init?(_ text: String) {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            width = parts[0]
            height = parts[1]
        }

        /// A range spec's ratio is exact up to one pixel of rounding in the height.
        public func matches(width imageWidth: Int, height imageHeight: Int) -> Bool {
            abs(imageHeight * width - imageWidth * height) <= width
        }
    }

    public struct SpecMapping: Codable, Sendable {
        public let placementGroupId: String
        public let specs: [String]
    }

    public struct PlacementType: Codable, Sendable {
        public let placementTypeId: String
        public let acceptsAssetCategories: [String]?
        public let specMappings: [SpecMapping]?
    }

    public let features: [Feature]
    public let placementProfileGroups: [ProfileGroup]
    public let imageSpecs: [ImageSpec]
    public let placementTypes: [PlacementType]

    public init(features: [Feature], placementProfileGroups: [ProfileGroup], imageSpecs: [ImageSpec], placementTypes: [PlacementType]) {
        self.features = features
        self.placementProfileGroups = placementProfileGroups
        self.imageSpecs = imageSpecs
        self.placementTypes = placementTypes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decodeIfPresent([Feature].self, forKey: .features) ?? []
        placementProfileGroups = try container.decodeIfPresent([ProfileGroup].self, forKey: .placementProfileGroups) ?? []
        imageSpecs = try container.decodeIfPresent([ImageSpec].self, forKey: .imageSpecs) ?? []
        placementTypes = try container.decodeIfPresent([PlacementType].self, forKey: .placementTypes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case features, placementProfileGroups, imageSpecs, placementTypes
    }

    public static func decode(response data: Data) throws -> RefData {
        let document: CollectionDocument<Resource<RefData>>
        do {
            document = try JSONDecoder().decode(CollectionDocument<Resource<RefData>>.self, from: data)
        } catch {
            throw ASCError.decoding("asset library reference data: \(error)")
        }
        return try first(of: document)
    }

    static func first(of document: CollectionDocument<Resource<RefData>>) throws -> RefData {
        guard let attributes = document.data.first?.attributes else {
            throw ASCError.decoding("the asset library reference data is empty")
        }
        return attributes
    }
}
