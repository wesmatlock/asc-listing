import ArgumentParser

public struct ASCListing: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "asc-listing",
        abstract: "Upload App Store listing text, screenshots and creative assets through the App Store Connect API.",
        subcommands: [StatusCommand.self, MetadataCommand.self, ScreenshotsCommand.self, CreativeCommand.self, PublishCommand.self]
    )

    public init() {}
}
