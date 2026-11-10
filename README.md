# asc-listing

A command-line tool that pushes an app's App Store listing text, screenshots, and product page header and search results assets to App Store Connect, per localization, through the official API. One manifest per app, plain-text files for the listing, PNG files for the images.

> [!WARNING]
> With `--apply`, this tool changes your live App Store Connect listing. Every write command is a dry run without it; read the plan first.

## Why another App Store Connect tool

- **Product page header and search results images.** Both are uploaded and placed per locale through the App Store Connect asset library, alongside the screenshots.
- **Idempotent.** Each image's SHA-256 is stored as its reference name, so unchanged files are never uploaded again and a re-run after a partial failure redoes only what failed.
- **No device table to maintain.** Screenshot placement groups and creative sizes are resolved from Apple's own reference data at run time.
- **Dry run by default.** The plan is printed and nothing is written until you pass `--apply`. After applying, the tool re-reads App Store Connect to confirm the result.
- **Small.** One Swift package with a single dependency (`swift-argument-parser`). No Ruby and no Xcode project.

If you already run fastlane `deliver` and it covers what you upload, it remains a fine choice.

## Install

Requires macOS 26 or later. Release builds are universal (Apple silicon and Intel), signed with Developer ID and notarized by Apple.

### Homebrew

```sh
brew install wesmatlock/tap/asc-listing
```

Naming the tap in full trusts this one formula for Homebrew's [tap trust](https://docs.brew.sh/Tap-Trust); nothing else in the tap is trusted. `brew upgrade asc-listing` picks up new releases.

### Installer package

Download `asc-listing-<version>.pkg` from the [latest release](https://github.com/wesmatlock/asc-listing/releases/latest) and open it. It installs `/usr/local/bin/asc-listing`, which is on the default `PATH`. The notarization ticket is stapled, so it installs without a network connection. To remove it:

```sh
sudo rm /usr/local/bin/asc-listing
sudo pkgutil --forget net.insoc.asc-listing
```

### Zip

The release also has `asc-listing-<version>-macos-universal.zip` and a `.sha256` file for each download. Unzip it and put `asc-listing` anywhere on your `PATH`. A bare command-line binary cannot carry a stapled ticket, so Gatekeeper checks its notarization online the first time it runs.

### From source

```sh
git clone https://github.com/wesmatlock/asc-listing.git
cd asc-listing
make install     # builds release, links ~/.local/bin/asc-listing
make uninstall
make test
```

Requires a Swift 6.2 toolchain. Make sure `~/.local/bin` is on your `PATH`. `make install` links the binary inside this clone, so keep the clone where it is.

The `ASCListingKit` library product is usable on its own, but its API is not stable before 1.0.

## Credentials

Create an App Store Connect API key (Users and Access, Integrations) with the App Manager or Admin role. Either put this in `~/.appstoreconnect/config.json`:

```json
{ "keyId": "ABC123DEFG", "issuerId": "00000000-0000-0000-0000-000000000000", "p8Path": "~/.appstoreconnect/AuthKey_ABC123DEFG.p8" }
```

or set all three of `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_P8_PATH`. The environment wins when all three are present. The key, token and ids are never printed.

## Manifest

`asc-listing.json`, in the app's repo. Paths are relative to the manifest's directory.

```json
{
  "bundleId": "com.example.MyApp",
  "platform": "IOS",
  "version": "1.0",
  "metadata": "build/appstore/metadata",
  "screenshots": {
    "directory": "build/screenshots/final",
    "sets": { "en": ["en-US", "en-GB"], "es": ["es-MX", "es-ES"] },
    "placementGroups": { "1320x2868": "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE" }
  },
  "creative": {
    "directory": "build/screenshots/creative",
    "sets": { "en": ["en-US", "en-GB"], "es": ["es-MX", "es-ES"] },
    "placements": {
      "PRODUCT_PAGE_HEADER_ASSET": "universal.png",
      "APP_STORE_SEARCH_RESULTS_ASSET": "universal.png"
    }
  }
}
```

- `platform`: `IOS`, `MAC_OS`, `TV_OS` or `VISION_OS`.
- `version` is optional; `--version` overrides it. Commands that touch a version need one or the other.
- `metadata`, `screenshots` and `creative` are each optional. `publish` skips a block the manifest does not configure.
- `screenshots.sets` maps a folder under `directory` to the App Store Connect locales it fills (one folder can fill several). Use the string `"folders"` instead when every subfolder name is itself an App Store Connect locale.
- `placementGroups` is optional. It is needed only when a screenshot size fits more than one placement group.
- `creative.sets` takes the same two forms as `screenshots.sets`. `creative.placements` maps a placement type to the file name inside each set folder; point both at one file, or give each its own.

## Metadata folder

`<metadata>/<locale>/<file>.txt`, plus `<metadata>/copyright.txt`. Locale folders are App Store Connect locale codes (`en-US`, `ja`, `zh-Hant`). Files are UTF-8; exactly one trailing newline is stripped. A missing file leaves that field as it is on App Store Connect, and so does an empty one (with a warning). Lengths count characters; any violation is reported for every file before the network is touched. Unknown `.txt` files are warned about and ignored.

| File | Field | Limit |
| --- | --- | --- |
| `name.txt` | app name | 30 |
| `subtitle.txt` | subtitle | 30 |
| `privacy_url.txt` | privacy policy URL | |
| `description.txt` | description | 4000 |
| `keywords.txt` | keywords | 100 |
| `promotional_text.txt` | promotional text | 170 |
| `release_notes.txt` | what's new | 4000 |
| `support_url.txt` | support URL | |
| `marketing_url.txt` | marketing URL | |
| `copyright.txt` (top level) | version copyright | |

Locales that exist on App Store Connect but not locally are reported as untouched, never deleted. What's New cannot be set on an app's first version.

## Screenshots

Put PNG or JPEG files in each folder; they are placed in file-name order. The tool reads each file's pixel size and resolves the placement group from Apple's own reference data, so new device sizes need no tool update.

- No alpha channel (App Store Connect rejects it); every offender is listed before anything is uploaded.
- At most 10 per device group per locale.
- Re-runs are idempotent. Each file is fingerprinted (SHA-256) and stored as the asset's reference name, so an unchanged file is never uploaded again and an unchanged locale is left alone. A changed order or file replaces that locale's group. If one group fails, the rest still run and the error lists the failed ones; re-running the same command redoes only those.

## Creative assets

Apple's product page header and search results images are two placement types, one image each per locale:

| Placement type | Where it shows | Accepted sizes |
| --- | --- | --- |
| `PRODUCT_PAGE_HEADER_ASSET` | the top of the product page | 5244x2950 (PNG), 3840x1646 (PNG) |
| `APP_STORE_SEARCH_RESULTS_ASSET` | search results | 5244x2950 (PNG), 3:2 from 1920x1280 to 3840x2560 (PNG or JPEG) |

One universal 5244x2950 PNG fills both: name it for both placement types and it is uploaded once and placed twice. The sizes and formats come from Apple's reference data at run time, so a size Apple adds later works without a tool update. A file in a format the size does not accept (a JPEG at 5244x2950, for example) is refused before anything is sent, and so is an image with an alpha channel. A placement type the reference data does not list as a creative asset is an error naming the ones it does. A changed file replaces that locale's placement; an unchanged one is left alone.

## Commands

```sh
asc-listing status      [--manifest FILE] [--version V] [--locale L ...] [--verbose]
asc-listing metadata    [--manifest FILE] [--version V] [--locale L ...] [--create-version] [--apply] [--verbose]
asc-listing screenshots [--manifest FILE] [--version V] [--locale L ...] [--create-version] [--apply] [--verbose]
asc-listing creative    [same as above]
asc-listing publish     [same as above]   # metadata, then screenshots, then creative
```

- `status` is read-only: the app, its versions and states, the app info state, and per locale the character count of each text field, the screenshot count per placement group, and whether the header and search assets are placed (`1` or `–`). It works on a version that is no longer editable.
- The write commands are a dry run unless you pass `--apply`. A dry run prints the plan and ends with `dry run: nothing changed (pass --apply to write)`; it only reads.
- With `--apply` the plan is executed, then re-read, and a line such as `metadata: all locales unchanged after apply` confirms the result (or a warning lists what still differs).
- `--locale` limits the App Store Connect locales acted on. Copyright is version-wide, so it is only sent without `--locale`. `--create-version` creates the version when it does not exist; without it a missing version is an error. The version and app info must be editable (for example `PREPARE_FOR_SUBMISSION`).
- `--verbose` logs each request as `METHOD path -> status`.
- Exit codes: 0 success, 1 failure (`error: ...` on stderr), 2 usage error.

## Adding a new app

1. Write `asc-listing.json` in the app's repo (bundle id, platform, version, and the metadata, screenshot and creative asset locations).
2. Export the listing into the folder layout above, one folder per locale.
3. `asc-listing status` to confirm the credentials, the app and the version state.
4. `asc-listing publish` for a dry run; read the plan.
5. `asc-listing publish --apply`, then run it again and expect everything unchanged.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

App Store and App Store Connect are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple.
