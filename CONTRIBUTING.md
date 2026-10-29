# Contributing

SerialPortSwift supports old toolchains and old systems on purpose. Two limits hold for every
change.

## Swift 5.1 is the language ceiling

The package must build with the Swift 5.1 compiler (Xcode 11). CI builds and tests it with
Swift 5.1.5 on Linux, so most mistakes fail there. Code that only builds on macOS is not covered
by that check, so review it against this list:

- No `some` or `any` in type positions, no `async`/`await`, no actors, no `@MainActor`,
  no `Sendable`.
- No `if let x {` or `guard let x else` shorthand. Write `if let x = x`.
- No `if`, `switch` or `do` used as an expression. Write a `return` in each branch; a
  single-expression function or closure body is fine.
- No implicit `self` in escaping closures. Write `self.` in every closure, even after
  `[weak self]` and `guard let self = self`.
- No multiple trailing closures.
- No `@main` and no result builders.
- No `#if` around postfix member expressions.
- No `#unavailable`, no `if #available` as an expression.
- No synthesized `Comparable` for enums, no enum cases used as protocol witnesses, no `where`
  clauses on members of non-generic types.
- No multi-pattern `catch`.
- `Result`, `Codable` and synthesized `Equatable`/`Hashable` are fine. `Identifiable` is not: it needs macOS 10.15.

## macOS 10.11 is the deployment floor

No API newer than macOS 10.11 may be used, even behind `#available`. Avoid in particular
`os_unfair_lock`, `os_log`, `dispatchPrecondition` (macOS 10.12), and the `Network` and
`Combine` frameworks. Use `NSLock`, or a serial `DispatchQueue`. CI type-checks the macOS sources
against a macOS 10.11 target.

## Building and testing

```bash
swift build
```

```bash
swift test
```

With Swift 5.1 to 5.3 on Linux, ask for test discovery on both commands. The package has no
`LinuxMain.swift`, so without the flag those compilers stop at the tests:

```bash
swift build --enable-test-discovery
```

```bash
swift test --enable-test-discovery
```

To run the same check CI runs, with Docker:

```bash
docker run --rm -v "$PWD:/src" -w /src swift:5.1 swift test --enable-test-discovery
```

## Releases

A release is a tag. Push a semantic version without a prefix:

```bash
git tag 1.2.3
git push origin 1.2.3
```

Tags that are not `X.Y.Z` (such as `v1.2.3` or `1.2.3-rc1`) are ignored. SwiftPM resolves the same tag as
the package version, so tag the commit you want to release.

The `Release` workflow (`.github/workflows/release.yml`) builds the frameworks and creates the GitHub
Release for the tag, if it does not exist yet. It uploads `SerialPortSwift.xcframework.zip` and
`SerialPortSwiftSimulation.xcframework.zip`, each with a `.sha256` file that holds the checksum of the zip as
`swift package compute-checksum` prints it (the value a SwiftPM `binaryTarget` asks for). The release notes list
the same checksums. Running the workflow again replaces the files and leaves the notes alone.

### Why prebuilt frameworks

Xcode applies a deployment-target floor of macOS 10.13 to Swift packages it builds from source, so an app that
deploys to macOS 10.11 cannot import the package through SwiftPM. An XCFramework built for macOS 10.11 has no such
floor. `project.yml` describes the two frameworks for XcodeGen. CI generates the Xcode project from it and never
commits it.

Each framework is a universal binary. Its x86_64 slice requires macOS 10.11. Its arm64 slice requires macOS 11.0,
the oldest system an Apple silicon Mac runs. Both are built with library evolution, so each carries a
`.swiftinterface`.

### Why Xcode 26.3 or older

A `.swiftinterface` written by a newer compiler may not be readable by an older one, and the apps that use the
frameworks build with Xcode 26.3. So the frameworks are built with an Xcode that is not newer than 26.3.
`Scripts/select-xcode.sh` picks the newest installed release Xcode at or below that limit (betas are ignored) and
fails if there is none. To raise the limit, change `MAX_XCODE_VERSION` in that script.

### Building the frameworks locally

You need macOS, an Xcode that is not newer than the limit, and XcodeGen (`brew install xcodegen`):

```bash
DEVELOPER_DIR="$(Scripts/select-xcode.sh)" Scripts/build-xcframeworks.sh
```

The script generates the project, archives both frameworks, packs the XCFrameworks and zips them, and writes
everything to `build/xcframeworks/` (ignored by git). It fails if a binary lacks the arm64 or the x86_64 slice, if
the x86_64 slice does not require macOS 10.11, or if a `.swiftinterface` is missing or does not name that target.
It also refuses an Xcode newer than the limit unless you set `ALLOW_NEWER_XCODE=1`. Set `FRAMEWORK_VERSION=1.2.3` to
stamp a version into the frameworks. The `frameworks` job in `ci.yml` runs the same script on every push and pull
request and uploads the zips as the `xcframeworks` artifact.
