import ArgumentParser
import ASCListingKit
import Foundation

func reportingFailures(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as ValidationError {
        throw error
    } catch let error as ExitCode {
        throw error
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        throw ExitCode.failure
    }
}

func publishOptions(session: PublishSession, common: CommonOptions, write: WriteOptions) throws -> PublishOptions {
    let version: String
    do {
        version = try session.resolveVersion(flag: common.version)
    } catch {
        throw ValidationError("\(error)")
    }
    return PublishOptions(
        version: version,
        createVersion: write.createVersion,
        apply: write.apply,
        locales: write.locale.isEmpty ? nil : Set(write.locale)
    )
}

public struct StatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the app, version, localizations, screenshots and creative assets on App Store Connect (read-only)."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "Only show this App Store Connect locale. Repeatable.")
    var locale: [String] = []

    public init() {}

    public func run() async throws {
        try await reportingFailures {
            let session = try PublishSession.make(manifestPath: common.manifest, verbose: common.verbose)
            let version = common.version ?? session.manifest.version
            let report = try await StatusReport.build(
                session: session,
                version: version,
                localeFilter: locale.isEmpty ? nil : Set(locale)
            )
            print(report.render())
        }
    }
}

struct WriteCommandBody {
    let blocks: [PublishRun.Block]
    let skipUnconfigured: Bool

    func run(common: CommonOptions, write: WriteOptions) async throws {
        try await reportingFailures {
            let session = try PublishSession.make(manifestPath: common.manifest, verbose: common.verbose)
            let options = try publishOptions(session: session, common: common, write: write)
            try await PublishRun(session: session).run(blocks, options: options, skipUnconfigured: skipUnconfigured)
        }
    }
}

public struct MetadataCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Plan, and with --apply write, the listing text for each locale."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var write: WriteOptions

    public init() {}

    public func run() async throws {
        try await WriteCommandBody(blocks: [.metadata], skipUnconfigured: false).run(common: common, write: write)
    }
}

public struct ScreenshotsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshots",
        abstract: "Plan, and with --apply upload and place, the screenshots for each locale."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var write: WriteOptions

    public init() {}

    public func run() async throws {
        try await WriteCommandBody(blocks: [.screenshots], skipUnconfigured: false).run(common: common, write: write)
    }
}

public struct CreativeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "creative",
        abstract: "Plan, and with --apply upload and place, the product page header and search results assets for each locale."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var write: WriteOptions

    public init() {}

    public func run() async throws {
        try await WriteCommandBody(blocks: [.creative], skipUnconfigured: false).run(common: common, write: write)
    }
}

public struct PublishCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Run metadata, then screenshots, then creative assets, for whatever the manifest configures."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var write: WriteOptions

    public init() {}

    public func run() async throws {
        try await WriteCommandBody(blocks: [.metadata, .screenshots, .creative], skipUnconfigured: true).run(common: common, write: write)
    }
}
