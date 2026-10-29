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
