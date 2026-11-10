import Foundation

public struct CurrentPlacement: Sendable, Equatable {
    public let id: String
    public let imageReferenceName: String?

    public init(id: String, imageReferenceName: String?) {
        self.id = id
        self.imageReferenceName = imageReferenceName
    }
}

public struct PlacementSlot: Sendable, Hashable {
    public let placementType: String
    public let group: String

    public init(placementType: String = PlacementResolver.screenshotPlacementType, group: String) {
        self.placementType = placementType
        self.group = group
    }

    public var name: String {
        placementType == PlacementResolver.screenshotPlacementType ? group : placementType
    }
}

public struct CurrentLocaleState: Sendable, Equatable {
    public let localizationID: String?
    public let placements: [PlacementSlot: [CurrentPlacement]]

    public init(localizationID: String?, placements: [PlacementSlot: [CurrentPlacement]] = [:]) {
        self.localizationID = localizationID
        self.placements = placements
    }

    public init(localizationID: String?, groups: [String: [CurrentPlacement]]) {
        self.init(
            localizationID: localizationID,
            placements: Dictionary(uniqueKeysWithValues: groups.map { (PlacementSlot(group: $0.key), $0.value) })
        )
    }
}

public struct PlannedAsset: Sendable, Equatable {
    public let file: ScreenshotFile
    public let specID: String
    public let existing: LibraryImage?
    public let category: String

    public var needsUpload: Bool {
        !(existing?.isReusable ?? false)
    }
}

public struct CreativeAsset: Sendable, Equatable {
    public let placementType: String
    public let file: ScreenshotFile

    public init(placementType: String, file: ScreenshotFile) {
        self.placementType = placementType
        self.file = file
    }
}

public struct ScreenshotPlan: Sendable {
    public enum Action: Sendable, Equatable {
        case unchanged
        case replace
    }

    public struct GroupPlan: Sendable, Equatable {
        public let locale: String
        public let slot: PlacementSlot
        public let desired: [ScreenshotFile]
        public let current: [CurrentPlacement]
        public let action: Action

        public var group: String {
            slot.group
        }

        public var placementType: String {
            slot.placementType
        }

        public var label: String {
            "\(locale) \(slot.name)"
        }
    }

    struct ResolvedEntry {
        let file: ScreenshotFile
        let slot: PlacementSlot
        let target: PlacementTarget
    }

    public let groups: [GroupPlan]
    public let localizationsToCreate: [String]
    public let localizationIDs: [String: String]
    public let assets: [PlannedAsset]
    public let libraryID: String?
    public let category: String

    public var uploads: [ScreenshotFile] {
        assets.filter(\.needsUpload).map(\.file)
    }

    public var reuses: Int {
        assets.count { !$0.needsUpload }
    }

    public var hasChanges: Bool {
        groups.contains { $0.action == .replace } || !localizationsToCreate.isEmpty
    }

    public static func targets(
        for desired: [String: [ScreenshotFile]],
        resolver: PlacementResolver
    ) throws -> [String: [(file: ScreenshotFile, target: PlacementTarget)]] {
        var cache: [String: PlacementTarget] = [:]
        var result: [String: [(file: ScreenshotFile, target: PlacementTarget)]] = [:]
        for (locale, files) in desired {
            result[locale] = try files.map { file in
                let target: PlacementTarget
                if let known = cache[file.sizeKey] {
                    target = known
                } else {
                    target = try resolver.resolve(width: file.width, height: file.height)
                    cache[file.sizeKey] = target
                }
                try resolver.checkFormat(of: file, specID: target.specID)
                return (file, target)
            }
        }
        return result
    }

    public static func groupsByLocale(
        for desired: [String: [ScreenshotFile]],
        resolver: PlacementResolver
    ) throws -> [String: [String]] {
        try targets(for: desired, resolver: resolver).mapValues { entries in
            entries.reduce(into: [String]()) { groups, entry in
                if !groups.contains(entry.target.group) {
                    groups.append(entry.target.group)
                }
            }
        }
    }

    static func creativeEntries(for desired: [String: [CreativeAsset]], refData: RefData) throws -> [String: [ResolvedEntry]] {
        let types = Set(desired.values.flatMap { $0.map(\.placementType) })
        for type in types.sorted() {
            try PlacementResolver.checkPlacementType(type, category: AssetRequests.creativeCategory, refData: refData)
        }
        let resolvers = Dictionary(uniqueKeysWithValues: types.map { ($0, PlacementResolver(refData: refData, pins: [:], placementType: $0)) })
        var resolved: [String: [ResolvedEntry]] = [:]
        for (locale, assets) in desired {
            resolved[locale] = try assets.compactMap { asset in
                guard let resolver = resolvers[asset.placementType] else { return nil }
                let target = try resolver.resolve(asset.file)
                return ResolvedEntry(file: asset.file, slot: PlacementSlot(placementType: asset.placementType, group: target.group), target: target)
            }
        }
        return resolved
    }

    static func slotsByLocale(_ entries: [String: [ResolvedEntry]]) -> [String: [PlacementSlot]] {
        entries.mapValues { entries in
            entries.reduce(into: [PlacementSlot]()) { slots, entry in
                if !slots.contains(entry.slot) {
                    slots.append(entry.slot)
                }
            }
        }
    }

    public static func make(
        desired: [String: [ScreenshotFile]],
        resolver: PlacementResolver,
        current: [String: CurrentLocaleState],
        library: [String: LibraryImage],
        libraryID: String? = nil
    ) throws -> ScreenshotPlan {
        let entries = try targets(for: desired, resolver: resolver).mapValues { pairs in
            pairs.map { ResolvedEntry(file: $0.file, slot: PlacementSlot(placementType: resolver.placementType, group: $0.target.group), target: $0.target) }
        }
        return try make(entries: entries, category: AssetRequests.screenshotCategory, current: current, library: library, libraryID: libraryID)
    }

    public static func makeCreative(
        desired: [String: [CreativeAsset]],
        refData: RefData,
        current: [String: CurrentLocaleState],
        library: [String: LibraryImage],
        libraryID: String? = nil
    ) throws -> ScreenshotPlan {
        try make(
            entries: creativeEntries(for: desired, refData: refData),
            category: AssetRequests.creativeCategory,
            current: current,
            library: library,
            libraryID: libraryID
        )
    }

    static func make(
        entries resolved: [String: [ResolvedEntry]],
        category: String,
        current: [String: CurrentLocaleState],
        library: [String: LibraryImage],
        libraryID: String?
    ) throws -> ScreenshotPlan {
        var groups: [GroupPlan] = []
        var toCreate: [String] = []
        var localizationIDs: [String: String] = [:]
        var assets: [PlannedAsset] = []
        var seen: Set<String> = []
        for locale in resolved.keys.sorted() {
            let state = current[locale]
            if let id = state?.localizationID {
                localizationIDs[locale] = id
            } else {
                toCreate.append(locale)
            }
            let entries = resolved[locale] ?? []
            var order: [PlacementSlot] = []
            var bySlot: [PlacementSlot: [ResolvedEntry]] = [:]
            for entry in entries {
                if bySlot[entry.slot] == nil {
                    order.append(entry.slot)
                }
                bySlot[entry.slot, default: []].append(entry)
            }
            for slot in order {
                let members = bySlot[slot] ?? []
                let maxCount = members.first?.target.maxCount ?? PlacementResolver.defaultMaxCount
                guard members.count <= maxCount else {
                    throw ASCError.tooManyScreenshots(locale, slot.name, members.count, maxCount)
                }
                let files = members.map(\.file)
                let placed = state?.placements[slot] ?? []
                let unchanged = state?.localizationID != nil
                    && placed.map(\.imageReferenceName) == files.map(\.fingerprint)
                groups.append(GroupPlan(locale: locale, slot: slot, desired: files, current: placed, action: unchanged ? .unchanged : .replace))
                guard !unchanged else { continue }
                for member in members where seen.insert(member.file.fingerprint).inserted {
                    let existing = library[member.file.fingerprint].flatMap { $0.category == category ? $0 : nil }
                    assets.append(PlannedAsset(file: member.file, specID: member.target.specID, existing: existing, category: category))
                }
            }
        }
        return ScreenshotPlan(
            groups: groups,
            localizationsToCreate: toCreate,
            localizationIDs: localizationIDs,
            assets: assets,
            libraryID: libraryID,
            category: category
        )
    }

    public func render(primaryLocale: String) -> String {
        let rows = orderedGroups(primaryLocale: primaryLocale).map { plan in
            let action = switch plan.action {
            case .unchanged: "unchanged"
            case .replace: "replace (\(plan.current.count) → \(plan.desired.count))"
            }
            return [locale(plan, primaryLocale), plan.group, String(plan.desired.count), action]
        }
        return Self.table([["locale", "group", "count", "action"]] + rows, summary: summary)
    }

    public func renderCreative(primaryLocale: String) -> String {
        let rows = orderedGroups(primaryLocale: primaryLocale).map { plan in
            let action = switch plan.action {
            case .unchanged: "unchanged"
            case .replace: "replace (\(plan.current.count) → \(plan.desired.count))"
            }
            return [locale(plan, primaryLocale), plan.placementType, plan.desired.map(\.fileName).joined(separator: ", "), action]
        }
        return Self.table([["locale", "placement", "file", "action"]] + rows, summary: summary)
    }

    private var summary: String {
        "\(uploads.count) files to upload, \(reuses) already in the asset library, \(localizationsToCreate.count) localizations to create"
    }

    private func orderedGroups(primaryLocale: String) -> [GroupPlan] {
        groups.filter { $0.locale == primaryLocale } + groups.filter { $0.locale != primaryLocale }
    }

    private func locale(_ plan: GroupPlan, _ primaryLocale: String) -> String {
        plan.locale + (plan.locale == primaryLocale ? "*" : "")
    }

    private static func table(_ rows: [[String]], summary: String) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        var lines = rows.map { row in
            row.enumerated().map { index, cell in
                cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        }
        lines.insert(String(repeating: "-", count: lines[0].count), at: 1)
        lines.append(summary)
        return lines.joined(separator: "\n")
    }
}
