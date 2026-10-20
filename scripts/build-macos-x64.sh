#!/usr/bin/env bash
#
# Build DeepSeek Harness for macOS on Intel (x86_64).
#
# The script installs the locked workspace dependencies, builds every repository
# artifact (native addon, Host/Client bundles, Web, Desktop bundle) and packages an
# unsigned Desktop DMG for mac-x64.
#
# Output:
#   apps/desktop/.desktop-build/targets/mac-x64/unsigned-artifacts/
#
# Usage:
#   scripts/build-macos-x64.sh [options]
#
# Options:
#   --build-only        Build repository artifacts, skip Desktop packaging.
#   --skip-install      Reuse an existing node_modules tree.
#   --no-xlsx-fallback  Never replace the SheetJS CDN dependency; fail instead.
#   -h, --help          Show this help.
#
# Environment:
#   DSH_XLSX_FALLBACK_SPEC   pnpm spec used when cdn.sheetjs.com is unreachable
#                            (default: npm:@e965/xlsx@0.20.3)
#   DSH_GITHUB_PROXY         Prefix for GitHub release downloads that fail directly
#                            (default: https://gh-proxy.com/; empty disables it)
#   ELECTRON_MIRROR          Electron download mirror
#                            (default: https://npmmirror.com/mirrors/electron/)
#   ELECTRON_BUILDER_BINARIES_MIRROR
#                            electron-builder tool mirror
#                            (default: https://npmmirror.com/mirrors/electron-builder-binaries/)
#   DSH_GATE_CONCURRENCY     Build parallelism; the build defaults to the host CPU count.
#   DSH_ALLOW_NON_INTEL=1    Allow packaging on Apple Silicon through Rosetta.
#
# The machine needs Node.js 22.19+ or 24+, a C compiler (Xcode Command Line Tools),
# and network access for the locked npm packages plus the Desktop runtime payload
# (Node.js, Python, Python wheels, Electron).
#
# When the SheetJS fallback is used, pnpm-workspace.yaml and pnpm-lock.yaml stay
# modified until packaging finishes so every pnpm invocation sees a consistent
# tree; the first build then carries a ".dirty" version stamp, while the Desktop
# packaging build (--profile official) does not. Both files are restored on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_ONLY=0
SKIP_INSTALL=0
ALLOW_XLSX_FALLBACK=1
XLSX_FALLBACK_SPEC="${DSH_XLSX_FALLBACK_SPEC:-npm:@e965/xlsx@0.20.3}"
ARTIFACTS_DIR="$ROOT/apps/desktop/.desktop-build/targets/mac-x64/unsigned-artifacts"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --no-xlsx-fallback) ALLOW_XLSX_FALLBACK=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

step "Checking the build host"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS is required."

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "x86_64" ]]; then
  if [[ "${DSH_ALLOW_NON_INTEL:-0}" == "1" ]]; then
    warn "host architecture is $HOST_ARCH; continuing because DSH_ALLOW_NON_INTEL=1."
    warn "An x64 build from Apple Silicon needs Rosetta and the x64 Node.js runtime."
  else
    die "mac-x64 packaging needs an Intel Mac (or a Rosetta x86_64 shell). Current: $HOST_ARCH.
      Run under Rosetta with: arch -x86_64 $0 $*
      or set DSH_ALLOW_NON_INTEL=1 to try anyway."
  fi
fi

command -v node >/dev/null 2>&1 || die "Node.js is not on PATH."
node -e '
const [major, minor] = process.versions.node.split(".").map(Number)
const supported = major === 22 ? minor >= 19 : major >= 24
if (!supported) {
  console.error(`error: Node.js ${process.versions.node} is unsupported; install 22.19+ or 24+.`)
  process.exit(1)
}
'

command -v cc >/dev/null 2>&1 || die "a C compiler is required for the native addon (install Xcode Command Line Tools)."

export DSH_TELEMETRY_DISABLED="${DSH_TELEMETRY_DISABLED:-1}"
case " ${NODE_OPTIONS:-} " in
  *" --dns-result-order="*) ;;
  *) export NODE_OPTIONS="${NODE_OPTIONS:-} --dns-result-order=ipv4first" ;;
esac

# Electron and electron-builder fetch their tool archives from GitHub releases,
# which some networks throttle. Default to the npmmirror CDN that mirrors those
# releases; set ELECTRON_MIRROR to the official URL to fetch from GitHub instead.
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_BUILDER_BINARIES_MIRROR="${ELECTRON_BUILDER_BINARIES_MIRROR:-https://npmmirror.com/mirrors/electron-builder-binaries/}"

step "Resolving the pinned pnpm"
PINNED_PNPM="$(node -p "require('./package.json').packageManager.split('@').pop()")"
PNPM=()
if [[ -x "$ROOT/node_modules/.bin/pnpm" ]]; then
  PNPM=("$ROOT/node_modules/.bin/pnpm")
elif command -v corepack >/dev/null 2>&1; then
  # Keep the Corepack cache outside the checkout so the build's git-state stamp
  # stays clean; an explicit COREPACK_HOME still wins.
  COREPACK_HOME="${COREPACK_HOME:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/dsh-corepack}"
  mkdir -p "$COREPACK_HOME"
  export COREPACK_HOME
  corepack prepare "pnpm@$PINNED_PNPM" --activate >/dev/null
  PNPM=(corepack pnpm)
elif command -v pnpm >/dev/null 2>&1 && [[ "$(pnpm --version 2>/dev/null | tail -n 1)" == "$PINNED_PNPM" ]]; then
  PNPM=(pnpm)
else
  die "pnpm@$PINNED_PNPM is unavailable. Enable Corepack ('corepack enable') or install pnpm."
fi
printf 'pnpm: %s\n' "$("${PNPM[@]}" --version 2>/dev/null | tail -n 1)"

restore_config() {
  if [[ -n "${XLSX_BACKUP_DIR:-}" && -d "${XLSX_BACKUP_DIR:-}" ]]; then
    cp "$XLSX_BACKUP_DIR/pnpm-workspace.yaml" "$ROOT/pnpm-workspace.yaml"
    cp "$XLSX_BACKUP_DIR/pnpm-lock.yaml" "$ROOT/pnpm-lock.yaml"
    rm -rf "$XLSX_BACKUP_DIR"
    XLSX_BACKUP_DIR=""
    printf 'Restored pnpm-workspace.yaml and pnpm-lock.yaml.\n'
    printf 'Note: node_modules keeps the SheetJS fallback package; pnpm may report it out of sync\n'
    printf 'until cdn.sheetjs.com is reachable again.\n'
  fi
}

# cdn.sheetjs.com is unreachable from some networks. The official dependency is a
# URL tarball, so a mirror needs an explicit override; restore the repository
# files before the build so its git-state stamp sees a clean tree.
apply_xlsx_fallback() {
  [[ "$ALLOW_XLSX_FALLBACK" == "1" ]] || return 1
  step "Applying the SheetJS CDN fallback ($XLSX_FALLBACK_SPEC)"
  warn "cdn.sheetjs.com could not be fetched; using $XLSX_FALLBACK_SPEC for this install."
  warn "The workspace config and lockfile are restored after installation."
  XLSX_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-xlsx-backup.XXXXXX")"
  cp "$ROOT/pnpm-workspace.yaml" "$XLSX_BACKUP_DIR/pnpm-workspace.yaml"
  cp "$ROOT/pnpm-lock.yaml" "$XLSX_BACKUP_DIR/pnpm-lock.yaml"
  trap restore_config EXIT
  if ! grep -qE '^[[:space:]]+xlsx:' "$ROOT/pnpm-workspace.yaml"; then
    awk -v spec="$XLSX_FALLBACK_SPEC" '
      BEGIN { inserted = 0 }
      /^overrides:[[:space:]]*$/ && !inserted {
        print
        print "  xlsx: \"" spec "\""
        inserted = 1
        next
      }
      { print }
      END {
        if (!inserted) {
          print ""
          print "overrides:"
          print "  xlsx: \"" spec "\""
        }
      }
    ' "$ROOT/pnpm-workspace.yaml" > "$ROOT/pnpm-workspace.yaml.tmp"
    mv "$ROOT/pnpm-workspace.yaml.tmp" "$ROOT/pnpm-workspace.yaml"
  fi
}

install_dependencies() {
  step "Installing locked dependencies"
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/dsh-install.XXXXXX")"
  if "${PNPM[@]}" install --frozen-lockfile 2>&1 | tee "$log"; then
    rm -f "$log"
    return 0
  fi
  if grep -q 'sheetjs' "$log" && apply_xlsx_fallback; then
    if "${PNPM[@]}" install --no-frozen-lockfile; then
      rm -f "$log"
      # Keep the fallback override in place until packaging ends: the restored
      # lockfile would no longer match node_modules and pnpm would try to
      # reinstall implicitly before every script.
      return 0
    fi
  fi
  rm -f "$log"
  die "pnpm install failed. Fix the reported network or dependency error and retry."
}

if [[ "$SKIP_INSTALL" == "0" ]]; then
  install_dependencies
  if [[ -x "$ROOT/node_modules/.bin/pnpm" ]]; then
    PNPM=("$ROOT/node_modules/.bin/pnpm")
  fi
else
  [[ -d "$ROOT/node_modules" ]] || die "--skip-install was passed but node_modules does not exist."
fi

step "Building repository artifacts"
"${PNPM[@]}" run build

step "Verifying the CLI"
"${PNPM[@]}" dsh --version

if [[ "$BUILD_ONLY" == "1" ]]; then
  step "Build complete (Desktop packaging skipped)"
  printf 'Web artifacts: %s\n' "$ROOT/apps/web/dist"
  exit 0
fi

step "Pre-fetching the locked Desktop runtime payload"
if ! node "$ROOT/scripts/prefetch-macos-x64-runtime.mjs" "$ROOT"; then
  warn "runtime pre-fetch was incomplete; the packaging step will retry the missing assets."
fi

step "Packaging the unsigned macOS x64 Desktop app"
"${PNPM[@]}" run package:desktop:mac:x64:unsigned
restore_config
trap - EXIT

step "Done"
if [[ -d "$ARTIFACTS_DIR" ]]; then
  (cd "$ARTIFACTS_DIR" && shasum -a 256 ./*.dmg > SHA256SUMS)
  ls -lh "$ARTIFACTS_DIR"
  cat "$ARTIFACTS_DIR/SHA256SUMS"
  printf '\nUnsigned artifacts: %s\n' "$ARTIFACTS_DIR"
  printf 'The build is unsigned (ad-hoc signed only): on first launch use right-click > Open, or run\n'
  printf '  xattr -dr com.apple.quarantine "%s"/*.dmg\n' "$ARTIFACTS_DIR"
else
  die "packaging reported success but $ARTIFACTS_DIR does not exist."
fi
