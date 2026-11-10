# Changelog

All notable changes are listed here. The project follows [Semantic Versioning](https://semver.org); until 1.0, minor versions may break the manifest format or the `ASCListingKit` API.

## Unreleased

## 0.1.0

First public release.

- `status`, `metadata`, `screenshots`, `creative` and `publish` commands; every write command is a dry run unless `--apply` is passed.
- Listing text per locale from plain-text files, with Apple's length limits checked before anything is sent.
- Screenshot upload through the App Store Connect asset library. Placement groups are resolved from Apple's reference data, and SHA-256 fingerprints skip unchanged files.
- Product page header and search results assets.
- Retries for dropped connections and rate limits, and waits of up to 15 minutes for App Store Connect to process an image.
