import Foundation

public struct FieldChange: Sendable, Equatable {
    public let field: MetadataField
    public let old: String?
    public let new: String

    public init(field: MetadataField, old: String?, new: String) {
        self.field = field
        self.old = old
        self.new = new
    }
}

public struct CopyrightChange: Sendable, Equatable {
    public let old: String?
    public let new: String

    public init(old: String?, new: String) {
        self.old = old
        self.new = new
    }
}

public struct MetadataPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case create([MetadataField: String])
        case update([FieldChange])
        case unchanged
        case untouched
    }

    public struct LocalePlan: Sendable, Equatable {
        public let locale: String
        public let appInfo: Action
        public let version: Action

        public init(locale: String, appInfo: Action, version: Action) {
            self.locale = locale
            self.appInfo = appInfo
            self.version = version
        }
    }

    public let locales: [LocalePlan]
    public let copyright: CopyrightChange?
    public let localLocales: Set<String>

    public static func make(
        local: LocalMetadata,
        appInfoLocalizations: [LocalizationRecord],
        versionLocalizations: [LocalizationRecord],
        remoteCopyright: String?,
        localeFilter: Set<String>?
    ) -> MetadataPlan {
        let remoteInfo = Dictionary(appInfoLocalizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteVersion = Dictionary(versionLocalizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
        var names = Set(local.locales.keys).union(remoteInfo.keys).union(remoteVersion.keys)
        if let localeFilter {
            names.formIntersection(localeFilter)
        }
        let plans = names.sorted().map { locale in
            LocalePlan(
                locale: locale,
                appInfo: action(scope: .appInfo, local: local.locales[locale] ?? [:], remote: remoteInfo[locale]),
                version: action(scope: .version, local: local.locales[locale] ?? [:], remote: remoteVersion[locale])
            )
        }
        var copyright: CopyrightChange?
        if localeFilter == nil, let new = local.copyright, new != remoteCopyright {
            copyright = CopyrightChange(old: remoteCopyright, new: new)
        }
        return MetadataPlan(locales: plans, copyright: copyright, localLocales: Set(local.locales.keys))
    }

    public func unmatchedLocales(_ filter: Set<String>?) -> [String] {
        (filter ?? []).subtracting(locales.map(\.locale)).sorted()
    }

    private static func action(scope: MetadataScope, local: [MetadataField: String], remote: LocalizationRecord?) -> Action {
        let wanted = local.filter { $0.key.scope == scope }
        if wanted.isEmpty {
            return .untouched
        }
        guard let remote else {
            return .create(wanted)
        }
        let changes = MetadataField.allCases.compactMap { field -> FieldChange? in
            guard let new = wanted[field], remote.fields[field] != new else { return nil }
            return FieldChange(field: field, old: remote.fields[field], new: new)
        }
        return changes.isEmpty ? .unchanged : .update(changes)
    }

    private var actions: [Action] {
        locales.flatMap { [$0.appInfo, $0.version] }
    }

    public var createCount: Int {
        actions.filter {
            if case .create = $0 {
                true
            } else {
                false
            }
        }.count
    }

    public var updateCount: Int {
        actions.filter {
            if case .update = $0 {
                true
            } else {
                false
            }
        }.count + (copyright == nil ? 0 : 1)
    }

    public var unchangedCount: Int {
        actions.filter { $0 == .unchanged }.count
    }

    public var hasChanges: Bool {
        createCount + updateCount > 0
    }

    public func render(primaryLocale: String) -> String {
        var rows = [["locale", "app info", "version"]]
        for plan in locales {
            let marker = plan.locale == primaryLocale ? "*" : ""
            rows.append([plan.locale + marker, Self.describe(plan.appInfo), Self.describe(plan.version)])
        }
        let widths = (0 ..< 3).map { column in rows.map { $0[column].count }.max() ?? 0 }
        var lines = rows.map { row in
            row.enumerated().map { index, cell in
                cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        }
        lines.insert(String(repeating: "-", count: lines[0].count), at: 1)
        if let copyright {
            lines.append("copyright: update \(Self.size(copyright.old))→\(copyright.new.count)")
        }
        lines.append("\(createCount) to create, \(updateCount) to update, \(unchangedCount) unchanged")
        if !localLocales.contains(primaryLocale) {
            lines.append("warning: no local data targets the primary locale \(primaryLocale)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ action: Action) -> String {
        switch action {
        case let .create(fields):
            let names = MetadataField.allCases.filter { fields[$0] != nil }.map(\.rawValue)
            return "create (\(names.joined(separator: ", ")))"
        case let .update(changes):
            return "update " + changes.map { "\($0.field.rawValue) \(size($0.old))→\($0.new.count)" }.joined(separator: ", ")
        case .unchanged:
            return "unchanged"
        case .untouched:
            return "untouched"
        }
    }

    private static func size(_ value: String?) -> String {
        value.map { String($0.count) } ?? "∅"
    }
}
