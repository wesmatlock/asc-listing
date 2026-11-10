import Foundation

public struct AppRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    public let bundleId: String
    public let primaryLocale: String

    public init(id: String, name: String, bundleId: String, primaryLocale: String) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.primaryLocale = primaryLocale
    }
}

public struct VersionRecord: Sendable, Equatable {
    public let id: String
    public let versionString: String
    public let state: String
    public let copyright: String?

    public init(id: String, versionString: String, state: String, copyright: String? = nil) {
        self.id = id
        self.versionString = versionString
        self.state = state
        self.copyright = copyright
    }
}

public struct AppInfoRecord: Sendable, Equatable {
    public let id: String
    public let state: String

    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}

public struct AppStoreContext: Sendable, Equatable {
    public let app: AppRecord
    public let version: VersionRecord
    public let appInfo: AppInfoRecord

    public init(app: AppRecord, version: VersionRecord, appInfo: AppInfoRecord) {
        self.app = app
        self.version = version
        self.appInfo = appInfo
    }
}

public struct LocalizationRecord: Sendable, Equatable {
    public let id: String
    public let locale: String
    public let fields: [MetadataField: String]

    public init(id: String, locale: String, fields: [MetadataField: String]) {
        self.id = id
        self.locale = locale
        self.fields = fields
    }
}

public enum EditableState {
    public static let editable: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"
    ]

    public static func isEditable(_ state: String) -> Bool {
        editable.contains(state)
    }
}

public struct VersionSummary: Sendable, Equatable {
    public let versionString: String
    public let platform: String
    public let state: String

    public init(versionString: String, platform: String, state: String) {
        self.versionString = versionString
        self.platform = platform
        self.state = state
    }
}

public struct AppStoreLookup: Sendable {
    private let client: ASCClient

    public init(client: ASCClient) {
        self.client = client
    }

    public func app(bundleId: String) async throws -> AppRecord {
        let result = try await client.getAll(
            "/v1/apps",
            query: ["filter[bundleId]": bundleId, "limit": "200"],
            resource: Resource<AppAttributes>.self
        )
        guard let found = result.data.first(where: { $0.attributes?.bundleId == bundleId }) ?? result.data.first else {
            throw ASCError.appNotFound(bundleId)
        }
        return AppRecord(
            id: found.id,
            name: found.attributes?.name ?? bundleId,
            bundleId: found.attributes?.bundleId ?? bundleId,
            primaryLocale: found.attributes?.primaryLocale ?? "en-US"
        )
    }

    public func context(manifest: ResolvedManifest, version: String, createVersion: Bool) async throws -> AppStoreContext {
        let context = try await readContext(manifest: manifest, version: version, createVersion: createVersion, requireEditable: true)
        if !EditableState.isEditable(context.version.state) {
            throw ASCError.notEditable("version \(version)", state: context.version.state)
        }
        if !EditableState.isEditable(context.appInfo.state) {
            throw ASCError.notEditable("app info", state: context.appInfo.state)
        }
        return context
    }

    public func readContext(manifest: ResolvedManifest, version: String) async throws -> AppStoreContext {
        try await readContext(manifest: manifest, version: version, createVersion: false, requireEditable: false)
    }

    public func allVersions(appID: String) async throws -> [VersionSummary] {
        let result = try await client.getAll(
            "/v1/apps/\(appID)/appStoreVersions",
            resource: Resource<AppStoreVersionAttributes>.self
        )
        return result.data.map { item in
            VersionSummary(
                versionString: item.attributes?.versionString ?? "",
                platform: item.attributes?.platform ?? "",
                state: item.attributes?.appVersionState ?? item.attributes?.appStoreState ?? "UNKNOWN"
            )
        }
    }

    public func appInfo(app: AppRecord) async throws -> AppInfoRecord {
        try await findAppInfo(app: app, requireEditable: false)
    }

    public func appInfoLocalizations(appInfoID: String) async throws -> [LocalizationRecord] {
        let result = try await client.getAll(
            "/v1/appInfos/\(appInfoID)/appInfoLocalizations",
            query: ["limit": "200"],
            resource: Resource<AppInfoLocalizationAttributes>.self
        )
        return result.data.compactMap { item in
            item.attributes?.locale.map { LocalizationRecord(id: item.id, locale: $0, fields: item.attributes?.fields ?? [:]) }
        }
    }

    public func versionLocalizations(versionID: String) async throws -> [LocalizationRecord] {
        let result = try await client.getAll(
            "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: ["limit": "200"],
            resource: Resource<VersionLocalizationAttributes>.self
        )
        return result.data.compactMap { item in
            item.attributes?.locale.map { LocalizationRecord(id: item.id, locale: $0, fields: item.attributes?.fields ?? [:]) }
        }
    }

    private func readContext(
        manifest: ResolvedManifest,
        version: String,
        createVersion: Bool,
        requireEditable: Bool
    ) async throws -> AppStoreContext {
        let app = try await app(bundleId: manifest.bundleId)
        let path = "/v1/apps/\(app.id)/appStoreVersions"
        let platform = manifest.platform
        let found = try await client.getAll(
            path,
            query: ["filter[platform]": platform.rawValue, "filter[versionString]": version],
            resource: Resource<AppStoreVersionAttributes>.self
        )
        if let match = found.data.first(where: { $0.attributes?.versionString == version }) {
            let appInfo = try await findAppInfo(app: app, requireEditable: requireEditable)
            return AppStoreContext(app: app, version: Self.record(match), appInfo: appInfo)
        }
        guard createVersion else {
            let existing = try await client.getAll(
                path,
                query: ["filter[platform]": platform.rawValue],
                resource: Resource<AppStoreVersionAttributes>.self
            )
            throw ASCError.versionNotFound(version, available: existing.data.compactMap { $0.attributes?.versionString })
        }
        let appInfo = try await findAppInfo(app: app, requireEditable: true)
        let created = try await client.send(
            .post,
            "/v1/appStoreVersions",
            body: StoreRequests.createVersion(appID: app.id, platform: platform, versionString: version),
            as: Document<Resource<AppStoreVersionAttributes>>.self
        )
        return AppStoreContext(app: app, version: Self.record(created.data), appInfo: appInfo)
    }

    private func findAppInfo(app: AppRecord, requireEditable: Bool) async throws -> AppInfoRecord {
        let result = try await client.getAll(
            "/v1/apps/\(app.id)/appInfos",
            resource: Resource<AppInfoAttributes>.self
        )
        let records = result.data.map { item in
            AppInfoRecord(id: item.id, state: item.attributes?.state ?? item.attributes?.appStoreState ?? "UNKNOWN")
        }
        if let editable = records.first(where: { EditableState.isEditable($0.state) }) {
            return editable
        }
        guard let first = records.first else {
            throw ASCError.notEditable("app info", state: "missing")
        }
        if requireEditable {
            throw ASCError.notEditable("app info", state: records.map(\.state).joined(separator: ", "))
        }
        return first
    }

    private static func record(_ resource: Resource<AppStoreVersionAttributes>) -> VersionRecord {
        let attributes = resource.attributes
        return VersionRecord(
            id: resource.id,
            versionString: attributes?.versionString ?? "",
            state: attributes?.appVersionState ?? attributes?.appStoreState ?? "UNKNOWN",
            copyright: attributes?.copyright
        )
    }
}
