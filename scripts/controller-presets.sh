#!/usr/bin/env bash
# Sync per-app controller mappings between this repo and the PlayCover container.
# Presets in presets/EmulatedController/ also ship inside PlayCover.app and are applied automatically
# when a game is installed, so this script is only needed to contribute a preset or to install one by hand.
#
# Usage: scripts/controller-presets.sh pull [--all | bundleId...]
#        scripts/controller-presets.sh install [bundleId... | path/to/<bundleId>.plist...]
#   pull     Copy <container>/EmulatedController/<id>.plist into presets/EmulatedController/.
#            No ids: refresh every preset already in the repo; --all: every plist in the container
#   install  Copy plists into <container>/EmulatedController/ (created if missing). An arg ending in
#            .plist is a file from anywhere (e.g. another source), installed under its file name;
#            other args are repo preset ids. No args: all repo presets. A different existing file is
#            first backed up as <id>.plist.bak next to it (an older .bak is overwritten)
# Every file is checked with `plutil -lint` first; invalid ones are skipped and reported. Unchanged
# files (cmp) are skipped too. One line per file; the exit code is non-zero if any file failed or a
# named id/file has no source file.
# Env vars:
#   PLAYCOVER_CONTAINER  PlayCover container dir (default: $HOME/Library/Containers/io.playcover.PlayCover)
#
# Note: games are sandboxed to the container, so symlinks into the repo cannot work, and PlayCover
# writes the plist atomically (a symlink would be replaced). Hence the copy.
# Note: PlayTools live-reloads the mapping, so `install` applies to a running game. Close PlayCover's
# Controller tab for that app first, or it may overwrite the installed file on its next edit.
set -euo pipefail

usage() { echo "Usage: $0 pull [--all | bundleId...] | install [bundleId... | file.plist...]" >&2; }

PLAYCOVER_CONTAINER="${PLAYCOVER_CONTAINER:-$HOME/Library/Containers/io.playcover.PlayCover}"
CONTAINER_DIR="$PLAYCOVER_CONTAINER/EmulatedController"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$REPO_ROOT/presets/EmulatedController"

# Parse all args up front so a bad one fails before any file is touched.
[[ $# -ge 1 ]] || { usage; exit 1; }
command="$1"; shift
all=0
if [[ "${1:-}" == "--all" ]]; then
  [[ "$command" == pull && $# -eq 1 ]] || { usage; exit 1; }
  all=1
  shift
fi
case "$command" in
  # Without ids: pull refreshes what the repo already tracks, install pushes everything in the repo.
  pull)    src_dir="$CONTAINER_DIR"; dst_dir="$REPO_DIR"; verb=pulled;    backup=0
           if [[ "$all" -eq 1 ]]; then default_ids_dir="$CONTAINER_DIR"; else default_ids_dir="$REPO_DIR"; fi
           for arg in "$@"; do
             [[ "$arg" != *.plist ]] || { echo "error: pull takes bundle ids, not files: $arg" >&2; exit 1; }
           done ;;
  install) src_dir="$REPO_DIR"; dst_dir="$CONTAINER_DIR"; verb=installed; backup=1
           default_ids_dir="$REPO_DIR" ;;
  *) usage; exit 1 ;;
esac

# Bundle ids of every plist in a dir (empty when none).
list_ids() {
  local file
  for file in "$1"/*.plist; do
    [[ -e "$file" ]] || continue
    basename "$file" .plist
  done
}

failed=0

# Lint, then copy one plist (an id in $src_dir, or a .plist path); prints one status line.
# Failures set $failed and keep going.
sync_one() {
  local src id dst
  if [[ "$1" == *.plist ]]; then
    src="$1"; id="$(basename "$1" .plist)"
  else
    src="$src_dir/$1.plist"; id="$1"
  fi
  dst="$dst_dir/$id.plist"
  if [[ ! -f "$src" ]]; then
    echo "error: $src not found" >&2
    failed=1
    return 0
  fi
  if ! plutil -lint "$src" >/dev/null 2>&1; then
    echo "skipped   $id (invalid plist)"
    failed=1
    return 0
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    echo "unchanged $id"
    return 0
  fi
  if [[ "$backup" -eq 1 && -f "$dst" ]]; then cp "$dst" "$dst.bak"; fi
  cp "$src" "$dst"
  echo "$verb $id"
}

mkdir -p "$dst_dir"

if [[ $# -gt 0 ]]; then
  ids=("$@")
else
  ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(list_ids "$default_ids_dir")
fi

if [[ "${#ids[@]}" -eq 0 ]]; then
  echo "No plists found in $default_ids_dir"
else
  for id in "${ids[@]}"; do sync_one "$id"; done
fi

exit "$failed"
