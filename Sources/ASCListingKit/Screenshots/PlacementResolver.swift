import Foundation

public struct PlacementTarget: Sendable, Equatable {
    public let group: String
    public let specID: String
    public let maxCount: Int

    public init(group: String, specID: String, maxCount: Int) {
        self.group = group
        self.specID = specID
        self.maxCount = maxCount
    }
}

public struct PlacementResolver: Sendable {
    public static let screenshotPlacementType = "APP_SCREENSHOT"
    public static let versionFeature = "APP_STORE_VERSIONS"
    public static let defaultMaxCount = 10

    public let placementType: String
    private let refData: RefData
    private let pins: [String: String]

    public init(refData: RefData, pins: [String: String], placementType: String = screenshotPlacementType) {
        self.refData = refData
        self.pins = pins
        self.placementType = placementType
    }

    public static func checkPlacementType(_ placementType: String, category: String, refData: RefData) throws {
        let accepting = refData.placementTypes.filter { ($0.acceptsAssetCategories ?? []).contains(category) }
        guard accepting.contains(where: { $0.placementTypeId == placementType }) else {
            throw ASCError.unknownPlacementType(placementType, category: category, known: accepting.map(\.placementTypeId).sorted())
        }
    }

    public func resolve(width: Int, height: Int) throws -> PlacementTarget {
        let size = "\(width)x\(height)"
        let matching = refData.imageSpecs.filter {
            $0.accepts(width: width, height: height) && ($0.compatiblePlacementTypes ?? []).contains(placementType)
        }
        let limits = groupLimits()
        let mappings = specMappings()
        var candidates: [(group: String, spec: RefData.ImageSpec)] = []
        for mapping in mappings where limits.keys.contains(mapping.placementGroupId) {
            guard !candidates.contains(where: { $0.group == mapping.placementGroupId }) else { continue }
            let specs = matching.filter { mapping.specs.contains($0.specId) }
            if let spec = specs.first(where: \.dimensions.isExact) ?? specs.first {
                candidates.append((mapping.placementGroupId, spec))
            }
        }
        let chosen: (group: String, spec: RefData.ImageSpec)
        switch candidates.count {
        case 0:
            if placementType == Self.screenshotPlacementType {
                throw ASCError.unsupportedScreenshotSize(size)
            }
            throw ASCError.unsupportedAssetSize(size, placementType: placementType, accepted: acceptedSizes(mappings))
        case 1:
            chosen = candidates[0]
        default:
            guard let pin = pins[size], let pinned = candidates.first(where: { $0.group == pin }) else {
                throw ASCError.ambiguousPlacement(size, candidates.map(\.group))
            }
            chosen = pinned
        }
        return PlacementTarget(group: chosen.group, specID: chosen.spec.specId, maxCount: limits[chosen.group] ?? Self.defaultMaxCount)
    }

    public func resolve(_ file: ScreenshotFile) throws -> PlacementTarget {
        let target = try resolve(width: file.width, height: file.height)
        try checkFormat(of: file, specID: target.specID)
        return target
    }

    public func checkFormat(of file: ScreenshotFile, specID: String) throws {
        guard let spec = refData.imageSpecs.first(where: { $0.specId == specID }),
              let accepted = spec.mimeTypes, !accepted.isEmpty,
              let mimeType = file.mimeType,
              !accepted.contains(mimeType)
        else { return }
        throw ASCError.unsupportedImageFormat(file.fileName, mimeType: mimeType, size: file.sizeKey, spec: spec.name, accepted: accepted)
    }

    private func specMappings() -> [RefData.SpecMapping] {
        refData.placementTypes.first { $0.placementTypeId == placementType }?.specMappings ?? []
    }

    private func acceptedSizes(_ mappings: [RefData.SpecMapping]) -> [String] {
        let ids = Set(mappings.flatMap(\.specs))
        return refData.imageSpecs
            .filter { ids.contains($0.specId) && ($0.compatiblePlacementTypes ?? []).contains(placementType) }
            .map { spec in
                let ratio = spec.dimensions.isExact ? nil : spec.aspectRatio
                return spec.dimensions.label + (ratio.map { " (\($0))" } ?? "")
            }
    }

    private func groupLimits() -> [String: Int] {
        let policies = refData.features
            .filter { $0.featureId == Self.versionFeature }
            .flatMap { $0.placementPolicies ?? [] }
            .filter { $0.placementType == placementType }
        var limits: [String: Int] = [:]
        for limit in policies.flatMap({ $0.groupLimits ?? [] }) {
            for group in limit.groupIds where limits[group] == nil {
                limits[group] = limit.maxCount ?? Self.defaultMaxCount
            }
        }
        return limits
    }
}

extension RefData.Dimensions {
    var label: String {
        let width = minWidth == maxWidth ? "\(minWidth)" : "\(minWidth)–\(maxWidth)"
        let height = minHeight == maxHeight ? "\(minHeight)" : "\(minHeight)–\(maxHeight)"
        return "\(width)x\(height)"
    }
}
