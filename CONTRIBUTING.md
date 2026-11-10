# Contributing

Issues and pull requests are welcome. For anything larger than a bug fix, open an issue first so we can agree on the shape before you write it.

## Setup

macOS 26 and a Swift 6.2 toolchain (Xcode 26).

```sh
swift build
swift test
swiftformat --lint .
swiftlint lint --strict
```

CI runs all four on every pull request.

## Guidelines

- Swift 6 language mode with strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)`.
- Tests use Swift Testing and never touch the network. Use `ScriptedTransport` from `TestSupport.swift`. Put recorded App Store Connect responses under `Tests/ASCListingKitTests/Fixtures`, with any account-specific ids replaced.
- Write commands must stay a dry run unless `--apply` is passed, and must never delete a locale or an asset that the manifest does not manage.
- Keep comments for constraints the code cannot show (an App Store Connect quirk, an ordering rule).

## Commits

One logical change per commit, with a subject that starts with a tag:

- `[FEATURE]` new behavior
- `[FIX]` bug fix
- `[CHORE]` tooling, docs, CI

Add a line to `CHANGELOG.md` under "Unreleased" for anything a user would notice.
