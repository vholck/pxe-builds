#!/bin/sh
# Entry point of the rpi-uboot stage image (Dockerfile.stage). Runs on the boot
# host when the pxe stack starts and publishes the prebuilt Raspberry Pi boot
# files (firmware, device trees, U-Boot, shared config.txt) into the TFTP root.
set -eu

SRC=/assets/tftp
OUT=/out

echo "[rpi-uboot-stage] publishing to the TFTP root:"
cat "$SRC"/build-info/rpi-uboot/*.txt 2>/dev/null || true

# Copy to a temporary name and rename, so a client never downloads a half-written
# file. Anything else in the TFTP root, including per-device {serial}/ override
# directories, is left alone. config.txt and its copy tryboot.txt go last: they
# point at rpi/, which has to be complete before a Pi reads them.
# Ownership is set file by file, on what this script wrote. The three stage
# containers of the pxe stack run at the same time on the same directory: a
# "chown -R" over all of it fails when another stage renames one of its
# temporary files in that moment, and a failed stage keeps dnsmasq from starting.
own() { chown "${PUID:-500}:${PGID:-500}" "$@"; }

cd "$SRC"
{ find . -type f ! -path ./config.txt ! -path ./tryboot.txt; echo ./config.txt; echo ./tryboot.txt; } | while read -r f; do
  f=${f#./}
  mkdir -p "$OUT/$(dirname "$f")"
  cp "$f" "$OUT/$f.stage-tmp"
  own "$OUT/$f.stage-tmp"
  mv -f "$OUT/$f.stage-tmp" "$OUT/$f"
done
# the directories those files are in
find . -type d | while read -r d; do own "$OUT/$d"; done

# Remove files an earlier version of this image published and this one no longer
# ships. Only names from the manifest the previous run left behind are touched,
# so hand-placed files and other images' files are safe. Before the first
# manifest existed the files below were published to the TFTP root; they moved
# to rpi/ and build-info/rpi-uboot/.
MANIFEST=$OUT/build-info/rpi-uboot/published-files
LEGACY="u-boot-rpi3.bin u-boot-rpi4.bin u-boot-rpi5.bin rpi3.txt rpi4.txt rpi5.txt
bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-cm3.dtb
bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb bcm2711-rpi-cm4.dtb bcm2712-rpi-5-b.dtb
overlays/miniuart-bt.dtbo"
find . -type f | sed 's|^\./||' | sort > /tmp/published-files
if [ -f "$MANIFEST" ]; then
  cat "$MANIFEST"
else
  # shellcheck disable=SC2086  # word splitting is intended: one name per line
  printf '%s\n' $LEGACY
fi | while read -r f; do
  case "$f" in ''|/*|*..*) continue ;; esac
  grep -qxF "$f" /tmp/published-files && continue
  [ -f "$OUT/$f" ] || continue
  rm -f "$OUT/$f"
  echo "[rpi-uboot-stage] removed $f (no longer published)"
  # drop directories this left empty
  d=$(dirname "$f")
  while [ "$d" != . ] && rmdir "$OUT/$d" 2>/dev/null; do d=$(dirname "$d"); done
done
cp /tmp/published-files "$MANIFEST.stage-tmp"
own "$MANIFEST.stage-tmp"
mv -f "$MANIFEST.stage-tmp" "$MANIFEST"

echo "[rpi-uboot-stage] done"
