import Foundation

public struct ScreenshotState: Sendable {
    public let refData: RefData
    public let libraryID: String
    public let library: [String: LibraryImage]
    public let current: [String: CurrentLocaleState]
}

public struct ScreenshotStateReader: Sendable {
    private let client: ASCClient

    public init(client: ASCClient) {
        self.client = client
    }

    public func read(
        context: AppStoreContext,
        desired: [String: [ScreenshotFile]],
        pins: [String: String]
    ) async throws -> ScreenshotState {
        let refData = try await refData()
        let groups = try ScreenshotPlan.groupsByLocale(for: desired, resolver: PlacementResolver(refData: refData, pins: pins))
        let slots = groups.mapValues { $0.map { PlacementSlot(group: $0) } }
        return try await state(context: context, refData: refData, slots: slots, category: AssetRequests.screenshotCategory)
    }

    public func plan(
        context: AppStoreContext,
        desired: [String: [ScreenshotFile]],
        pins: [String: String]
    ) async throws -> ScreenshotPlan {
        let state = try await read(context: context, desired: desired, pins: pins)
        return try ScreenshotPlan.make(
            desired: desired,
            resolver: PlacementResolver(refData: state.refData, pins: pins),
            current: state.current,
            library: state.library,
            libraryID: state.libraryID
        )
    }

    public func creativePlan(context: AppStoreContext, desired: [String: [CreativeAsset]]) async throws -> ScreenshotPlan {
        let refData = try await refData()
        let entries = try ScreenshotPlan.creativeEntries(for: desired, refData: refData)
        let state = try await state(
            context: context,
            refData: refData,
            slots: ScreenshotPlan.slotsByLocale(entries),
            category: AssetRequests.creativeCategory
        )
        return try ScreenshotPlan.make(
            entries: entries,
            category: AssetRequests.creativeCategory,
            current: state.current,
            library: state.library,
            libraryID: state.libraryID
        )
    }

    private func state(
        context: AppStoreContext,
        refData: RefData,
        slots: [String: [PlacementSlot]],
        category: String
    ) async throws -> ScreenshotState {
        let libraryID = try await libraryID(appID: context.app.id)
        let library = try await libraryImages(libraryID: libraryID, category: category)
        let current = try await currentState(versionID: context.version.id, slots: slots)
        return ScreenshotState(refData: refData, libraryID: libraryID, library: library, current: current)
    }

    public func refData() async throws -> RefData {
        try await RefData.first(of: client.get(
            "/v1/appAssetLibraryRefData",
            as: CollectionDocument<Resource<RefData>>.self
        ))
    }

    public func libraryID(appID: String) async throws -> String {
        try await client.get("/v1/apps/\(appID)/assetLibrary", as: Document<Resource<EmptyAttributes>>.self).data.id
    }

    public func libraryImages(
        libraryID: String,
        category: String = AssetRequests.screenshotCategory
    ) async throws -> [String: LibraryImage] {
        let result = try await client.getAll(
            "/v1/appAssetLibraries/\(libraryID)/images",
            query: ["limit": "200"],
            resource: Resource<LibraryImageAttributes>.self
        )
        var images: [String: LibraryImage] = [:]
        for item in result.data {
            guard let name = item.attributes?.referenceName, item.attributes?.category == category else { continue }
            let image = LibraryImage(id: item.id, state: item.attributes?.state ?? "UNKNOWN", specID: item.attributes?.specId, category: category)
            if let known = images[name], known.preference >= image.preference {
                continue
            }
            images[name] = image
        }
        return images
    }

    public func currentState(versionID: String, slots: [String: [PlacementSlot]]) async throws -> [String: CurrentLocaleState] {
        let localizations = try await AppStoreLookup(client: client).versionLocalizations(versionID: versionID)
        var result: [String: CurrentLocaleState] = [:]
        for locale in slots.keys.sorted() {
            guard let localization = localizations.first(where: { $0.locale == locale }) else {
                result[locale] = CurrentLocaleState(localizationID: nil)
                continue
            }
            var placed: [PlacementSlot: [CurrentPlacement]] = [:]
            for slot in slots[locale] ?? [] {
                placed[slot] = try await placements(localizationID: localization.id, group: slot.group, placementType: slot.placementType)
            }
            result[locale] = CurrentLocaleState(localizationID: localization.id, placements: placed)
        }
        return result
    }

    public func placements(
        localizationID: String,
        group: String,
        placementType: String = PlacementResolver.screenshotPlacementType
    ) async throws -> [CurrentPlacement] {
        let result = try await client.getAll(
            "/v1/appStoreVersionLocalizations/\(localizationID)/placements",
            query: [
                "filter[placementType]": placementType,
                "filter[placementGroup]": group,
                "sort": "placementGroupPosition",
                "include": "image"
            ],
            resource: Resource<PlacementAttributes>.self
        )
        let names = Dictionary(
            result.included
                .filter { $0.type == "appAssetLibraryImages" }
                .compactMap { item in item.attributes["referenceName"]?.stringValue.map { (item.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return result.data.map { placement in
            var imageID: String?
            if case let .one(identifier) = placement.relationships?["image"]?.data {
                imageID = identifier.id
            }
            return CurrentPlacement(id: placement.id, imageReferenceName: imageID.flatMap { names[$0] })
        }
    }

    public func placementCounts(
        localizationID: String,
        placementType: String = PlacementResolver.screenshotPlacementType
    ) async throws -> [String: Int] {
        let result = try await client.getAll(
            "/v1/appStoreVersionLocalizations/\(localizationID)/placements",
            query: ["filter[placementType]": placementType],
            resource: Resource<PlacementAttributes>.self
        )
        return result.data.reduce(into: [:]) { counts, placement in
            if let group = placement.attributes?.placementGroup {
                counts[group, default: 0] += 1
            }
        }
    }
}
