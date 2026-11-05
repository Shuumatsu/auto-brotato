#!/usr/bin/env bash
# Install / uninstall the local "AutoBattler (movement-only)" mod for Brotato.
#
# Why this is not a simple copy into <Brotato>/mods: the Steam build ships
# godot-mod-loader with `steam_workshop_enabled = true`, so it only loads zips
# from *subscribed Steam Workshop item folders*:
#   <Steam>/steamapps/workshop/content/1942280/<subscribed item id>/*.zip
# (<Brotato>/mods is only used by non-Steam builds, e.g. GOG/Epic.)
#
# This script copies the built zip next to an already-installed Workshop mod
# (the loader mounts every zip found in a subscribed item's folder). That is a
# local, reversible workaround: if Steam re-downloads/updates that Workshop
# item, just run this script again. For a permanent install, upload the zip as
# your own Workshop item (see README "安装方法 B").
#
# Usage:
#   ./install.sh                 build + install into the first suitable
#                                Workshop item folder (auto-detected)
#   ./install.sh --list          list candidate Workshop item folders
#   ./install.sh --item <id>     install into a specific Workshop item folder
#   ./install.sh --remove        remove the mod zip (all Workshop item folders)
#   ./install.sh --non-steam     install into <Brotato>/mods/ (GOG/Epic/local)
#
# Env:
#   BROTATO_DIR=<path>           override the Brotato install dir
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
VERSION="$(python3 -c 'import json;print(json.load(open("mod/mods-unpacked/Pasha-AutoBattler/manifest.json"))["version_number"])' 2>/dev/null || echo 2.3.0)"
NAME="AutoBattler-${VERSION}-fork"
STEAM_ROOT="${STEAM_ROOT:-$HOME/Library/Application Support/Steam}"
APP_ID="1942280"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

find_game_dir() {
  if [ -n "${BROTATO_DIR:-}" ] && [ -d "$BROTATO_DIR" ]; then
    echo "$BROTATO_DIR"; return 0
  fi
  local default="$STEAM_ROOT/steamapps/common/Brotato"
  if [ -d "$default" ]; then echo "$default"; return 0; fi
  # Search every library listed in libraryfolders.vdf.
  local vdf="$STEAM_ROOT/steamapps/libraryfolders.vdf"
  if [ -f "$vdf" ]; then
    local p
    while IFS= read -r p; do
      if [ -d "$p/steamapps/common/Brotato" ]; then
        echo "$p/steamapps/common/Brotato"; return 0
      fi
    done < <(grep -o '"path"[[:space:]]*"[^"]*"' "$vdf" | sed 's/.*"path"[[:space:]]*"//; s/"$//')
  fi
  return 1
}

find_workshop_dirs() {
  local game library content
  if ! game="$(find_game_dir)"; then return 1; fi
  # <library>/steamapps/common/Brotato -> <library>
  library="$(cd "$game/../.." && pwd)"
  content="$library/workshop/content/$APP_ID"
  [ -d "$content" ] || return 1
  # Only item folders that actually contain zips are candidates.
  find "$content" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r d; do
    if compgen -G "$d/*.zip" > /dev/null; then echo "$d"; fi
  done
}

pick_item_dir() {
  if [ -n "${ITEM:-}" ]; then
    local d="" x
    while IFS= read -r x; do
      if [ "$(basename "$x")" = "$ITEM" ]; then d="$x"; fi
    done < <(find_workshop_dirs || true)
    if [ -z "$d" ]; then
      echo "ERROR: workshop item '$ITEM' not found among installed item folders." >&2
      exit 1
    fi
    echo "$d"; return 0
  fi
  find_workshop_dirs | head -1
}

do_build() { ./build.sh; }

do_list() {
  echo "Brotato dir: $(find_game_dir || echo '<not found>')"
  echo "Workshop candidate item folders (contain zips):"
  find_workshop_dirs | sed 's/^/  /' || true
  echo
  echo "Install with: ./install.sh --item <id>"
}

do_remove() {
  local removed=0 d
  while IFS= read -r d; do
    if [ -f "$d/$NAME.zip" ]; then rm -f "$d/$NAME.zip"; echo "Removed: $d/$NAME.zip"; removed=1; fi
  done < <(find_workshop_dirs || true)
  if [ "$removed" = "0" ]; then echo "Nothing to remove (zip not found in any Workshop item folder)."; fi
  echo "Restart Brotato to unload the mod."
}

do_install_steam() {
  local target
  target="$(pick_item_dir)"
  if [ -z "$target" ]; then
    echo "ERROR: no installed Workshop item folder was found." >&2
    echo "Open Brotato once via Steam so its Workshop content is downloaded, then retry." >&2
    exit 1
  fi
  do_build
  cp "dist/$NAME.zip" "$target/"
  echo "Installed: $target/$NAME.zip"
  echo
  echo "Next steps:"
  echo "  1) Start Brotato *through Steam* (the loader needs the Steam Workshop context)."
  echo "  2) Start a run: the character auto-moves during waves."
  echo "  3) Shift+Space toggles autopilot (top-left HUD shows the state)."
  echo "  4) Level-up / shop / crates / continue are 100% manual."
  echo
  echo "Note: if Steam updates that Workshop item, the extra zip may be removed."
  echo "      Re-run ./install.sh to re-add it, or use a dedicated Workshop upload"
  echo "      for a permanent install (see README, 安装方法 B)."
}

do_install_nonsteam() {
  local game
  if ! game="$(find_game_dir)"; then
    echo "ERROR: Brotato install dir not found. Set BROTATO_DIR=<path>." >&2
    exit 1
  fi
  do_build
  mkdir -p "$game/mods"
  cp "dist/$NAME.zip" "$game/mods/"
  echo "Installed: $game/mods/$NAME.zip"
  echo "This path is only loaded by non-Steam builds of Brotato (GOG/Epic/local)."
}

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --remove) MODE="remove"; shift ;;
    --non-steam) MODE="nonsteam"; shift ;;
    --item) ITEM="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$MODE" in
  list) do_list ;;
  remove) do_remove ;;
  nonsteam) do_install_nonsteam ;;
  install) do_install_steam ;;
esac
