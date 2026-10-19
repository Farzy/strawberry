#!/usr/bin/env bash
#
# build-macos.sh - Build, bundle, ad-hoc sign and deploy Strawberry.app on macOS.
#
# This is a developer convenience wrapper (not part of the upstream build system,
# which has no install rule on macOS). It:
#
#   1. Ensures the Homebrew build dependencies are present.
#   2. Builds KDSingleApplication (KDAB) statically into ~/.local the first time
#      (it is a hard dependency and is not packaged in Homebrew).
#   3. Configures + builds Strawberry with CMake/Ninja. Ninja only rebuilds what
#      changed.
#   4. Only when the compiled binary actually changed (or --force, or the target
#      is missing/stale): completes the .app bundle (icon + PkgInfo), ad-hoc
#      signs it with the project bundle id, deploys it to ~/Applications and
#      refreshes Launch Services.
#
# The deployed bundle links against Homebrew dylibs in /opt/homebrew - it runs on
# this machine but is not self-contained/portable. For a distributable bundle use
# jonaski/macdeploytool + the `deploy` / `dmg` CMake targets.
#
# Usage:
#   ./build-macos.sh [options]
#
# Options:
#   --force            Re-bundle / re-sign / re-deploy even if the binary is unchanged.
#   --reconfigure      Delete the CMake cache and configure from scratch.
#   --install-deps     Run `brew install` for any missing dependencies (otherwise
#                      the script only prints the command and exits).
#   --build-type=TYPE  CMake build type (default: RelWithDebInfo).
#   --dest=PATH        Destination .app path (default: ~/Applications/Strawberry.app).
#   --build-dir=PATH   CMake build directory (default: <repo>/build).
#   -h, --help         Show this help.
#
# Environment overrides: BUILD_TYPE, BUILD_DIR, DEST, LOCAL_PREFIX.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
DEST="${DEST:-${HOME}/Applications/Strawberry.app}"
LOCAL_PREFIX="${LOCAL_PREFIX:-${HOME}/.local}"

BUNDLE_ID="org.strawberrymusicplayer.strawberry"
ICNS_SRC="${REPO_ROOT}/dist/macos/strawberry.icns"
KDSA_REPO="https://github.com/KDAB/KDSingleApplication"

# Homebrew formulae the build needs. Keg-only ones (icu4c, openssl) are
# resolved explicitly further down.
BREW_DEPS=(
  qt gstreamer taglib boost chromaprint fftw libebur128
  libmtp libcdio google-sparsehash gnutls uchardet
  cmake ninja pkgconf
)

FORCE=0
RECONFIGURE=0
INSTALL_DEPS=0

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
build-macos.sh - Build, bundle, ad-hoc sign and deploy Strawberry.app on macOS.

Usage: ./build-macos.sh [options]

  --force            Re-bundle / re-sign / re-deploy even if the binary is unchanged.
  --reconfigure      Delete the CMake cache and configure from scratch.
  --install-deps     Run `brew install` for any missing dependencies.
  --build-type=TYPE  CMake build type (default: RelWithDebInfo).
  --dest=PATH        Destination .app path (default: ~/Applications/Strawberry.app).
  --build-dir=PATH   CMake build directory (default: <repo>/build).
  -h, --help         Show this help.

Environment overrides: BUILD_TYPE, BUILD_DIR, DEST, LOCAL_PREFIX.
EOF
}

sha256() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #

for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=1 ;;
    --reconfigure)   RECONFIGURE=1 ;;
    --install-deps)  INSTALL_DEPS=1 ;;
    --build-type=*)  BUILD_TYPE="${arg#*=}" ;;
    --dest=*)        DEST="${arg#*=}" ;;
    --build-dir=*)   BUILD_DIR="${arg#*=}" ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown option: $arg (see --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This script only runs on macOS."

# --------------------------------------------------------------------------- #
# 1. Homebrew dependencies
# --------------------------------------------------------------------------- #

command -v brew >/dev/null 2>&1 || die "Homebrew not found - install from https://brew.sh"

BREW_PREFIX="$(brew --prefix)"

missing=()
for formula in "${BREW_DEPS[@]}"; do
  brew list --versions "$formula" >/dev/null 2>&1 || missing+=("$formula")
done

if [ "${#missing[@]}" -gt 0 ]; then
  if [ "$INSTALL_DEPS" -eq 1 ]; then
    log "Installing missing Homebrew dependencies: ${missing[*]}"
    brew install "${missing[@]}"
  else
    die "Missing Homebrew dependencies. Run:
    brew install ${missing[*]}
  or re-run this script with --install-deps"
  fi
fi

QT_PREFIX="$(brew --prefix qt)"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"

# icu4c is versioned in Homebrew and the suffix changes over time.
ICU_PREFIX="$(
  { brew --prefix icu4c \
    || brew --prefix icu4c@78 \
    || brew --prefix icu4c@77 \
    || brew --prefix icu4c@76; } 2>/dev/null
)"
[ -n "$ICU_PREFIX" ] || die "Could not locate an icu4c Homebrew keg."

export PKG_CONFIG_PATH="${ICU_PREFIX}/lib/pkgconfig:${OPENSSL_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/share/pkgconfig"

# --------------------------------------------------------------------------- #
# 2. KDSingleApplication (one-time, static, into ~/.local)
# --------------------------------------------------------------------------- #

if [ ! -d "${LOCAL_PREFIX}/lib/cmake/KDSingleApplication-qt6" ]; then
  log "Building KDSingleApplication into ${LOCAL_PREFIX} (one-time setup)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git clone --depth 1 --recurse-submodules "$KDSA_REPO" "${tmp}/kdsa"
  cmake -S "${tmp}/kdsa" -B "${tmp}/kdsa/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${QT_PREFIX}" \
    -DCMAKE_INSTALL_PREFIX="${LOCAL_PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DKDSingleApplication_STATIC=ON \
    -DKDSingleApplication_QT6=ON \
    -DKDSingleApplication_TESTS=OFF \
    -DKDSingleApplication_EXAMPLES=OFF
  cmake --build "${tmp}/kdsa/build" --parallel "$(sysctl -n hw.ncpu)"
  cmake --install "${tmp}/kdsa/build"
  rm -rf "$tmp"
  trap - EXIT
fi

# --------------------------------------------------------------------------- #
# 3. Configure + build (Ninja handles incrementality)
# --------------------------------------------------------------------------- #

[ "$RECONFIGURE" -eq 1 ] && rm -f "${BUILD_DIR}/CMakeCache.txt"

# Upstream probes that Qt's sqlite driver and Strawberry share one sqlite library
# by registering an sqlite3_auto_extension.
# Apple's system sqlite rejects that call (SQLITE_MISUSE), so the probe always fails on macOS,
# although Homebrew's Qt does use the same system libsqlite3 as Strawberry.
# Pre-seed the result to skip the probe.
log "Configuring (${BUILD_TYPE})"
cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DUSE_BUNDLE=OFF \
  -DENABLE_GPOD=OFF \
  -DENABLE_SPARKLE=OFF \
  -DENABLE_QTSPARKLE=OFF \
  -DQT_SQLITE_SAME_LIBRARY_TEST=1 \
  -DCMAKE_PREFIX_PATH="${QT_PREFIX};${LOCAL_PREFIX};${OPENSSL_PREFIX};${BREW_PREFIX}" \
  -DICU_ROOT="${ICU_PREFIX}"

APP_IN_BUILD="${BUILD_DIR}/strawberry.app"
BIN_IN_BUILD="${APP_IN_BUILD}/Contents/MacOS/strawberry"

before_hash="none"
[ -f "$BIN_IN_BUILD" ] && before_hash="$(sha256 "$BIN_IN_BUILD")"

log "Building"
cmake --build "${BUILD_DIR}" --parallel "$(sysctl -n hw.ncpu)"

[ -f "$BIN_IN_BUILD" ] || die "Build finished but ${BIN_IN_BUILD} is missing."
after_hash="$(sha256 "$BIN_IN_BUILD")"

# --------------------------------------------------------------------------- #
# 4. Bundle + sign + deploy - only when needed
# --------------------------------------------------------------------------- #

STAMP="${DEST}/Contents/Resources/.build-hash"
deployed_hash=""
[ -f "$STAMP" ] && deployed_hash="$(cat "$STAMP")"

need_deploy=0
if [ "$FORCE" -eq 1 ]; then
  need_deploy=1; reason="--force"
elif [ ! -d "$DEST" ]; then
  need_deploy=1; reason="target missing"
elif [ "$after_hash" != "$deployed_hash" ]; then
  need_deploy=1
  if [ "$before_hash" != "$after_hash" ]; then reason="binary rebuilt"; else reason="deployed copy stale"; fi
fi

if [ "$need_deploy" -eq 0 ]; then
  log "Up to date - ${DEST} already matches the current build. Nothing to do."
  exit 0
fi

log "Deploying (${reason})"

mkdir -p "$(dirname "$DEST")"
/usr/bin/rsync -a --delete "${APP_IN_BUILD}/" "${DEST}/"

# Complete the bundle: the CMake build produces only Info.plist + the binary.
mkdir -p "${DEST}/Contents/Resources"
cp "${ICNS_SRC}" "${DEST}/Contents/Resources/strawberry.icns"
printf 'APPL????' > "${DEST}/Contents/PkgInfo"

# Record what we deployed so the next run can skip an unchanged rebuild. Written
# before signing so it is covered by the seal.
printf '%s' "$after_hash" > "$STAMP"

# Ad-hoc sign (identity "-"): satisfies the "must be signed" requirement, seals
# the resources and pins the identifier to the project bundle id so keychain
# ACLs and TCC grants stay stable across rebuilds. Not Gatekeeper-valid.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${DEST}"

# Refresh the Finder / Spotlight / Launchpad icon and registration.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DEST}"

log "Done. Installed: ${DEST}"
codesign -dv "${DEST}" 2>&1 | grep -E 'Identifier|Signature|Sealed' || true

if pgrep -f 'strawberry.app/Contents/MacOS/strawberry' >/dev/null 2>&1; then
  warn "A Strawberry instance is running. Strawberry is single-instance - quit it before launching the new copy (they share ~/Library/Application Support/Strawberry/)."
fi
