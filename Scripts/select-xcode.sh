#!/usr/bin/env bash
#
# Chooses the Xcode that the binary frameworks are built with.
#
# The frameworks ship a textual module interface (.swiftinterface). A compiler reads an interface written
# by an older compiler, but it may not read one written by a newer compiler. The apps that use the
# frameworks build with Xcode 26.3, so the frameworks must be built with Xcode 26.3 or older.
#
#   Scripts/select-xcode.sh           Prints the developer directory (for DEVELOPER_DIR) of the newest installed
#                                     Xcode that is at or below the limit. What it found and chose goes to
#                                     stderr. Exits 1 if no installed Xcode qualifies.
#   Scripts/select-xcode.sh --check   Exits 1 unless the active Xcode is at or below the limit.
#
# Environment:
#   MAX_XCODE_VERSION   Highest Xcode version allowed. Default: 26.3.
#   XCODE_APPS_DIR      Folder that holds the Xcode_<version>.app bundles. Default: /Applications.
#
# Compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

MAX_XCODE_VERSION="${MAX_XCODE_VERSION:-26.3}"
XCODE_APPS_DIR="${XCODE_APPS_DIR:-/Applications}"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

# Succeeds when version $1 is lower than or equal to version $2.
version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

select_newest() {
  local app name version best_version="" best_app=""
  local release_pattern='^[0-9]+(\.[0-9]+)*$'

  log "Looking for Xcode_*.app in $XCODE_APPS_DIR (limit: $MAX_XCODE_VERSION)"
  for app in "$XCODE_APPS_DIR"/Xcode_*.app; do
    [ -d "$app" ] || continue
    name="$(basename "$app" .app)"
    version="${name#Xcode_}"
    # Release versions only. A name with letters (a beta, a release candidate) is skipped.
    if ! [[ "$version" =~ $release_pattern ]]; then
      log "  skipped  $name (not a release version)"
      continue
    fi
    if ! version_le "$version" "$MAX_XCODE_VERSION"; then
      log "  skipped  $name (newer than $MAX_XCODE_VERSION)"
      continue
    fi
    log "  usable   $name"
    if [ -z "$best_version" ] || version_le "$best_version" "$version"; then
      best_version="$version"
      best_app="$app"
    fi
  done

  if [ -z "$best_app" ]; then
    die "no installed release Xcode is at or below $MAX_XCODE_VERSION (looked in $XCODE_APPS_DIR). Use a runner image that has one, or raise MAX_XCODE_VERSION in Scripts/select-xcode.sh once the apps that use the frameworks build with a newer Xcode."
  fi
  if [ ! -d "$best_app/Contents/Developer" ]; then
    die "$best_app has no Contents/Developer folder"
  fi

  log "Selected Xcode $best_version ($best_app)"
  printf '%s\n' "$best_app/Contents/Developer"
}

check_active() {
  local active=""
  active="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $2 }')" || active=""
  if [ -z "$active" ]; then
    die "could not read the active Xcode version (xcodebuild -version failed). Select a full Xcode with xcode-select or DEVELOPER_DIR."
  fi
  if ! version_le "$active" "$MAX_XCODE_VERSION"; then
    die "the active Xcode is $active, newer than the limit of $MAX_XCODE_VERSION. A module interface written by a newer compiler may not be readable by the apps' Xcode. Select an older Xcode (DEVELOPER_DIR or xcode-select)."
  fi
  log "Active Xcode $active is at or below the limit of $MAX_XCODE_VERSION."
}

case "${1:-}" in
  "")
    select_newest
    ;;
  --check)
    check_active
    ;;
  *)
    die "usage: Scripts/select-xcode.sh [--check]"
    ;;
esac
