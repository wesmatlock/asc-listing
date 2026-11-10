import Foundation

public struct LocalizationCreation: Sendable, Equatable {
    public let id: String
    public let adopted: Bool
}

public struct LocalizationWriter: Sendable {
    private let client: ASCClient

    public init(client: ASCClient) {
        self.client = client
    }

    public func createAppInfoLocalization(
        appInfoID: String,
        locale: String,
        fields: [MetadataField: String]
    ) async throws -> LocalizationCreation {
        try await createOrAdopt(
            locale: locale,
            fields: fields,
            create: {
                try await client.send(
                    .post,
                    "/v1/appInfoLocalizations",
                    body: StoreRequests.createAppInfoLocalization(appInfoID: appInfoID, locale: locale, fields: fields),
                    as: Document<Resource<AppInfoLocalizationAttributes>>.self
                ).data.id
            },
            existing: { try await AppStoreLookup(client: client).appInfoLocalizations(appInfoID: appInfoID) },
            update: { id, differing in
                _ = try await client.send(
                    .patch,
                    "/v1/appInfoLocalizations/\(id)",
                    body: StoreRequests.updateAppInfoLocalization(id: id, fields: differing),
                    as: Document<Resource<AppInfoLocalizationAttributes>>.self
                )
            }
        )
    }

    public func createVersionLocalization(
        versionID: String,
        locale: String,
        fields: [MetadataField: String]
    ) async throws -> LocalizationCreation {
        try await createOrAdopt(
            locale: locale,
            fields: fields,
            create: {
                try await client.send(
                    .post,
                    "/v1/appStoreVersionLocalizations",
                    body: StoreRequests.createVersionLocalization(versionID: versionID, locale: locale, fields: fields),
                    as: Document<Resource<VersionLocalizationAttributes>>.self
                ).data.id
            },
            existing: { try await AppStoreLookup(client: client).versionLocalizations(versionID: versionID) },
            update: { id, differing in
                _ = try await client.send(
                    .patch,
                    "/v1/appStoreVersionLocalizations/\(id)",
                    body: StoreRequests.updateVersionLocalization(id: id, fields: differing),
                    as: Document<Resource<VersionLocalizationAttributes>>.self
                )
            }
        )
    }

    private func createOrAdopt(
        locale: String,
        fields: [MetadataField: String],
        create: () async throws -> String,
        existing: () async throws -> [LocalizationRecord],
        update: (String, [MetadataField: String]) async throws -> Void
    ) async throws -> LocalizationCreation {
        do {
            return try await LocalizationCreation(id: create(), adopted: false)
        } catch let error as ASCError where error.isConflict {
            guard let record = try await existing().first(where: { $0.locale == locale }) else { throw error }
            let differing = fields.filter { record.fields[$0.key] != $0.value }
            if !differing.isEmpty {
                try await update(record.id, differing)
            }
            return LocalizationCreation(id: record.id, adopted: true)
        }
    }
}

extension ASCError {
    var isConflict: Bool {
        if case let .api(status, _) = self {
            return status == 409
        }
        return false
    }
}
