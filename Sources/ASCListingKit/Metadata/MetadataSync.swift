import Foundation

public struct MetadataSync: Sendable {
    private let client: ASCClient
    private let log: PublishLog

    public init(client: ASCClient, log: PublishLog) {
        self.client = client
        self.log = log
    }

    public func apply(
        _ plan: MetadataPlan,
        context: AppStoreContext,
        appInfoLocalizations: [LocalizationRecord],
        versionLocalizations: [LocalizationRecord]
    ) async throws {
        let infoByLocale = Dictionary(appInfoLocalizations.map { ($0.locale, $0.id) }, uniquingKeysWith: { first, _ in first })
        let versionByLocale = Dictionary(versionLocalizations.map { ($0.locale, $0.id) }, uniquingKeysWith: { first, _ in first })
        for localePlan in plan.locales {
            let locale = localePlan.locale
            try await step("\(locale) app info localization") {
                try await applyAppInfo(localePlan.appInfo, locale: locale, appInfoID: context.appInfo.id, existing: infoByLocale[locale])
            }
            try await step("\(locale) version localization") {
                try await applyVersion(localePlan.version, locale: locale, versionID: context.version.id, existing: versionByLocale[locale])
            }
        }
        if let copyright = plan.copyright {
            try await step("version copyright") {
                _ = try await client.send(
                    .patch,
                    "/v1/appStoreVersions/\(context.version.id)",
                    body: StoreRequests.updateVersionCopyright(versionID: context.version.id, copyright: copyright.new),
                    as: Document<Resource<AppStoreVersionAttributes>>.self
                )
                log.info("updated copyright")
            }
        }
    }

    private func applyAppInfo(_ action: MetadataPlan.Action, locale: String, appInfoID: String, existing: String?) async throws {
        switch action {
        case let .create(fields):
            let creation = try await LocalizationWriter(client: client)
                .createAppInfoLocalization(appInfoID: appInfoID, locale: locale, fields: fields)
            log.info(creation.adopted ? "\(locale) app info already existed, updated instead" : "created \(locale) app info (\(names(fields.keys)))")
        case let .update(changes):
            guard let existing else { throw ASCError.internalInconsistency("the plan updates the \(locale) app info localization but none was read") }
            _ = try await client.send(
                .patch,
                "/v1/appInfoLocalizations/\(existing)",
                body: StoreRequests.updateAppInfoLocalization(id: existing, fields: Self.fields(changes)),
                as: Document<Resource<AppInfoLocalizationAttributes>>.self
            )
            log.info("updated \(locale) app info (\(names(changes.map(\.field))))")
        case .unchanged, .untouched:
            break
        }
    }

    private func applyVersion(_ action: MetadataPlan.Action, locale: String, versionID: String, existing: String?) async throws {
        switch action {
        case let .create(fields):
            let creation = try await LocalizationWriter(client: client)
                .createVersionLocalization(versionID: versionID, locale: locale, fields: fields)
            log.info(
                creation.adopted ? "\(locale) version already existed, updated instead" : "created \(locale) version localization (\(names(fields.keys)))"
            )
        case let .update(changes):
            guard let existing else { throw ASCError.internalInconsistency("the plan updates the \(locale) version localization but none was read") }
            _ = try await client.send(
                .patch,
                "/v1/appStoreVersionLocalizations/\(existing)",
                body: StoreRequests.updateVersionLocalization(id: existing, fields: Self.fields(changes)),
                as: Document<Resource<VersionLocalizationAttributes>>.self
            )
            log.info("updated \(locale) version localization (\(names(changes.map(\.field))))")
        case .unchanged, .untouched:
            break
        }
    }

    private func step(_ label: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw ASCError.step(label, error)
        }
    }

    private func names(_ fields: some Collection<MetadataField>) -> String {
        MetadataField.allCases.filter { fields.contains($0) }.map(\.rawValue).joined(separator: ", ")
    }

    private static func fields(_ changes: [FieldChange]) -> [MetadataField: String] {
        Dictionary(uniqueKeysWithValues: changes.map { ($0.field, $0.new) })
    }
}
