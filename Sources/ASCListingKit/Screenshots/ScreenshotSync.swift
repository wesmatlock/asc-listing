import Foundation

public struct ScreenshotSync: Sendable {
    public static let maxConcurrentUploads = 4
    public static let orderReads = 5

    private let client: ASCClient
    private let log: PublishLog
    private let uploader: AssetUploader
    private let sleeper: Sleeper
    private let orderReadInterval: Duration

    public init(
        client: ASCClient,
        log: PublishLog,
        uploader: AssetUploader,
        sleeper: Sleeper = .system,
        orderReadInterval: Duration = .seconds(2)
    ) {
        self.client = client
        self.log = log
        self.uploader = uploader
        self.sleeper = sleeper
        self.orderReadInterval = orderReadInterval
    }

    public func apply(_ plan: ScreenshotPlan, context: AppStoreContext) async throws {
        var localizationIDs = plan.localizationIDs
        var adopted: Set<String> = []
        for locale in plan.localizationsToCreate {
            try await step("\(locale) version localization") {
                let creation = try await LocalizationWriter(client: client)
                    .createVersionLocalization(versionID: context.version.id, locale: locale, fields: [:])
                localizationIDs[locale] = creation.id
                if creation.adopted {
                    adopted.insert(locale)
                }
                log.info(creation.adopted ? "\(locale) version localization already existed" : "created \(locale) version localization")
            }
        }

        let imageIDs = try await prepareAssets(plan, appID: context.app.id)

        var failed: [String] = []
        for group in plan.groups where group.action == .replace {
            let label = group.label
            do {
                guard let localizationID = localizationIDs[group.locale] else {
                    throw ASCError.internalInconsistency("no version localization id for \(group.locale)")
                }
                let current = if adopted.contains(group.locale) {
                    try await ScreenshotStateReader(client: client)
                        .placements(localizationID: localizationID, group: group.group, placementType: group.placementType)
                } else {
                    group.current
                }
                try await replace(group, current: current, localizationID: localizationID, imageIDs: imageIDs)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(label)
                log.info("\(label): FAILED — \(error)")
            }
        }
        if !failed.isEmpty {
            throw plan.category == AssetRequests.screenshotCategory
                ? ASCError.screenshotGroupsFailed(failed)
                : ASCError.creativePlacementsFailed(failed)
        }
    }

    private func prepareAssets(_ plan: ScreenshotPlan, appID: String) async throws -> [String: String] {
        guard !plan.assets.isEmpty else { return [:] }
        let libraryID: String = if let known = plan.libraryID {
            known
        } else {
            try await ScreenshotStateReader(client: client).libraryID(appID: appID)
        }
        return try await withThrowingTaskGroup(of: (String, String).self) { group in
            var pending = plan.assets.makeIterator()
            var imageIDs: [String: String] = [:]
            func addNext() -> Bool {
                guard let asset = pending.next() else { return false }
                group.addTask { [uploader] in
                    do {
                        let id = try await uploader.ensureReady(
                            asset.file,
                            libraryID: libraryID,
                            existing: asset.existing,
                            expectedSpecID: asset.specID,
                            category: asset.category
                        )
                        return (asset.file.fingerprint, id)
                    } catch {
                        throw ASCError.step(asset.file.fileName, error)
                    }
                }
                return true
            }
            var running = 0
            while running < Self.maxConcurrentUploads, addNext() {
                running += 1
            }
            while let (fingerprint, id) = try await group.next() {
                imageIDs[fingerprint] = id
                _ = addNext()
            }
            return imageIDs
        }
    }

    private func replace(
        _ group: ScreenshotPlan.GroupPlan,
        current: [CurrentPlacement],
        localizationID: String,
        imageIDs: [String: String]
    ) async throws {
        if current.map(\.imageReferenceName) == group.desired.map(\.fingerprint) {
            log.info("\(group.label): already in place")
            return
        }
        for placement in current {
            try await client.delete("/v1/appAssetLibraryPlacements/\(placement.id)")
        }
        var placementIDs: [String] = []
        for file in group.desired {
            guard let imageID = imageIDs[file.fingerprint] else {
                throw ASCError.internalInconsistency("no uploaded image id for \(file.fileName)")
            }
            let created = try await client.send(
                .post,
                "/v1/appAssetLibraryPlacements",
                body: AssetRequests.createPlacement(
                    group: group.group,
                    imageID: imageID,
                    localizationID: localizationID,
                    placementType: group.placementType
                ),
                as: Document<Resource<PlacementAttributes>>.self
            )
            placementIDs.append(created.data.id)
        }
        if placementIDs.count > 1 {
            try await client.send(
                .post,
                "/v1/appAssetLibraryPlacementOrderingRequests",
                body: AssetRequests.orderPlacements(group: group.group, placementIDs: placementIDs, localizationID: localizationID)
            )
        }
        let placed = try await verifiedPlacementCount(group, localizationID: localizationID)
        log.info("\(group.label): \(placed) placed")
    }

    private func verifiedPlacementCount(_ group: ScreenshotPlan.GroupPlan, localizationID: String) async throws -> Int {
        let desired = group.desired.map(\.fingerprint)
        let reader = ScreenshotStateReader(client: client)
        for read in 1 ... Self.orderReads {
            let placed = try await reader.placements(localizationID: localizationID, group: group.group, placementType: group.placementType)
            if placed.map(\.imageReferenceName) == desired {
                return placed.count
            }
            if read < Self.orderReads {
                try await sleeper.sleep(orderReadInterval)
            }
        }
        if desired.count > 1 {
            throw ASCError.orderMismatch(group.locale, group.slot.name)
        }
        throw ASCError.placementNotVisible(group.locale, group.slot.name)
    }

    private func step(_ label: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw ASCError.step(label, error)
        }
    }
}
