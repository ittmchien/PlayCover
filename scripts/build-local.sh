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
# Flow: machine checks -> Xcode -> PlayTools source -> output dirs -> summary -> build. Nothing is
# asked before the unfixable checks pass; on a terminal only a failing input is asked for.
# PlayTools source, first match wins:
#   1. PLAYTOOLS_DIR, if set
#   2. PlayTools next to this repo (developer setup; built as-is)
#   3. a fresh copy of the fork in vendor/PlayTools (git clone --depth 1, else the branch zip);
#      on a terminal you are asked first [Y/n] and "n" asks for a local path. This copy and
#      build/PlayTools-DD are removed when the script exits (also on failure or Ctrl-C); a leftover
#      from an interrupted run is replaced without asking.
# Env vars:
#   PLAYTOOLS_DIR       Local PlayTools source to build (must contain PlayTools.xcodeproj)
#   PLAYTOOLS_REPO_URL  Fork fetched into vendor/ (default: https://github.com/ittmchien/PlayTools.git)
#   PLAYTOOLS_BRANCH    Branch fetched into vendor/ (default: master)
#   DEVELOPER_DIR       Xcode developer dir (default: /Applications/Xcode.app/Contents/Developer, else
#                       `xcode-select -p` if it is a full Xcode, else the first /Applications/Xcode*.app)
#   PACKAGE_DIR         Where the zip/dmg go, when packaging (default: build)
#   INSTALL_DIR         Where PlayCover.app is installed, with --install (default: /Applications)
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

# Settings: env var or default, never prompted here (the preflight asks only on failure).
PLAYTOOLS_REPO_URL="${PLAYTOOLS_REPO_URL:-https://github.com/ittmchien/PlayTools.git}"
PLAYTOOLS_BRANCH="${PLAYTOOLS_BRANCH:-master}"
VENDOR_PLAYTOOLS=vendor/PlayTools
PACKAGE_DIR="${PACKAGE_DIR:-build}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# Skip SwiftLint/Carthage run-script phases in both projects (same switch upstream CI uses).
export FASTLANE=1

mkdir -p build

# DerivedData embeds absolute paths; a moved repo breaks incremental builds, so clear it (not an error).
if [[ -d build/DerivedData && "$(cat build/.repo-path 2>/dev/null || true)" != "$PWD" ]]; then
  rm -rf build/DerivedData build/PlayTools-DD
  echo "==> Repo moved; cleared stale DerivedData"
fi
echo "$PWD" > build/.repo-path

# Shared helpers.
has() { command -v "$1" >/dev/null; }
is_tty() { [[ -t 0 ]]; }
# Expand a leading ~ (read does not).
expand_tilde() {
  if [[ "$1" == "~" || "$1" == "~/"* ]]; then echo "$HOME${1:1}"; else echo "$1"; fi
}
# Short HEAD sha of a dir that is itself a git checkout; fails without git or for a plain copy.
git_rev() { [[ -e "$1/.git" ]] && has git && git -C "$1" rev-parse --short HEAD 2>/dev/null; }

# The fetched vendor copy is temporary: remove it (and its build intermediates) on any exit.
CLEANUP_VENDOR=0
cleanup_vendor() {
  [[ "$CLEANUP_VENDOR" -eq 1 ]] || return 0
  rm -rf "$VENDOR_PLAYTOOLS" vendor/.PlayTools.* build/PlayTools-DD
  rmdir vendor 2>/dev/null || true
  echo "==> Removed vendor/PlayTools to free disk space"
}
trap cleanup_vendor EXIT

# Preflight: collect every problem first, then print them all with fix hints and exit once.
echo "==> Preflight"
problems=()
fail() { problems+=("$1 — $2"); }
exit_if_problems() {
  [[ "${#problems[@]}" -eq 0 ]] && return 0
  for problem in "${problems[@]}"; do echo "  ✗ $problem" >&2; done
  exit 1
}

# Step 1: machine checks, never prompted. PlayCover/PlayTools target Apple Silicon.
[[ "$(uname -m)" == arm64 ]] || fail "not an Apple Silicon Mac (uname -m: $(uname -m))" "build on an arm64 Mac"
# Tools used later (ditto also installs); hdiutil and PlistBuddy are only needed when packaging.
# git is optional and curl is checked only if a download happens.
required_tools=(codesign ditto)
[[ "$PACKAGE" -eq 0 ]] || required_tools+=(hdiutil)
for tool in "${required_tools[@]}"; do
  has "$tool" || fail "missing tool: $tool" "install Xcode Command Line Tools: xcode-select --install"
done
if [[ "$PACKAGE" -eq 1 && ! -x /usr/libexec/PlistBuddy ]]; then
  fail "missing /usr/libexec/PlistBuddy" "it ships with macOS; check the system install"
fi
exit_if_problems

# Step 2: Xcode. DEVELOPER_DIR env wins; else the first usable of the default, `xcode-select -p`,
# Xcode*.app. If none works, a terminal is asked for a path; otherwise it fails with a hint.
xcode_usable() { [[ -d "$1" ]] && "$1/usr/bin/xcodebuild" -version >/dev/null 2>&1; }
selected_dev_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  for candidate in "$DEVELOPER_DIR" "$selected_dev_dir" /Applications/Xcode*.app/Contents/Developer; do
    if xcode_usable "$candidate"; then DEVELOPER_DIR="$candidate"; break; fi
  done
fi

# Ask for Xcode.app or its Contents/Developer until xcodebuild runs (empty answer aborts).
ask_developer_dir() {
  local input
  while true; do
    read -r -p "Xcode not found. Enter path to Xcode.app or its Contents/Developer (empty to abort): " input || input=""
    if [[ -z "$input" ]]; then echo "Aborted." >&2; exit 1; fi
    input="$(expand_tilde "$input")"
    if [[ -d "$input/Contents/Developer" ]]; then input="$input/Contents/Developer"; fi
    DEVELOPER_DIR="$input"
    xcode_usable "$DEVELOPER_DIR" && return 0
    echo "  ✗ xcodebuild not usable at $DEVELOPER_DIR" >&2
  done
}

if ! xcode_usable "$DEVELOPER_DIR"; then
  if is_tty; then
    ask_developer_dir
  else
    xcode_hint="install Xcode from the App Store or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer"
    if [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools* || "$selected_dev_dir" == /Library/Developer/CommandLineTools* ]]; then
      xcode_hint="$xcode_hint (Command Line Tools alone are not enough)"
    fi
    fail "Xcode not usable at DEVELOPER_DIR=$DEVELOPER_DIR" "$xcode_hint"
    exit_if_problems
  fi
fi
export DEVELOPER_DIR

# Xcode health: both are unfixable here, so fail before asking anything else.
xcodebuild_bin="$DEVELOPER_DIR/usr/bin/xcodebuild"
"$xcodebuild_bin" -checkFirstLaunchStatus >/dev/null 2>&1 \
  || fail "Xcode first launch / license not completed" "run: sudo xcodebuild -runFirstLaunch (and sudo xcodebuild -license accept)"
# Capture first: `xcodebuild | grep -q` under pipefail fails on SIGPIPE.
sdks="$("$xcodebuild_bin" -showsdks 2>/dev/null || true)"
[[ "$sdks" == *iphoneos* ]] \
  || fail "iOS platform SDK not installed" "install the iOS platform in Xcode -> Settings -> Components"
exit_if_problems

# Step 3: PlayTools source. PLAYTOOLS_KIND labels it in the summary.
is_playtools_dir() { [[ -d "$1/PlayTools.xcodeproj" ]]; }

# Print the downloaded source dir under $1: a shallow clone when git exists, else the branch zip.
download_playtools() {
  local tmp="$1" archive_url top
  if has git; then
    git clone --quiet --depth 1 --branch "$PLAYTOOLS_BRANCH" "$PLAYTOOLS_REPO_URL" "$tmp/PlayTools" >&2 || return 1
    echo "$tmp/PlayTools"
    return 0
  fi
  if ! has curl; then echo "  ✗ missing tool: curl (or install git)" >&2; return 1; fi
  archive_url="${PLAYTOOLS_REPO_URL%.git}/archive/refs/heads/$PLAYTOOLS_BRANCH.zip"
  echo "    downloading $archive_url" >&2
  curl -fsSL "$archive_url" -o "$tmp/src.zip" && ditto -x -k "$tmp/src.zip" "$tmp/src" || return 1
  # GitHub archives hold a single top-level folder (PlayTools-<branch>).
  top=("$tmp"/src/*)
  [[ "${#top[@]}" -eq 1 ]] || return 1
  echo "${top[0]}"
}

# Fetch the fork into vendor/PlayTools (replacing any leftover) or exit with a hint.
fetch_playtools() {
  local tmp src
  echo "==> Fetching PlayTools ($PLAYTOOLS_BRANCH) from $PLAYTOOLS_REPO_URL into $VENDOR_PLAYTOOLS"
  CLEANUP_VENDOR=1
  rm -rf "$VENDOR_PLAYTOOLS"
  mkdir -p vendor
  tmp="$(mktemp -d vendor/.PlayTools.XXXXXX)"
  if src="$(download_playtools "$tmp")" && is_playtools_dir "$src" && mv "$src" "$VENDOR_PLAYTOOLS"; then
    rm -rf "$tmp"
    PLAYTOOLS_DIR="$PWD/$VENDOR_PLAYTOOLS"
    PLAYTOOLS_KIND="vendor zip"
    if [[ -e "$PLAYTOOLS_DIR/.git" ]]; then PLAYTOOLS_KIND="vendor git"; fi
    return 0
  fi
  echo "  ✗ could not download PlayTools — check the network, or set PLAYTOOLS_DIR to a local clone" >&2
  exit 1
}

# Ask whether to download the fork (Enter = yes); "no" asks for a local path instead. EOF aborts.
ask_playtools() {
  local answer
  while true; do
    read -r -p "PlayTools not found. Download your fork ($PLAYTOOLS_REPO_URL) into vendor/PlayTools? [Y/n]: " answer \
      || { echo "Aborted." >&2; exit 1; }
    case "$answer" in
      "" | [yY] | [yY][eE][sS]) fetch_playtools; return 0 ;;
      [nN] | [nN][oO]) ask_playtools_path; return 0 ;;
    esac
  done
}

# Ask for a local PlayTools path until it has PlayTools.xcodeproj (empty answer aborts).
ask_playtools_path() {
  local input
  while true; do
    read -r -p "Enter path to your PlayTools clone (empty to abort): " input || input=""
    if [[ -z "$input" ]]; then echo "Aborted." >&2; exit 1; fi
    input="$(expand_tilde "$input")"
    if is_playtools_dir "$input"; then
      PLAYTOOLS_DIR="$input"
      PLAYTOOLS_KIND=custom
      return 0
    fi
    echo "  ✗ no PlayTools.xcodeproj in $input" >&2
  done
}

# Resolve: PLAYTOOLS_DIR env, sibling clone, else a fresh vendor copy (asked first on a terminal).
resolve_playtools() {
  local sibling msg
  sibling="$(dirname "$PWD")/PlayTools"
  if [[ -n "${PLAYTOOLS_DIR:-}" ]]; then
    PLAYTOOLS_KIND=custom
    is_playtools_dir "$PLAYTOOLS_DIR" && return 0
    msg="no PlayTools.xcodeproj in PLAYTOOLS_DIR=$PLAYTOOLS_DIR — point it at a PlayTools clone, or unset it to download the fork"
    if ! is_tty; then problems+=("$msg"); exit_if_problems; fi
    echo "  ✗ $msg" >&2
    ask_playtools
  elif is_playtools_dir "$sibling"; then
    PLAYTOOLS_DIR="$sibling"
    PLAYTOOLS_KIND=sibling
  elif [[ -e "$VENDOR_PLAYTOOLS" ]]; then
    # Leftover from an interrupted run: replace it with a fresh copy, no need to ask.
    fetch_playtools
  elif is_tty; then
    ask_playtools
  else
    fetch_playtools
  fi
}
resolve_playtools

# Step 4: output dirs. Each check prints "problem — hint" and returns 1 when the dir is unusable.
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
    if ! is_tty; then problems+=("$msg"); return 0; fi
    echo "  ✗ $msg" >&2
    read -r -p "$label not found at ${!var}. Enter path (empty to abort): " input || input=""
    if [[ -z "$input" ]]; then echo "Aborted." >&2; exit 1; fi
    printf -v "$var" '%s' "$(expand_tilde "$input")"
  done
}
if [[ "$PACKAGE" -eq 1 ]]; then validate_dir PACKAGE_DIR check_package_dir "Package output dir"; fi
if [[ "$INSTALL" -eq 1 ]]; then validate_dir INSTALL_DIR check_install_dir "Install dir"; fi
exit_if_problems
echo "  ✓ all checks passed"
# Absolute path so the "Packaged:" messages stay correct for any PACKAGE_DIR.
if [[ "$PACKAGE" -eq 1 ]]; then PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"; fi

# Summary of what will be built and where it goes; the build starts right after (no confirmation).
outputs=""
[[ "$PACKAGE" -eq 0 ]] || outputs="$PACKAGE_DIR (package)"
[[ "$INSTALL" -eq 0 ]] || outputs="${outputs:+$outputs, }$INSTALL_DIR (install)"
echo "==> Xcode: $DEVELOPER_DIR"
echo "==> PlayTools: $PLAYTOOLS_DIR ($PLAYTOOLS_KIND)"
echo "==> Output: $outputs"

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

# A zip snapshot (or a missing git) has no sha; the dirty check needs a real git checkout.
echo "==> Using local PlayTools: $PLAYTOOLS_DIR @ $(git_rev "$PLAYTOOLS_DIR" || echo "zip snapshot")"
if git_rev "$PLAYTOOLS_DIR" >/dev/null && [[ -n "$(git -C "$PLAYTOOLS_DIR" status --porcelain)" ]]; then
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

# Zip + dmg for sharing; the version is read from the built app, plus the git sha (or "nogit").
if [[ "$PACKAGE" -eq 1 ]]; then
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")-$(git_rev . || echo nogit)"
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
