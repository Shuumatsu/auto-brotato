#!/usr/bin/env bash
# Build the local mod zip from mod/.
# Zip layout matches Steam Workshop mods: mods-unpacked/<mod>/... at the zip root.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
VERSION="2.10.0"
NAME="AutoBattler-${VERSION}-fork"
OUT="$ROOT/dist"
mkdir -p "$OUT"
rm -f "$OUT/$NAME.zip"

TMP="$(mktemp -d)"
mkdir -p "$TMP/$NAME"
cp -R mod/mods-unpacked "$TMP/$NAME/mods-unpacked"
cp mod/LICENSE "$TMP/$NAME/LICENSE-BOTato-MIT.txt"
[ -f mod/README-FORK.md ] && cp mod/README-FORK.md "$TMP/$NAME/README-FORK.md"
( cd "$TMP/$NAME" && zip -qr -X "$OUT/$NAME.zip" . )
rm -rf "$TMP"
echo "Built: $OUT/$NAME.zip"
unzip -l "$OUT/$NAME.zip" | tail -3
