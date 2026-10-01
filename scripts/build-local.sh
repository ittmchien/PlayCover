#!/usr/bin/env bash
# Build PlayCover + PlayTools from source without Apple signing certs.
#
# Usage: scripts/build-local.sh [--install] [--package]
# By default the app is built and packaged (no install).
#   --install  Install instead: replace $INSTALL_DIR/PlayCover.app (an official copy is kept at
#              build/PlayCover.previous.app); skips packaging unless --package is also given
#   --package  Create $PACKAGE_DIR/PlayCover-<version>-<git sha>.zip and .dmg of the built app for
#              sharing (the default; only needed alongside --install)
#
# A preflight first checks the environment (arm64, tools, Xcode); only if that passes are the
# directories below checked, and on a terminal only one that fails is asked for (empty aborts).
# Env vars:
#   PLAYTOOLS_DIR  Local PlayTools clone to build (default: PlayTools next to this repo)
#   DEVELOPER_DIR  Xcode developer dir (default: /Applications/Xcode.app/Contents/Developer, else
#                  `xcode-select -p` if it is a full Xcode, else the first /Applications/Xcode*.app)
#   PACKAGE_DIR    Where the zip/dmg go, when packaging (default: build)
#   INSTALL_DIR    Where PlayCover.app is installed, with --install (default: /Applications)
#
# Note: PlayTools is built directly via xcodebuild, not carthage -- Carthage
# 0.40 + Xcode 26.5 finishes silently with an empty Carthage/Build.
# Note: the build is ad-hoc signed and not notarized; other Apple Silicon Macs
# must clear the quarantine attribute before launching it.
set -euo pipefail

usage() { echo "Usage: $0 [--install] [--package]" >&2; }

# Parse all args up front so a bad one fails before any build work starts.
INSTALL=0
PACKAGE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --package) PACKAGE=1 ;;
    *) usage; exit 1 ;;
  esac
done
# Package by default; installing is opt-in and replaces packaging unless --package is also given.
[[ "$INSTALL" -eq 1 ]] || PACKAGE=1

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Directory settings: env var or default, never prompted here (the preflight asks only on failure).
PLAYTOOLS_DIR="${PLAYTOOLS_DIR:-$(dirname "$PWD")/PlayTools}"
PACKAGE_DIR="${PACKAGE_DIR:-build}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# Skip SwiftLint/Carthage run-script phases in both projects (same switch upstream CI uses).
export FASTLANE=1

mkdir -p build

# Preflight: collect every problem first, then print them all with fix hints and exit once.
echo "==> Preflight"
problems=()
fail() { problems+=("$1 — $2"); }
exit_if_problems() {
  [[ "${#problems[@]}" -eq 0 ]] && return 0
  for problem in "${problems[@]}"; do echo "  ✗ $problem" >&2; done
  exit 1
}

# DerivedData embeds absolute paths; a moved repo breaks incremental builds, so clear it (not an error).
if [[ -d build/DerivedData && "$(cat build/.repo-path 2>/dev/null || true)" != "$PWD" ]]; then
  rm -rf build/DerivedData build/PlayTools-DD
  echo "==> Repo moved; cleared stale DerivedData"
fi
echo "$PWD" > build/.repo-path

# Step 1: blocking environment checks, never prompted. PlayCover/PlayTools target Apple Silicon.
[[ "$(uname -m)" == arm64 ]] || fail "not an Apple Silicon Mac (uname -m: $(uname -m))" "build on an arm64 Mac"

# Tools used later; hdiutil and PlistBuddy are only needed when packaging.
required_tools=(git ditto codesign)
[[ "$PACKAGE" -eq 0 ]] || required_tools+=(hdiutil)
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || fail "missing tool: $tool" "install Xcode Command Line Tools: xcode-select --install"
done
if [[ "$PACKAGE" -eq 1 && ! -x /usr/libexec/PlistBuddy ]]; then
  fail "missing /usr/libexec/PlistBuddy" "it ships with macOS; check the system install"
fi

# Xcode: DEVELOPER_DIR env wins; else the first usable of the default, `xcode-select -p`, Xcode*.app.
xcode_usable() { [[ -d "$1" ]] && "$1/usr/bin/xcodebuild" -version >/dev/null 2>&1; }
selected_dev_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  for candidate in "$DEVELOPER_DIR" "$selected_dev_dir" /Applications/Xcode*.app/Contents/Developer; do
    if xcode_usable "$candidate"; then DEVELOPER_DIR="$candidate"; break; fi
  done
fi
export DEVELOPER_DIR
if xcode_usable "$DEVELOPER_DIR"; then
  xcodebuild_bin="$DEVELOPER_DIR/usr/bin/xcodebuild"
  "$xcodebuild_bin" -checkFirstLaunchStatus >/dev/null 2>&1 \
    || fail "Xcode first launch / license not completed" "run: sudo xcodebuild -runFirstLaunch (and sudo xcodebuild -license accept)"
  # Capture first: `xcodebuild | grep -q` under pipefail fails on SIGPIPE.
  sdks="$("$xcodebuild_bin" -showsdks 2>/dev/null || true)"
  [[ "$sdks" == *iphoneos* ]] \
    || fail "iOS platform SDK not installed" "install the iOS platform in Xcode -> Settings -> Components"
else
  xcode_hint="install Xcode from the App Store or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer"
  if [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools* || "$selected_dev_dir" == /Library/Developer/CommandLineTools* ]]; then
    xcode_hint="$xcode_hint (Command Line Tools alone are not enough)"
  fi
  fail "Xcode not usable at DEVELOPER_DIR=$DEVELOPER_DIR" "$xcode_hint"
fi
exit_if_problems

# Step 2: directory inputs. Each check prints "problem — hint" and returns 1 when the dir is unusable.
check_playtools_dir() {
  git -C "$PLAYTOOLS_DIR" rev-parse --git-dir >/dev/null 2>&1 && return 0
  echo "PlayTools git clone not found at $PLAYTOOLS_DIR — git clone https://github.com/PlayCover/PlayTools.git \"$PLAYTOOLS_DIR\", or choose another path (PLAYTOOLS_DIR)"
  return 1
}
# The package dir is created if missing.
check_package_dir() {
  mkdir -p "$PACKAGE_DIR" 2>/dev/null && [[ -w "$PACKAGE_DIR" ]] && return 0
  echo "package dir $PACKAGE_DIR cannot be created or written — choose a writable path or set PACKAGE_DIR"
  return 1
}
check_install_dir() {
  [[ -d "$INSTALL_DIR" && -w "$INSTALL_DIR" ]] && return 0
  echo "install dir $INSTALL_DIR is missing or not writable — create it, fix its permissions, or set INSTALL_DIR"
  return 1
}

# Run one directory check; on a terminal ask for a new path until it passes (empty answer aborts),
# otherwise record the problem.
validate_dir() {
  local var="$1" check="$2" label="$3" msg input
  until msg="$("$check")"; do
    if [[ ! -t 0 ]]; then problems+=("$msg"); return 0; fi
    echo "  ✗ $msg" >&2
    read -r -p "$label not found at ${!var}. Enter path (empty to abort): " input || input=""
    if [[ -z "$input" ]]; then echo "Aborted." >&2; exit 1; fi
    # Expand a leading ~ (read does not).
    if [[ "$input" == "~" || "$input" == "~/"* ]]; then input="$HOME${input:1}"; fi
    printf -v "$var" '%s' "$input"
  done
}
validate_dir PLAYTOOLS_DIR check_playtools_dir "PlayTools source dir"
if [[ "$PACKAGE" -eq 1 ]]; then validate_dir PACKAGE_DIR check_package_dir "Package output dir"; fi
if [[ "$INSTALL" -eq 1 ]]; then validate_dir INSTALL_DIR check_install_dir "Install dir"; fi
exit_if_problems
echo "  ✓ all checks passed"
# Absolute path so the "Packaged:" messages stay correct for any PACKAGE_DIR.
if [[ "$PACKAGE" -eq 1 ]]; then PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"; fi

# Run a build command, logging its output; on failure print the log tail + message and exit.
run_logged() {
  local logfile="$1" message="$2"; shift 2
  if command -v xcbeautify >/dev/null; then
    "$@" | xcbeautify
  elif ! "$@" >"$logfile" 2>&1; then
    tail -n 30 "$logfile"
    echo "$message" >&2
    exit 1
  fi
}

echo "==> Using local PlayTools: $PLAYTOOLS_DIR @ $(git -C "$PLAYTOOLS_DIR" rev-parse --short HEAD)"
if [[ -n "$(git -C "$PLAYTOOLS_DIR" status --porcelain)" ]]; then
  echo "    (dirty: building uncommitted changes)"
fi

echo "==> Building PlayTools (Release)"
run_logged build/playtools.log "PlayTools build failed. Full log: build/playtools.log" \
  xcodebuild -project "$PLAYTOOLS_DIR/PlayTools.xcodeproj" -scheme PlayTools -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/PlayTools-DD CODE_SIGNING_ALLOWED=NO build

# Package the built framework into the xcframework PlayCover's "Copy Carthage frameworks" phase reads.
mkdir -p Carthage/Build
rm -rf Carthage/Build/PlayTools.xcframework
xcodebuild -create-xcframework -allow-internal-distribution \
  -framework build/PlayTools-DD/Build/Products/Release-iphoneos/PlayTools.framework \
  -output Carthage/Build/PlayTools.xcframework
[[ -d Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework/PlugIns/AKInterface.bundle ]] || {
  echo "PlayTools.xcframework is missing PlugIns/AKInterface.bundle; build produced an incomplete framework." >&2
  exit 1
}

# FASTLANE=1 skips the SwiftLint and Carthage Bootstrap phases (the latter would clobber local PlayTools).
XCODEBUILD_ARGS=(
  -project PlayCover.xcodeproj -scheme PlayCover -configuration Release
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' build
  FASTLANE=1 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
  # Hardened runtime's library validation rejects ad-hoc embedded frameworks (no Team ID) -> crash on launch.
  ENABLE_HARDENED_RUNTIME=NO
)
echo "==> Building PlayCover (Release)"
run_logged build/xcodebuild.log "Build failed. Full log: build/xcodebuild.log" \
  xcodebuild "${XCODEBUILD_ARGS[@]}"

APP_PATH="build/DerivedData/Build/Products/Release/PlayCover.app"
codesign --verify --deep --strict "$APP_PATH" || echo "warning: codesign verify failed (expected for ad-hoc builds)" >&2
echo "==> Built: $PWD/$APP_PATH"

# Zip + dmg for sharing; the version is read from the built app, plus the git sha to tell builds apart.
if [[ "$PACKAGE" -eq 1 ]]; then
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")-$(git rev-parse --short HEAD)"
  zip_path="$PACKAGE_DIR/PlayCover-$version.zip"
  dmg_path="$PACKAGE_DIR/PlayCover-$version.dmg"
  echo "==> Packaging PlayCover $version"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"
  hdiutil create -volname PlayCover -srcfolder "$APP_PATH" -ov -format UDZO "$dmg_path" >/dev/null
  echo "==> Packaged: $zip_path"
  echo "==> Packaged: $dmg_path"
  echo "On the receiving Mac: drag to /Applications, then run: xattr -dr com.apple.quarantine /Applications/PlayCover.app"
fi

if [[ "$INSTALL" -eq 0 ]]; then
  echo "To install: scripts/build-local.sh --install"
  exit 0
fi

# Install target comes from INSTALL_DIR; the official-app backup stays in build/.
INSTALLED_APP="$INSTALL_DIR/PlayCover.app"
osascript -e 'quit app "PlayCover"' || true
# Back up only an officially signed app (once); a previous local ad-hoc build is simply replaced.
if [[ -d "$INSTALLED_APP" ]]; then
  # Capture first: `codesign | grep -q` under pipefail fails on SIGPIPE and would pick the wrong branch.
  installed_sig="$(codesign -dv "$INSTALLED_APP" 2>&1 || true)"
  if [[ "$installed_sig" == *"Signature=adhoc"* ]]; then
    rm -rf "$INSTALLED_APP"
  else
    rm -rf build/PlayCover.previous.app
    mv "$INSTALLED_APP" build/PlayCover.previous.app
  fi
fi
ditto "$APP_PATH" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" || true
echo "Installed. Launch PlayCover once so it installs the new PlayTools into ~/Library/Frameworks."
