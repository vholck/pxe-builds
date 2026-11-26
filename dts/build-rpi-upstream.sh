#!/bin/bash
# Builds the upstream Linux device trees of one Raspberry Pi family, with
# symbols, from devicetree-rebasing (the Linux device tree files, fetched by
# fetch-rpi-dts.sh at the release pinned in build.env). Pi 5 trees get the RP1's
# UART0 added (rp1-uart0.dtsi); Pi 3 and Pi 4 trees are built as upstream ships
# them (their console, the mini UART on GPIO 14/15, is already described).
# Used by rpi-uboot-build and rpi-uefi-build, so both firmwares serve the same
# trees. A loader picks one by the firmware's FdtFile variable. See README.md.
#
# Usage: build-rpi-upstream.sh <dts-upstream> <out-dir> <dtc> <gcc> <family>
#   <dts-upstream>  a devicetree-rebasing checkout (fetch-rpi-dts.sh)
#   <out-dir>       gets broadcom/<board>.dtb
#   <dtc>           device tree compiler (needs -@)
#   <gcc>           any gcc, used as the C preprocessor
#   <family>        rpi3, rpi4 or rpi5
set -eu

src=$1 out=$2 dtc=$3 cc=$4 family=$5
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "[build-rpi-upstream] ERROR: $*" >&2; exit 1; }

# The boards of each family that upstream Linux has a tree for (U-Boot's
# fdtfile names; the Compute Modules are named differently upstream,
# bcm2837-rpi-cm3-io3 and bcm2711-rpi-cm4-io, and are left out).
case "$family" in
  rpi3) boards="bcm2837-rpi-3-b bcm2837-rpi-3-b-plus bcm2837-rpi-3-a-plus bcm2837-rpi-zero-2-w" ;;
  rpi4) boards="bcm2711-rpi-4-b bcm2711-rpi-400" ;;
  rpi5) boards="bcm2712-rpi-5-b bcm2712-d-rpi-5-b" ;;
  *) die "family must be rpi3, rpi4 or rpi5 (got '$family')" ;;
esac

if [ "$family" = rpi5 ]; then
  rp1="$src/src/arm64/broadcom/rp1-common.dtsi"
  [ -f "$rp1" ] || die "$rp1 not found"
  # Once upstream has its own node for the RP1's UART0, ours would sit next to
  # it: stop and let a person drop the node from rp1-uart0.dtsi (keeping the
  # aliases, stdout-path and __overrides__, pointed at upstream's node).
  if grep -q 'serial@40030000' "$rp1"; then
    die "upstream rp1-common.dtsi now has a node for the RP1's UART0: update dts/rp1-uart0.dtsi (see dts/README.md)"
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out/broadcom"
for board in $boards; do
  [ -f "$src/src/arm64/broadcom/$board.dts" ] || die "$board.dts not found in $src; upstream changed"
  # (named apart from the board file, which it would otherwise include itself)
  if [ "$family" = rpi5 ]; then
    printf '#include "%s.dts"\n#include "%s/rp1-uart0.dtsi"\n' "$board" "$here" > "$tmp/$board-top.dts"
  else
    printf '#include "%s.dts"\n' "$board" > "$tmp/$board-top.dts"
  fi
  "$cc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$src/include" -I "$src/src/arm64" -I "$src/src/arm64/broadcom" \
    -I "$src/src" -I "$src/src/arm/broadcom" \
    -o "$tmp/$board.pp" "$tmp/$board-top.dts"
  "$dtc" -q -@ -I dts -O dtb -o "$out/broadcom/$board.dtb" "$tmp/$board.pp"
  "$dtc" -q -I dtb -O dts -o "$tmp/$board.check" "$out/broadcom/$board.dtb"
  if [ "$family" = rpi5 ]; then
    # The firmware applies enable_uart=1 through these; check they came through.
    wants="arm,sbsa-uart|__symbols__|__overrides__|uart0_console|stdout-path = \"serial0:115200n8\""
  else
    wants="__symbols__|stdout-path"
  fi
  IFS='|' read -r -a want_list <<< "$wants"
  for want in "${want_list[@]}"; do
    grep -qF "$want" "$tmp/$board.check" || die "broadcom/$board.dtb has no '$want'"
  done
  echo "[build-rpi-upstream] built broadcom/$board.dtb$([ "$family" = rpi5 ] && echo ' (upstream tree + RP1 UART0)')"
done
