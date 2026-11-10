import Foundation

public struct StatusReport: Sendable, Equatable {
    public struct LocaleStatus: Sendable, Equatable {
        public let locale: String
        public let counts: [MetadataField: Int]
        public let screenshots: [String: Int]
        public let creative: [String: Int]

        public init(locale: String, counts: [MetadataField: Int], screenshots: [String: Int], creative: [String: Int] = [:]) {
            self.locale = locale
            self.counts = counts
            self.screenshots = screenshots
            self.creative = creative
        }
    }

    public let app: AppRecord
    public let versions: [VersionSummary]
    public let requestedVersion: String?
    public let appInfoState: String
    public let locales: [LocaleStatus]

    public init(
        app: AppRecord,
        versions: [VersionSummary],
        requestedVersion: String?,
        appInfoState: String,
        locales: [LocaleStatus]
    ) {
        self.app = app
        self.versions = versions
        self.requestedVersion = requestedVersion
        self.appInfoState = appInfoState
        self.locales = locales
    }

    public static func build(session: PublishSession, version: String?, localeFilter: Set<String>? = nil) async throws -> StatusReport {
        let manifest = session.manifest
        let lookup = session.lookup
        let reader = ScreenshotStateReader(client: session.client)
        let app: AppRecord
        let appInfo: AppInfoRecord
        var versions: [VersionSummary]
        var versionID: String?
        if let version {
            let context = try await lookup.readContext(manifest: manifest, version: version)
            app = context.app
            appInfo = context.appInfo
            versionID = context.version.id
            versions = [VersionSummary(versionString: version, platform: manifest.platform.rawValue, state: context.version.state)]
        } else {
            app = try await lookup.app(bundleId: manifest.bundleId)
            appInfo = try await lookup.appInfo(app: app)
            versions = try await lookup.allVersions(appID: app.id)
        }

        let infoLocalizations = try await lookup.appInfoLocalizations(appInfoID: appInfo.id)
        var versionLocalizations: [LocalizationRecord] = []
        if let versionID {
            versionLocalizations = try await lookup.versionLocalizations(versionID: versionID)
        }

        var names = Set(infoLocalizations.map(\.locale)).union(versionLocalizations.map(\.locale))
        if let localeFilter {
            names.formIntersection(localeFilter)
        }
        var locales: [LocaleStatus] = []
        for locale in names.sorted() {
            var counts: [MetadataField: Int] = [:]
            for record in [infoLocalizations, versionLocalizations].compactMap({ $0.first { $0.locale == locale } }) {
                for (field, value) in record.fields where !value.isEmpty {
                    counts[field] = value.count
                }
            }
            var screenshots: [String: Int] = [:]
            var creative: [String: Int] = [:]
            if let localization = versionLocalizations.first(where: { $0.locale == locale }) {
                screenshots = try await reader.placementCounts(localizationID: localization.id)
                creative = try await creativeCounts(reader: reader, localizationID: localization.id)
            }
            locales.append(LocaleStatus(locale: locale, counts: counts, screenshots: screenshots, creative: creative))
        }
        return StatusReport(
            app: app,
            versions: versions,
            requestedVersion: version,
            appInfoState: appInfo.state,
            locales: locales
        )
    }

    private static func creativeCounts(reader: ScreenshotStateReader, localizationID: String) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for (_, type) in creativeColumns {
            let count = try await reader.placementCounts(localizationID: localizationID, placementType: type).values.reduce(0, +)
            if count > 0 {
                counts[type] = count
            }
        }
        return counts
    }

    static let creativeColumns = [("header", "PRODUCT_PAGE_HEADER_ASSET"), ("search", "APP_STORE_SEARCH_RESULTS_ASSET")]

    public func render() -> String {
        var lines = [
            "app:         \(app.name) (\(app.id))",
            "bundle id:   \(app.bundleId)",
            "primary:     \(app.primaryLocale)"
        ]
        if versions.isEmpty {
            lines.append("versions:    none")
        } else {
            lines.append("versions:")
            lines += versions.map { "  \($0.versionString)  \($0.platform)  \($0.state)" }
        }
        lines.append("app info:    \(appInfoState)")
        lines.append("")

        let columns: [(String, MetadataField?)] = [
            ("name", .name), ("subtitle", .subtitle), ("promo", .promotionalText), ("description", .description),
            ("keywords", .keywords), ("whatsNew", .whatsNew), ("screenshots", nil)
        ]
        var rows = [["locale"] + columns.map(\.0) + Self.creativeColumns.map(\.0)]
        for status in locales {
            let marker = status.locale == app.primaryLocale ? "*" : ""
            let cells = columns.map { _, field -> String in
                guard let field else { return Self.screenshotCell(status.screenshots) }
                return status.counts[field].map(String.init) ?? "–"
            }
            let creative = Self.creativeColumns.map { _, type in status.creative[type].map(String.init) ?? "–" }
            rows.append([status.locale + marker] + cells + creative)
        }
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        var table = rows.map { row in
            row.enumerated().map { index, cell in
                cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        }
        table.insert(String(repeating: "-", count: table[0].count), at: 1)
        lines += table
        if requestedVersion == nil {
            lines.append("")
            lines.append("version localizations and screenshots need a version: pass --version or set it in the manifest")
        }
        return lines.joined(separator: "\n")
    }

    private static func screenshotCell(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "–" }
        return counts.keys.sorted().map { "\($0): \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }
}
