#!/usr/bin/env bash
#
# Builds the prebuilt binary frameworks of SerialPortSwift.
#
#   1. Generates the Xcode project from project.yml with XcodeGen (the project is never committed).
#   2. Archives SerialPortSwift, SerialPortSwiftSimulation and SerialPortSwiftConcurrency for macOS (arm64 and
#      x86_64, Release).
#   3. Packs each framework, with its dSYM, into an XCFramework.
#   4. Verifies the result and fails if it is not what the apps need: both architectures, an x86_64 slice that
#      deploys back to the framework's own minimum macOS (10.11 for SerialPortSwift and SerialPortSwiftSimulation,
#      10.15 for SerialPortSwiftConcurrency), and module interfaces (.swiftinterface) that name that target. It also
#      fails if SerialPortSwift or SerialPortSwiftSimulation link the Swift concurrency runtime
#      (libswift_Concurrency): apps that deploy to macOS 10.11 cannot load it, and keeping it out of those two is
#      the reason SerialPortSwiftConcurrency is a separate framework. And it fails if the x86_64 slice of a
#      framework that deploys to a macOS older than 10.12 references an OS_* Objective-C class (OS_dispatch_queue,
#      for example) directly: those systems do not export them, so dyld would refuse to load the framework.
#   5. Zips each XCFramework and writes the SwiftPM checksum of the zip next to it.
#
# Output, in build/xcframeworks/, for each of the three frameworks (SerialPortSwift, SerialPortSwiftSimulation,
# SerialPortSwiftConcurrency):
#   <name>.xcframework
#   <name>.xcframework.zip
#   <name>.xcframework.zip.sha256
#
# Needs macOS, a full Xcode and XcodeGen (brew install xcodegen). The build refuses an Xcode newer than the
# limit in Scripts/select-xcode.sh, because the module interfaces of a newer compiler may not be readable by the
# Xcode of the apps that use the frameworks. In CI, Scripts/select-xcode.sh picks the Xcode first.
#
# Environment (all optional):
#   FRAMEWORK_VERSION   Version stamped into the frameworks' Info.plist (CFBundleShortVersionString), for
#                       example 1.2.3. Default: the MARKETING_VERSION in project.yml.
#   ALLOW_NEWER_XCODE   Set to 1 to build with an Xcode newer than the limit anyway.
#
# Compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

FRAMEWORKS=(SerialPortSwift SerialPortSwiftSimulation SerialPortSwiftConcurrency)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVES_DIR="$BUILD_DIR/archives"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
WORK_DIR="$BUILD_DIR/work"
OUT_DIR="$BUILD_DIR/xcframeworks"
PROJECT="$ROOT/SerialPortSwift.xcodeproj"

# ---------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------

step() {
  printf '\n==> %s\n' "$*"
}

warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s\n' "$*"
  else
    printf 'warning: %s\n' "$*" >&2
  fi
}

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*"
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

# Prints the macOS version that the x86_64 slice of framework $1 must require (MACOSX_DEPLOYMENT_TARGET in
# project.yml). Fails for a framework that is not listed here, so that a new framework cannot be built without
# anyone stating its minimum.
expected_x86_64_min_os() {
  case "$1" in
    SerialPortSwift | SerialPortSwiftSimulation) printf '10.11\n' ;;
    SerialPortSwiftConcurrency) printf '10.15\n' ;;
    *) return 1 ;;
  esac
}

# Prints the extended regular expression that the x86_64 module interface of a framework whose minimum macOS is $1
# must match. The interface names its target in swift-module-flags, for example -target x86_64-apple-macos10.11
# (the OS part is "macos" or "macosx" and may carry a ".0" patch).
x86_64_target_pattern() {
  local min_os="$1"
  printf '%s' "-target x86_64-apple-macosx?${min_os//./[.]}"'([.]0)?( |$)'
}

# Succeeds when framework $1 may link the Swift concurrency runtime. Only the concurrency framework may: it is the
# one that needs it, and it is a separate framework so that the others never do. Anything not listed may not, so
# a new framework starts out forbidden from linking it.
may_link_concurrency_runtime() {
  [ "$1" = "SerialPortSwiftConcurrency" ]
}

# The first macOS that exports the Objective-C classes of its OS objects (OS_dispatch_queue, OS_dispatch_source,
# OS_os_log, OS_xpc_object and the rest). Before it they exist only at run time, and a binary must look them up by
# name.
OS_OBJECT_CLASSES_MIN_OS=10.12

# Succeeds when macOS version $1 (such as 10.11 or 11.0) is older than version $2.
macos_version_older_than() {
  awk -v older="$1" -v newer="$2" 'BEGIN {
    split(older, a, ".")
    split(newer, b, ".")
    for (i = 1; i <= 3; i++) {
      if (a[i] + 0 < b[i] + 0) exit 0
      if (a[i] + 0 > b[i] + 0) exit 1
    }
    exit 1
  }'
}

# Reads the minimum OS version out of the output of `vtool -show-build` or `otool -l` (both print the same
# field names). That is "minos" under LC_BUILD_VERSION and "version" under LC_VERSION_MIN_MACOSX. The "version"
# that follows "minos" in LC_BUILD_VERSION is the linker's version, so only the first value is taken.
parse_min_os() {
  awk '
    $1 == "cmd" { watching = ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX"); next }
    watching && ($1 == "minos" || $1 == "version") { print $2; watching = 0 }
  '
}

# Prints the minimum OS version of the single-architecture Mach-O file $1.
min_os_of() {
  local file="$1" version=""
  if command -v vtool >/dev/null 2>&1; then
    version="$(vtool -show-build "$file" 2>/dev/null | parse_min_os)" || version=""
  fi
  if [ -z "$version" ]; then
    version="$(otool -l "$file" 2>/dev/null | parse_min_os)" || version=""
  fi
  printf '%s\n' "$version"
}

# Succeeds when every .swiftinterface of architecture $3 in framework $2 (module $1) is a library-evolution
# interface and, when $4 is not empty, matches the extended regular expression $4. Needs at least one.
check_interfaces() {
  local module="$1" framework="$2" arch="$3" target_pattern="$4"
  local dir="$framework/Modules/$module.swiftmodule"
  local file count=0

  [ -d "$dir" ] || fail "$module: $dir does not exist, so the framework has no module interface."
  for file in "$dir/$arch"-*.swiftinterface; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    grep -E -e '-enable-library-evolution' "$file" >/dev/null ||
      fail "$module: $file was not built with library evolution (BUILD_LIBRARY_FOR_DISTRIBUTION)."
    if [ -n "$target_pattern" ]; then
      grep -E -e "$target_pattern" "$file" >/dev/null ||
        fail "$module: $file does not name the target this build must have. Expected a match for: $target_pattern. Found: $(grep -E -e '^// swift-module-flags:' "$file" || echo 'no swift-module-flags line')"
    fi
  done
  [ "$count" -gt 0 ] || fail "$module: no $arch .swiftinterface in $dir."
  printf '    %s: %d module interface file(s), library evolution on\n' "$arch" "$count"
}

# Fails when the single-architecture Mach-O file $2 (the $3 slice of framework $1) links the Swift concurrency
# runtime. `otool -L` lists every dylib the binary loads, weak links included: @rpath/libswift_Concurrency.dylib
# for a deployment target before macOS 12, /usr/lib/swift/libswift_Concurrency.dylib from there on.
check_no_concurrency_runtime() {
  local name="$1" file="$2" arch="$3"
  local libraries count offending

  libraries="$(otool -L "$file" 2>&1)" || fail "$name: otool -L could not read the $arch slice: $libraries"
  # The first line names the file. A binary that loads nothing else is not a framework, so an empty list means the
  # tool did not do its job, and the absence of libswift_Concurrency would mean nothing.
  count="$(printf '%s\n' "$libraries" | awk 'NR > 1 && NF { count++ } END { print count + 0 }')"
  [ "$count" -gt 0 ] || fail "$name: otool -L listed no libraries for the $arch slice, so it cannot show that the slice does not link libswift_Concurrency. Output: $libraries"

  # One line, so that a GitHub Actions annotation holds all of it.
  offending="$(printf '%s\n' "$libraries" | grep -F -e 'libswift_Concurrency' | tr -s '\t\n' '  ')" || offending=""
  if [ -n "$offending" ]; then
    fail "$name: the $arch slice links the Swift concurrency runtime, which apps that deploy to macOS 10.11 cannot load. Only SerialPortSwiftConcurrency may. Check that no source in Sources/$name uses async/await, actors or Task, and whether the compiler's implicit import of _Concurrency is the cause. otool -L lists:$offending"
  fi
  printf '    %s: does not link libswift_Concurrency (%d libraries)\n' "$arch" "$count"
}

# Fails when the x86_64 slice of the binary $2 (framework $1) references an OS_* Objective-C class directly: a
# non-weak undefined _OBJC_CLASS_$_OS_* symbol. macOS 10.11 does not export those classes, so dyld refuses to load
# such a binary there, and the app that links it does not launch.
check_no_os_object_class_references() {
  local name="$1" binary="$2"
  local symbols count classes

  symbols="$(nm -m -arch x86_64 "$binary" 2>&1)" || fail "$name: nm -m could not read the x86_64 slice: $symbols"
  # A framework always uses something from the system. No undefined symbols means the tool did not do its job, and
  # the absence of OS_* classes would mean nothing.
  count="$(printf '%s\n' "$symbols" | grep -c -F -e '(undefined)')" || count=0
  [ "$count" -gt 0 ] || fail "$name: nm -m listed no undefined symbols for the x86_64 slice, so it cannot show that the slice references no OS_* class. Output: $symbols"

  # One line, so that a GitHub Actions annotation holds all of it.
  classes="$(printf '%s\n' "$symbols" | grep -F -e '(undefined)' | grep -v -F -e ' weak ' |
    grep -o -e '_OBJC_CLASS_\$_OS_[A-Za-z0-9_]*' | sort -u | tr '\n' ' ' | sed 's/ $//')" || classes=""
  if [ -n "$classes" ]; then
    fail "$name: the x86_64 slice references OS_* Objective-C classes directly, which macOS $OS_OBJECT_CLASSES_MIN_OS is the first to export, so it does not load on older systems. Check that the build uses implicit modules (SWIFT_ENABLE_EXPLICIT_MODULES=NO). Found: $classes"
  fi
  printf '    x86_64: references no OS_* class directly (%d undefined symbols)\n' "$count"
}

verify_xcframework() {
  local name="$1" xcframework="$2"
  local candidate framework="" slices=0 binary archs arch thin min_os expected_min_os target_pattern

  expected_min_os="$(expected_x86_64_min_os "$name")" || fail "$name: Scripts/build-xcframeworks.sh does not say which macOS this framework must require. Add it to expected_x86_64_min_os."
  target_pattern="$(x86_64_target_pattern "$expected_min_os")"

  step "Verifying $name.xcframework"

  [ -f "$xcframework/Info.plist" ] || fail "$name: $xcframework/Info.plist is missing."
  for candidate in "$xcframework"/*/"$name.framework"; do
    [ -d "$candidate" ] || continue
    framework="$candidate"
    slices=$((slices + 1))
  done
  [ "$slices" -eq 1 ] || fail "$name: expected exactly one macOS framework slice in $xcframework, found $slices."
  printf '    slice: %s\n' "$(basename "$(dirname "$framework")")"

  binary="$framework/$name"
  [ -f "$binary" ] || fail "$name: the framework binary $binary is missing."

  # Both architectures.
  archs="$(lipo -archs "$binary")" || fail "$name: lipo could not read $binary."
  printf '    architectures: %s\n' "$archs"
  for arch in arm64 x86_64; do
    case " $archs " in
      *" $arch "*) ;;
      *) fail "$name: the binary has no $arch slice (found: $archs)." ;;
    esac
  done

  # The x86_64 slice must deploy back to the framework's own floor. The arm64 slice cannot go below macOS 11.0, so
  # its minimum is only reported.
  #
  # Neither slice of a framework that may not link the Swift concurrency runtime may do so.
  mkdir -p "$WORK_DIR"
  for arch in x86_64 arm64; do
    thin="$WORK_DIR/$name.$arch"
    lipo "$binary" -thin "$arch" -output "$thin" || fail "$name: lipo could not extract the $arch slice."
    min_os="$(min_os_of "$thin")"
    [ -n "$min_os" ] || fail "$name: could not read the minimum OS version of the $arch slice (vtool and otool found no LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX)."
    printf '    %s minimum macOS: %s\n' "$arch" "$min_os"
    if [ "$arch" = "x86_64" ]; then
      case "$min_os" in
        "$expected_min_os" | "$expected_min_os.0") ;;
        *) fail "$name: the x86_64 slice requires macOS $min_os, expected $expected_min_os. Check MACOSX_DEPLOYMENT_TARGET in project.yml." ;;
      esac
    fi
    if ! may_link_concurrency_runtime "$name"; then
      check_no_concurrency_runtime "$name" "$thin" "$arch"
    fi
    rm -f "$thin"
  done

  # A slice that deploys to a system without the OS_* classes must look them up by name rather than link them.
  if macos_version_older_than "$expected_min_os" "$OS_OBJECT_CLASSES_MIN_OS"; then
    check_no_os_object_class_references "$name" "$binary"
  fi

  # The module interfaces, for both architectures. The x86_64 one must name the framework's own target.
  check_interfaces "$name" "$framework" x86_64 "$target_pattern"
  check_interfaces "$name" "$framework" arm64 ""
}

# Sets CHECKSUM to the SwiftPM checksum (SHA-256) of the file $1.
compute_checksum() {
  local zip_file="$1"
  local checksum_pattern='^[0-9a-f]{64}$'

  CHECKSUM=""
  # Run outside the package folder: the command needs no package.
  CHECKSUM="$(cd "$WORK_DIR" && swift package compute-checksum "$zip_file" | tail -n 1)" || CHECKSUM=""
  if ! [[ "$CHECKSUM" =~ $checksum_pattern ]]; then
    warn "swift package compute-checksum gave no usable checksum for $zip_file; using shasum -a 256, which is the same SHA-256."
    CHECKSUM="$(shasum -a 256 "$zip_file" | awk '{ print $1 }')" || CHECKSUM=""
  fi
  [[ "$CHECKSUM" =~ $checksum_pattern ]] || fail "could not compute a SHA-256 checksum for $zip_file."
}

# ---------------------------------------------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------------------------------------------

step "Checking the toolchain"

# otool is needed even where vtool is: it lists the libraries a binary loads.
for tool in xcodegen xcodebuild lipo otool nm ditto swift unzip awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is not on PATH. This script needs macOS with a full Xcode and XcodeGen (brew install xcodegen)."
done

# Every framework needs a stated minimum macOS. Find out before the long build, not after it.
for name in "${FRAMEWORKS[@]}"; do
  expected_x86_64_min_os "$name" >/dev/null || fail "$name: Scripts/build-xcframeworks.sh does not say which macOS this framework must require. Add it to expected_x86_64_min_os."
done

if ! "$ROOT/Scripts/select-xcode.sh" --check; then
  if [ "${ALLOW_NEWER_XCODE:-0}" = "1" ]; then
    warn "Continuing with an Xcode newer than the limit because ALLOW_NEWER_XCODE=1. The frameworks may not be usable by the apps' Xcode."
  else
    fail "Refusing to build with an Xcode newer than the limit (set ALLOW_NEWER_XCODE=1 to build anyway)."
  fi
fi
xcodebuild -version
swift --version

# ---------------------------------------------------------------------------------------------------------------
# Generate the project and archive
# ---------------------------------------------------------------------------------------------------------------

rm -rf "$ARCHIVES_DIR" "$DERIVED_DATA_DIR" "$WORK_DIR" "$OUT_DIR" "$PROJECT"
mkdir -p "$ARCHIVES_DIR" "$WORK_DIR" "$OUT_DIR"

step "Generating the Xcode project with XcodeGen"
(cd "$ROOT" && xcodegen generate --spec project.yml)
[ -d "$PROJECT" ] || fail "XcodeGen did not create $PROJECT."

BUILD_SETTINGS=(
  SKIP_INSTALL=NO
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  ONLY_ACTIVE_ARCH=NO
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  # Implicit modules. With explicit modules, Xcode 26 makes Swift reference the OS_* Objective-C classes
  # (OS_dispatch_queue, ...) directly even for a macOS 10.11 target, and 10.11 does not export them: dyld refuses the
  # framework there. Implicit modules keep the lookup by name that the SDK headers ask for below macOS 10.12.
  SWIFT_ENABLE_EXPLICIT_MODULES=NO
)
if [ -n "${FRAMEWORK_VERSION:-}" ]; then
  BUILD_SETTINGS+=("MARKETING_VERSION=$FRAMEWORK_VERSION")
fi

for name in "${FRAMEWORKS[@]}"; do
  step "Archiving $name"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$name" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVES_DIR/$name.xcarchive" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    "${BUILD_SETTINGS[@]}"
done

# ---------------------------------------------------------------------------------------------------------------
# Pack, verify, zip
# ---------------------------------------------------------------------------------------------------------------

for name in "${FRAMEWORKS[@]}"; do
  archive="$ARCHIVES_DIR/$name.xcarchive"
  xcframework="$OUT_DIR/$name.xcframework"

  # The archive of a framework that depends on another one also holds the dependency, so look for this one by name.
  found="$(find "$archive/Products" -type d -name "$name.framework" -prune)" || found=""
  framework_count="$(printf '%s\n' "$found" | awk 'NF { count++ } END { print count + 0 }')"
  if [ "$framework_count" -ne 1 ]; then
    fail "$name: expected one $name.framework in $archive/Products, found $framework_count. Contents: $(find "$archive/Products" -maxdepth 4 | tr '\n' ' ')"
  fi
  framework="$found"
  dsym="$archive/dSYMs/$name.framework.dSYM"

  step "Creating $name.xcframework"
  create_args=(-create-xcframework -framework "$framework")
  if [ -d "$dsym" ]; then
    create_args+=(-debug-symbols "$dsym")
  else
    warn "$name: no dSYM at $dsym, so the XCFramework has no debug symbols."
  fi
  create_args+=(-output "$xcframework")
  xcodebuild "${create_args[@]}"

  verify_xcframework "$name" "$xcframework"

  step "Zipping $name.xcframework"
  zip_file="$OUT_DIR/$name.xcframework.zip"
  (cd "$OUT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$name.xcframework" "$name.xcframework.zip")
  listing="$(unzip -Z1 "$zip_file")"
  printf '%s\n' "$listing" | grep -F -x -e "$name.xcframework/Info.plist" >/dev/null ||
    fail "$name: $zip_file does not contain $name.xcframework/Info.plist at its top level."
  compute_checksum "$zip_file"
  printf '%s\n' "$CHECKSUM" >"$zip_file.sha256"
  printf '    %s\n    SHA-256 %s\n' "$zip_file" "$CHECKSUM"
done

rm -rf "$WORK_DIR"

step "Done"
(cd "$OUT_DIR" && ls -l)
