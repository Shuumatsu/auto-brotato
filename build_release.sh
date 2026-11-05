#!/usr/bin/env bash
# Build ONE distributable release zip:
#   - mods-unpacked/...      : ModLoader mod (local install AND Workshop content)
#   - preview.png            : Workshop preview
#   - description.txt        : Workshop description (BBCode)
#   - README.md              : promotional readme
#   - README-FORK.md, LICENSE-BOTato-MIT.txt (already included by build.sh)
#   - INSTALL.txt            : how to install / upload
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
VERSION="$(python3 -c 'import json;print(json.load(open("mod/mods-unpacked/Pasha-AutoBattler/manifest.json"))["version_number"])')"
bash build.sh >/dev/null
MOD_ZIP="$ROOT/dist/AutoBattler-${VERSION}-fork.zip"
OUT="$ROOT/dist/AutoBattler-v${VERSION}.zip"
[ -f "$MOD_ZIP" ] || { echo "missing $MOD_ZIP" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bundle"
unzip -q "$MOD_ZIP" -d "$TMP/bundle"
cp "$ROOT/workshop/preview.png" "$TMP/bundle/preview.png"
cp "$ROOT/workshop/description.txt" "$TMP/bundle/description.txt"
cp "$ROOT/README.md" "$TMP/bundle/README.md"
cat > "$TMP/bundle/INSTALL.txt" <<TXT
AutoBattler ${VERSION} — Brotato movement autopilot (decisions stay manual)

This single zip contains:
  mods-unpacked/          the ModLoader mod (works for local install and Workshop upload)
  preview.png             Workshop preview image
  description.txt         Workshop description (BBCode)
  README.md / README-FORK.md / LICENSE-BOTato-MIT.txt

Local install (Steam):
  Put this zip into any subscribed Workshop item folder:
  steamapps/workshop/content/1942280/<item>/
  then start Brotato through Steam.

Steam Workshop upload/update:
  Use GodotWorkshopUtility, select THIS zip, enter Workshop ID 3834096920,
  and select preview.png separately when the tool asks for a preview image.
TXT
rm -f "$OUT"
( cd "$TMP/bundle" && zip -qr -X "$OUT" . )
echo "Built release bundle: $OUT"
unzip -l "$OUT" | tail -6
