import Foundation

public struct PublishOptions: Sendable, Equatable {
    public let version: String
    public let createVersion: Bool
    public let apply: Bool
    public let locales: Set<String>?

    public init(version: String, createVersion: Bool = false, apply: Bool = false, locales: Set<String>? = nil) {
        self.version = version
        self.createVersion = createVersion
        self.apply = apply
        self.locales = locales
    }
}

public struct PublishRun: Sendable {
    public enum Block: Sendable, Equatable {
        case metadata
        case screenshots
        case creative
    }

    public static let dryRunNotice = "dry run: nothing changed (pass --apply to write)"

    private let session: PublishSession
    private let emit: @Sendable (String) -> Void

    public init(session: PublishSession, emit: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.session = session
        self.emit = emit
    }

    public func run(_ blocks: [Block], options: PublishOptions, skipUnconfigured: Bool = false) async throws {
        var wanted: [Block] = []
        for block in blocks {
            if isConfigured(block) {
                wanted.append(block)
            } else if skipUnconfigured {
                session.log.info("skipping \(name(block)): the manifest has no \"\(name(block))\" section")
            } else {
                throw ASCError.notConfigured(name(block))
            }
        }

        let metadata = try wanted.contains(.metadata) ? loadMetadata(options) : nil
        let screenshots = try wanted.contains(.screenshots) ? loadScreenshots(options) : nil
        let creative = try wanted.contains(.creative) ? loadCreative(options) : nil

        if let metadata {
            try await runMetadata(metadata, options: options)
        }
        if let screenshots {
            try await runScreenshots(screenshots, options: options)
        }
        if let creative {
            try await runCreative(creative, options: options)
        }
        if !options.apply, !wanted.isEmpty {
            emit(Self.dryRunNotice)
        }
    }

    private func isConfigured(_ block: Block) -> Bool {
        switch block {
        case .metadata: session.manifest.metadataDirectory != nil
        case .screenshots: session.manifest.screenshots != nil
        case .creative: session.manifest.creative != nil
        }
    }

    private func name(_ block: Block) -> String {
        switch block {
        case .metadata: "metadata"
        case .screenshots: "screenshots"
        case .creative: "creative"
        }
    }

    private func loadMetadata(_ options: PublishOptions) throws -> LocalMetadata? {
        guard let directory = session.manifest.metadataDirectory else { return nil }
        let (local, warnings) = try LocalMetadata.load(directory: directory)
        warnings.forEach(session.log.warn)
        if options.locales != nil, local.copyright != nil {
            session.log.info("note: copyright is version-wide and is only sent without --locale")
        }
        return local
    }

    private func loadScreenshots(_ options: PublishOptions) throws -> [String: [ScreenshotFile]]? {
        guard let config = session.manifest.screenshots else { return nil }
        let loaded = try LocalScreenshots.load(config, localeFilter: options.locales)
        for locale in (options.locales ?? []).subtracting(loaded.keys).sorted() {
            session.log.warn("--locale \(locale) matches no screenshot set in the manifest")
        }
        return loaded
    }

    private func loadCreative(_ options: PublishOptions) throws -> [String: [CreativeAsset]]? {
        guard let config = session.manifest.creative else { return nil }
        let loaded = try LocalCreative.load(config, localeFilter: options.locales)
        for locale in (options.locales ?? []).subtracting(loaded.keys).sorted() {
            session.log.warn("--locale \(locale) matches no creative asset set in the manifest")
        }
        return loaded
    }

    private func context(_ options: PublishOptions) async throws -> AppStoreContext? {
        if options.apply {
            return try await session.lookup.context(manifest: session.manifest, version: options.version, createVersion: options.createVersion)
        }
        do {
            let context = try await session.lookup.readContext(manifest: session.manifest, version: options.version)
            let states = [("version \(options.version)", context.version.state), ("app info", context.appInfo.state)]
            for (what, state) in states.filter({ !EditableState.isEditable($0.1) }) {
                session.log.warn("the \(what) is in state \(state); --apply would be refused")
            }
            return context
        } catch ASCError.versionNotFound where options.createVersion {
            emit("version \(options.version) does not exist yet; --apply would create it, so there is no plan to show")
            return nil
        }
    }

    private func runMetadata(_ local: LocalMetadata, options: PublishOptions) async throws {
        guard let context = try await context(options) else { return }
        let lookup = session.lookup
        let plan = try await makeMetadataPlan(local, context: context, options: options)
        for locale in plan.plan.unmatchedLocales(options.locales) {
            session.log.warn("--locale \(locale) matches no metadata locale, local or on App Store Connect")
        }
        emit(plan.plan.render(primaryLocale: context.app.primaryLocale))
        guard options.apply else { return }
        guard plan.plan.hasChanges else {
            emit("metadata: all locales unchanged")
            return
        }
        try await MetadataSync(client: session.client, log: session.log).apply(
            plan.plan,
            context: context,
            appInfoLocalizations: plan.appInfo,
            versionLocalizations: plan.version
        )
        let fresh = try await lookup.readContext(manifest: session.manifest, version: options.version)
        let replan = try await makeMetadataPlan(local, context: fresh, options: options)
        if replan.plan.hasChanges {
            let differing = replan.plan.locales.filter { $0.appInfo.differs || $0.version.differs }.map(\.locale)
            let extra = replan.plan.copyright == nil ? [] : ["copyright"]
            session.log.warn("metadata still differs after apply: " + (differing + extra).joined(separator: ", "))
        } else {
            emit("metadata: all locales unchanged after apply")
        }
    }

    private func makeMetadataPlan(
        _ local: LocalMetadata,
        context: AppStoreContext,
        options: PublishOptions
    ) async throws -> MetadataSnapshot {
        let appInfo = try await session.lookup.appInfoLocalizations(appInfoID: context.appInfo.id)
        let version = try await session.lookup.versionLocalizations(versionID: context.version.id)
        let plan = MetadataPlan.make(
            local: local,
            appInfoLocalizations: appInfo,
            versionLocalizations: version,
            remoteCopyright: context.version.copyright,
            localeFilter: options.locales
        )
        return MetadataSnapshot(plan: plan, appInfo: appInfo, version: version)
    }

    private func runScreenshots(_ desired: [String: [ScreenshotFile]], options: PublishOptions) async throws {
        guard let context = try await context(options), let config = session.manifest.screenshots else { return }
        let reader = ScreenshotStateReader(client: session.client)
        let plan = try await reader.plan(context: context, desired: desired, pins: config.placementGroups)
        emit(plan.render(primaryLocale: context.app.primaryLocale))
        guard options.apply else { return }
        guard plan.hasChanges else {
            emit("screenshots: all locales unchanged")
            return
        }
        try await sync(plan, context: context)
        let replan = try await reader.plan(context: context, desired: desired, pins: config.placementGroups)
        report(replan, block: .screenshots)
    }

    private func runCreative(_ desired: [String: [CreativeAsset]], options: PublishOptions) async throws {
        guard let context = try await context(options) else { return }
        let reader = ScreenshotStateReader(client: session.client)
        let plan = try await reader.creativePlan(context: context, desired: desired)
        emit(plan.renderCreative(primaryLocale: context.app.primaryLocale))
        guard options.apply else { return }
        guard plan.hasChanges else {
            emit("creative: all locales unchanged")
            return
        }
        try await sync(plan, context: context)
        try await report(reader.creativePlan(context: context, desired: desired), block: .creative)
    }

    private func sync(_ plan: ScreenshotPlan, context: AppStoreContext) async throws {
        let uploader = AssetUploader(client: session.client, log: session.log)
        try await ScreenshotSync(client: session.client, log: session.log, uploader: uploader).apply(plan, context: context)
    }

    private func report(_ replan: ScreenshotPlan, block: Block) {
        if replan.hasChanges {
            let differing = replan.groups.filter { $0.action == .replace }.map(\.label)
            let what = block == .creative ? "creative assets" : name(block)
            session.log.warn("\(what) still differ after apply: " + (differing + replan.localizationsToCreate).joined(separator: ", "))
        } else {
            emit("\(name(block)): all locales unchanged after apply")
        }
    }
}

private struct MetadataSnapshot {
    let plan: MetadataPlan
    let appInfo: [LocalizationRecord]
    let version: [LocalizationRecord]
}

private extension MetadataPlan.Action {
    var differs: Bool {
        switch self {
        case .create, .update: true
        case .unchanged, .untouched: false
        }
    }
}
