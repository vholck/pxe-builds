#!/bin/bash
# Builds the extra initrd that lets one Fedora CoreOS release boot over the
# network on a Raspberry Pi 5, or finds that the release does not need one.
#
#   build-extra-initrd.sh <os> <version> <out-dir>
#   e.g. build-extra-initrd.sh fedora-coreos 45.20261030.3.1 /out
#
# Writes <out-dir>/<os>-<version>-aarch64.cpio, or <out-dir>/<os>-<version>-aarch64.none
# when the live initramfs already contains everything (then nothing is added).
#
# Why: the Pi 5's Ethernet sits behind the RP1 chip, which needs rp1_pci.ko. The
# CoreOS live initramfs has the RP1 clock, pinctrl and MAC drivers, but not
# rp1_pci (dracut's list of arm driver directories lacks drivers/misc), so the
# initramfs never gets a network and cannot fetch its root file system. See
# dracut-rp1-bug-report.md.
#
# The extra initrd holds rp1_pci (and any module it needs that the initramfs
# lacks), taken from the release's own kernel package, plus module lists
# (modules.dep, modules.alias, ...) regenerated over the initramfs's module tree.
# The kernel unpacks it after the main initramfs, so its lists replace the
# originals: it fits exactly this release and must never be used with another.
#
# Only aarch64 needs it. Runs in a Fedora container (rpm2cpio, depmod, zstd);
# it only unpacks aarch64 packages, so any host architecture works.
set -euo pipefail

OS=${1:?os, e.g. fedora-coreos}
VERSION=${2:?release version}
OUT=${3:?output directory}

case "$OS" in
  fedora-coreos) ;;
  *) echo "[extra-initrd] unsupported OS: $OS" >&2; exit 2 ;;
esac
case "$VERSION" in
  *[!0-9.]*|'') echo "[extra-initrd] bad version: $VERSION" >&2; exit 2 ;;
esac

# Release streams keep every build under prod/streams/<stream>/builds/<version>;
# the third version field is the stream (1 next, 2 testing, 3 stable).
case "$(echo "$VERSION" | cut -d. -f3)" in
  1) STREAM=next ;;
  2) STREAM=testing ;;
  3) STREAM=stable ;;
  *) echo "[extra-initrd] cannot tell the stream of $VERSION" >&2; exit 2 ;;
esac
BASE=https://builds.coreos.fedoraproject.org/prod/streams/$STREAM/builds/$VERSION/aarch64
NAME=$OS-$VERSION-aarch64

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/rpm" "$W/initrd" "$W/overlay" "$OUT"
cd "$W"

# 1. module tree of the live initramfs, and its kernel version
curl -fsSL --retry 3 -o initramfs.img "$BASE/fedora-coreos-$VERSION-live-initramfs.aarch64.img"
# The live initramfs is several concatenated archives; the modules are in the
# zstd-compressed main one. cpio stops at the first archive end, so unpack
# each zstd frame stream with "zstd -dc" (it decodes all frames in a row).
(cd initrd && zstd -dc ../initramfs.img 2>/dev/null | cpio -id --quiet 'usr/lib/modules/*' 2>/dev/null) || true
KVER=$(ls initrd/usr/lib/modules/ 2>/dev/null | head -1)
[ -n "$KVER" ] || { echo "[extra-initrd] no kernel modules found in the $VERSION live initramfs" >&2; exit 1; }
echo "[extra-initrd] $OS $VERSION: kernel $KVER"

# 2. already there? Then this release needs nothing (dracut fixed, or Fedora
#    builds the driver in): record that instead of an archive.
if [ -n "$(find "initrd/usr/lib/modules/$KVER" -name 'rp1_pci.ko*' -print -quit)" ]; then
  echo "[extra-initrd] rp1_pci is already in the $VERSION initramfs; no extra initrd needed"
  echo "$KVER" > "$OUT/$NAME.none"
  exit 0
fi

# 3. rp1_pci from the release's kernel package (Fedora's koji keeps every build).
#    KVER is <version>-<release>.<arch>, e.g. 7.2.11-300.fc45.aarch64.
KV=${KVER%%-*}
KR=${KVER#*-}; KR=${KR%.aarch64}
KOJI=https://kojipkgs.fedoraproject.org/packages/kernel/$KV/$KR/aarch64
for p in kernel-modules-core kernel-modules; do
  curl -fsSL --retry 3 -o "$p.rpm" "$KOJI/$p-$KVER.rpm"
  (cd rpm && rpm2cpio "../$p.rpm" | cpio -id --quiet)
done
[ -n "$(find rpm -name 'rp1_pci.ko*' -print -quit)" ] || {
  echo "[extra-initrd] the $KVER kernel packages have no rp1_pci module (CONFIG_MISC_RP1 off?)" >&2; exit 1; }

add_mod() {
  local name=$1 f rel
  f=$(find "rpm/lib/modules/$KVER" -name "$name.ko*" | head -1)
  [ -n "$f" ] || { echo "[extra-initrd] module $name missing from the kernel packages" >&2; exit 1; }
  rel=${f#rpm/}
  [ -e "initrd/usr/$rel" ] && return 0
  mkdir -p "$(dirname "initrd/usr/$rel")" "$(dirname "overlay/usr/$rel")"
  cp "$f" "initrd/usr/$rel"
  cp "$f" "overlay/usr/$rel"
  echo "[extra-initrd] added $rel"
  local dep
  for dep in $(modinfo -F depends "$f" | tr ',' ' '); do add_mod "$dep"; done
}
add_mod rp1_pci

# 4. module lists for the initramfs tree with the new modules in it
depmod -b initrd/usr "$KVER"
mkdir -p "overlay/usr/lib/modules/$KVER"
cp initrd/usr/lib/modules/"$KVER"/modules.* "overlay/usr/lib/modules/$KVER/"
grep -q 'rp1_pci' "overlay/usr/lib/modules/$KVER/modules.dep"
grep -qi 'pci:v00001DE4d00000001' "overlay/usr/lib/modules/$KVER/modules.alias" || {
  echo "[extra-initrd] no PCI alias for the RP1 (1de4:0001) after depmod" >&2; exit 1; }

# 5. the archive: uncompressed newc, reproducible (fixed order, owner and time)
find overlay -exec touch -h -d @0 {} +
(cd overlay && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet) > "$OUT/$NAME.cpio.tmp"
mv "$OUT/$NAME.cpio.tmp" "$OUT/$NAME.cpio"
echo "[extra-initrd] wrote $NAME.cpio ($(stat -c %s "$OUT/$NAME.cpio") bytes)"
