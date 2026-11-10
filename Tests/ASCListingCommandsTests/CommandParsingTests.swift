import ArgumentParser
@testable import ASCListingCommands
import Testing

struct CommandParsingTests {
    @Test func `status parses defaults`() throws {
        let command = try #require(try ASCListing.parseAsRoot(["status"]) as? StatusCommand)
        #expect(command.common.manifest == "asc-listing.json")
        #expect(command.common.version == nil)
        #expect(command.common.verbose == false)
        #expect(command.locale.isEmpty)
    }

    @Test func `status accepts manifest version verbose and locales`() throws {
        let arguments = ["status", "--manifest", "x/m.json", "--version", "2.0", "--verbose", "--locale", "ja", "--locale", "de"]
        let command = try #require(try ASCListing.parseAsRoot(arguments) as? StatusCommand)
        #expect(command.common.manifest == "x/m.json")
        #expect(command.common.version == "2.0")
        #expect(command.common.verbose)
        #expect(command.locale == ["ja", "de"])
    }

    @Test func `metadata is a dry run by default`() throws {
        let command = try #require(try ASCListing.parseAsRoot(["metadata"]) as? MetadataCommand)
        #expect(command.write.apply == false)
        #expect(command.write.createVersion == false)
        #expect(command.write.locale.isEmpty)
    }

    @Test func `metadata takes apply create-version and repeated locale`() throws {
        let arguments = ["metadata", "--apply", "--create-version", "--locale", "fr", "--locale", "ko", "--version", "1.1"]
        let command = try #require(try ASCListing.parseAsRoot(arguments) as? MetadataCommand)
        #expect(command.write.apply)
        #expect(command.write.createVersion)
        #expect(command.write.locale == ["fr", "ko"])
        #expect(command.common.version == "1.1")
    }

    @Test func `screenshots parses its flags`() throws {
        let command = try #require(try ASCListing.parseAsRoot(["screenshots", "--apply", "--locale", "en-US"]) as? ScreenshotsCommand)
        #expect(command.write.apply)
        #expect(command.write.locale == ["en-US"])
    }

    @Test func `creative parses its flags and is a dry run by default`() throws {
        let command = try #require(try ASCListing.parseAsRoot(["creative", "--locale", "ja"]) as? CreativeCommand)
        #expect(command.write.apply == false)
        #expect(command.write.locale == ["ja"])
        let applying = try #require(try ASCListing.parseAsRoot(["creative", "--apply"]) as? CreativeCommand)
        #expect(applying.write.apply)
    }

    @Test func `publish parses its flags`() throws {
        let command = try #require(try ASCListing.parseAsRoot(["publish", "--manifest", "m.json", "--apply"]) as? PublishCommand)
        #expect(command.common.manifest == "m.json")
        #expect(command.write.apply)
    }

    @Test func `status rejects write flags`() {
        #expect(throws: (any Error).self) { try ASCListing.parseAsRoot(["status", "--apply"]) }
    }

    @Test func `unknown subcommand is a usage error`() {
        #expect(throws: (any Error).self) { try ASCListing.parseAsRoot(["upload"]) }
    }
}
