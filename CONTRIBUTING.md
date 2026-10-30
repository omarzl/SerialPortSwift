# Contributing

SerialPortSwift supports old toolchains and old systems on purpose. Two limits hold for every
change to `SerialPortSwift` and `SerialPortSwiftSimulation`. The third product, `SerialPortSwiftConcurrency`,
has its own minimums: see [The concurrency product](#the-concurrency-product).

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

## The concurrency product

`SerialPortSwiftConcurrency` (`Sources/SerialPortSwiftConcurrency/`) is the request/response channel as an actor with
`async`/`await`. It is the one place in the package where the Swift 5.1 and macOS 10.11 limits above do not apply.

**Why it is a separate product.** Swift concurrency needs a runtime library, `libswift_Concurrency`, that an app
deploying to macOS 10.11 cannot load. Code that uses concurrency links it, so `SerialPortSwift` and
`SerialPortSwiftSimulation` must never use it, and the `async`/`await` engine lives in its own product that an app
opts into. An app that stays on `SerialPortSwift` never links the concurrency runtime.

**Its minimums.** It needs the Swift 5.7 compiler and macOS 10.15:

- All of its code, and all of its tests, are inside `#if compiler(>=5.7) && canImport(_Concurrency)`, and its public
  types are `@available(macOS 10.15, *)`. With an older compiler the target builds empty, so the Swift 5.1 job keeps
  passing.
- Its framework is built with a deployment target of macOS 10.15 (`project.yml`). The other two stay at 10.11.
- It must build without warnings with every Swift from 5.7 on. The `Linux, Swift 5.7` job builds it with
  `-warnings-as-errors` with the 5.7 compiler and runs its tests, so "builds clean from the minimum" is checked, not
  assumed. Newer APIs go behind `#if compiler(>=...)`.
- The Swift 5.1 list above does not apply to it. Everything else in this file does.

**Why Swift 5.7 and not 5.5.** Swift 5.5 is where `async`/`await` starts, but its concurrency runtime loses a
wake-up: a task that makes a channel, takes a stream from `events()`, opens the channel and closes it never gets past
`events()`: the `await` on the actor never returns. It was reproduced with the `swift:5.5` image on Linux,
where the loop stalled in its first round, and it does not happen with 5.7 or later. A channel that can hang its
caller is worse than none, so the minimum is the oldest compiler whose runtime passes that loop, which is
`testChannelsWithAnEventsConsumerCanBeReleasedAndMadeAgainInQuickSuccession`. Do not lower it without checking that
test on the runtime you lower it to.

**No continuation wrappers.** The channel is written with native concurrency only: actors, `AsyncStream`, `Task`.
`withCheckedContinuation`, `withCheckedThrowingContinuation`, `withUnsafeContinuation` and
`withUnsafeThrowingContinuation` are not used anywhere in the module. A stream reports through its delegate on its
own queue; those reports enter the actor through an `AsyncStream`.

CI enforces this. The first step of the `Linux, Swift 6.0` job fails if this finds a match on a line that is not only
a comment (a comment may name the wrappers to forbid them):

```bash
grep -rnE "with(Checked|Unsafe)(Throwing)?Continuation" Sources/SerialPortSwiftConcurrency
```

**The core products stay free of it.** `Scripts/build-xcframeworks.sh` runs `otool -L` on both slices of the
`SerialPortSwift` and `SerialPortSwiftSimulation` binaries and fails if either lists `libswift_Concurrency`.

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
Release for the tag, if it does not exist yet. It uploads `SerialPortSwift.xcframework.zip`,
`SerialPortSwiftSimulation.xcframework.zip` and `SerialPortSwiftConcurrency.xcframework.zip`, each with a `.sha256`
file that holds the checksum of the zip as `swift package compute-checksum` prints it (the value a SwiftPM
`binaryTarget` asks for). The release notes list the same checksums. Running the workflow again replaces the files
and leaves the notes alone.

### Why prebuilt frameworks

Xcode applies a deployment-target floor of macOS 10.13 to Swift packages it builds from source, so an app that
deploys to macOS 10.11 cannot import the package through SwiftPM. An XCFramework built for macOS 10.11 has no such
floor. `project.yml` describes the three frameworks for XcodeGen. CI generates the Xcode project from it and never
commits it.

Each framework is a universal binary. The minimum macOS differs per framework:

| Framework | x86_64 slice requires | arm64 slice requires |
| --- | --- | --- |
| `SerialPortSwift` | macOS 10.11 | macOS 11.0 |
| `SerialPortSwiftSimulation` | macOS 10.11 | macOS 11.0 |
| `SerialPortSwiftConcurrency` | macOS 10.15 | macOS 11.0 |

macOS 11.0 is the oldest system an Apple silicon Mac runs. All three are built with library evolution, so each
carries a `.swiftinterface`. `SerialPortSwiftSimulation` and `SerialPortSwiftConcurrency` depend on
`SerialPortSwift`, which they link but do not embed.

### Why Xcode 26.3 or older

A `.swiftinterface` written by a newer compiler may not be readable by an older one. So that apps building with
Xcode 26.3 can import them, the frameworks are built with an Xcode that is not newer than 26.3.
`Scripts/select-xcode.sh` picks the newest installed release Xcode at or below that limit (betas are ignored) and
fails if there is none. To raise the limit, change `MAX_XCODE_VERSION` in that script.

### Building the frameworks locally

You need macOS, an Xcode that is not newer than the limit, and XcodeGen (`brew install xcodegen`):

```bash
DEVELOPER_DIR="$(Scripts/select-xcode.sh)" Scripts/build-xcframeworks.sh
```

The script generates the project, archives the three frameworks, packs the XCFrameworks and zips them, and writes
everything to `build/xcframeworks/` (ignored by git). It fails if a binary lacks the arm64 or the x86_64 slice, if
the x86_64 slice does not require the macOS from the table above (the script holds that minimum per framework), or if
a `.swiftinterface` is missing or does not name that target. It also fails if the `SerialPortSwift` or
`SerialPortSwiftSimulation` binary links `libswift_Concurrency`, or if its x86_64 slice references an `OS_*`
Objective-C class such as `OS_dispatch_queue` directly: macOS 10.11 does not export those classes, so dyld would
refuse the framework there. The script builds with implicit modules (`SWIFT_ENABLE_EXPLICIT_MODULES=NO`) for that
reason. It refuses an Xcode newer than the limit unless you set `ALLOW_NEWER_XCODE=1`. Set `FRAMEWORK_VERSION=1.2.3`
to stamp a version into the frameworks. The `frameworks` job in `ci.yml` runs the same script on every push and pull
request and uploads the three zips and their checksums as the `xcframeworks` artifact.

To add a framework, add it to `project.yml` and to `FRAMEWORKS` in the script, and state its minimum macOS in
`expected_x86_64_min_os`: the script refuses a framework without one. A new framework may not link
`libswift_Concurrency` unless you change `may_link_concurrency_runtime`.
