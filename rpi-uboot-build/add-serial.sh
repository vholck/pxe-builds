#!/bin/bash
set -eu

: "${1:?Usage: add-serial.sh <MODEL> <SERIAL> [OUT_DIR]}"
: "${2:?Usage: add-serial.sh <MODEL> <SERIAL> [OUT_DIR]}"
MODEL="$1"
SERIAL="$2"
OUT_DIR="${3:-./out}"
GENERIC="$OUT_DIR/generic-${MODEL}"

if [ ! -d "$GENERIC" ]; then
  echo "ERROR: $GENERIC not found — run the build first (MODEL=${MODEL})"
  exit 1
fi

if [ -d "$OUT_DIR/tftp/$SERIAL" ]; then
  echo "Serial $SERIAL already exists at $OUT_DIR/tftp/$SERIAL"
  exit 0
fi

mkdir -p "$OUT_DIR/tftp/$SERIAL/overlays"

for f in "$GENERIC"/*.bin "$GENERIC"/*.elf "$GENERIC"/*.dat "$GENERIC"/*.txt "$GENERIC"/*.scr "$GENERIC"/*.dtb; do
  [ -f "$f" ] || continue
  cp "$f" "$OUT_DIR/tftp/$SERIAL/$(basename "$f")"
done

for f in "$GENERIC/overlays"/*.dtbo; do
  [ -f "$f" ] || continue
  cp "$f" "$OUT_DIR/tftp/$SERIAL/overlays/$(basename "$f")"
done

echo "Created $OUT_DIR/tftp/$SERIAL"
