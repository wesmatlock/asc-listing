import ArgumentParser

struct CommonOptions: ParsableArguments {
    @Option(help: "Path to the manifest.")
    var manifest = "asc-listing.json"

    @Option(help: "Version string; defaults to the manifest's version.")
    var version: String?

    @Flag(help: "Log each request as METHOD path -> status.")
    var verbose = false
}

struct WriteOptions: ParsableArguments {
    @Flag(help: "Write the changes. Without it the command only prints the plan.")
    var apply = false

    @Flag(help: "Create the version when it does not exist.")
    var createVersion = false

    @Option(help: "Only act on this App Store Connect locale. Repeatable.")
    var locale: [String] = []
}
