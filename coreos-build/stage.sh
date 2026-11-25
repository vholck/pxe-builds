#!/bin/sh
# Runs on the boot host each time the pxe stack starts. Publishes what was built
# into this image to the TFTP root:
#   ipxe/fcos.ipxe                          boots Fedora CoreOS (live PXE)
#   ipxe/custom/custom.ipxe                 this stack's menu inside netboot.xyz
#   ipxe/coreos/fedora-coreos-stable.ipxe   newest stable release (generated in CI)
#   coreos/initrd/fedora-coreos-<version>-aarch64.cpio
#                                           Pi 5 extra initrds, last six stable releases
#   coreos/ignition/README.txt              how to add Ignition configs
#   build-info/coreos/                      what was built, from which sources
# Files in coreos/ignition/ other than the README are the user's and never touched.
set -eu

SRC=/assets/tftp
OUT=/out

own() { chown "${PUID:-500}:${PGID:-500}" "$@"; }

echo "[coreos-stage] publishing $(cat "$SRC/build-info/coreos/releases" | tr '\n' ' ')"

# Copy to a temporary name and rename, so a client never downloads a
# half-written file. Ownership file by file: the other stage containers work
# on the same directory at the same time (see ipxe-build/stage.sh).
cd "$SRC"
find . -type f | while read -r f; do
  f=${f#./}
  mkdir -p "$OUT/$(dirname "$f")"
  cp "$f" "$OUT/$f.stage-tmp"
  own "$OUT/$f.stage-tmp"
  mv -f "$OUT/$f.stage-tmp" "$OUT/$f"
done
find . -type d | while read -r d; do own "$OUT/$d"; done

# Remove files an earlier version of this image published and this one no
# longer ships (old releases' extra initrds). Only names from the manifest the
# previous run left behind are touched.
MANIFEST=$OUT/build-info/coreos/published-files
find . -type f | sed 's|^\./||' | sort > /tmp/published-files
if [ -f "$MANIFEST" ]; then
  while read -r f; do
    case "$f" in ''|/*|*..*) continue ;; esac
    grep -qxF "$f" /tmp/published-files && continue
    [ -f "$OUT/$f" ] || continue
    rm -f "$OUT/$f"
    echo "[coreos-stage] removed $f (no longer published)"
    d=$(dirname "$f")
    while [ "$d" != . ] && rmdir "$OUT/$d" 2>/dev/null; do d=$(dirname "$d"); done
  done < "$MANIFEST"
fi
cp /tmp/published-files "$MANIFEST.stage-tmp"
own "$MANIFEST.stage-tmp"
mv -f "$MANIFEST.stage-tmp" "$MANIFEST"

echo "[coreos-stage] done"
