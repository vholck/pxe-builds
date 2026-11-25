#!/bin/sh
# Entry point of the rpi-uefi stage image (Dockerfile.stage). Runs on the boot
# host when the pxe stack starts.
#
# Every Pi listed in RPI5_UEFI_SERIALS / RPI4_UEFI_SERIALS / RPI3_UEFI_SERIALS
# gets a <serial>/ directory in the TFTP root holding the UEFI firmware. The Pi bootloader prefers
# that directory over the flat U-Boot files, so listed Pis boot UEFI and all
# others keep booting U-Boot. Removing a serial from the list removes its
# directory on the next deploy.
set -eu

OUT=/out
SRC=/assets/uefi
# Marks a directory as created by this script. Directories without it (for
# example a hand-made per-device override) are never modified or removed.
MARK=.rpi-uefi-stage

wanted=""

stage_model() {
  model=$1
  serials=$2
  for serial in $serials; do
    serial=$(printf '%s' "$serial" | tr 'A-F' 'a-f')
    if ! printf '%s' "$serial" | grep -Eq '^[0-9a-f]{8}$'; then
      echo "[rpi-uefi-stage] WARNING: '$serial' is not an 8-digit hex serial; skipped" >&2
      continue
    fi
    case " $wanted " in *" $serial "*)
      echo "[rpi-uefi-stage] WARNING: $serial is listed more than once; keeping the first" >&2
      continue ;;
    esac
    dir="$OUT/$serial"
    if [ -e "$dir" ] && [ ! -f "$dir/$MARK" ]; then
      # One bad entry must not keep dnsmasq from starting, so warn and carry on.
      echo "[rpi-uefi-stage] WARNING: $dir exists and was not created by this stage; left alone. Remove it to use the staged UEFI firmware." >&2
      continue
    fi
    wanted="$wanted $serial"
    tmp="$OUT/.$serial.stage-tmp"
    rm -rf "$tmp"
    cp -r "$SRC/$model" "$tmp"
    echo "$model" > "$tmp/$MARK"
    # Ownership is set here, on the directory this script made, and not with a
    # "chown -R" over the whole TFTP root: the other stage containers work in it at
    # the same time, and a file of theirs that disappears mid-run fails the chown
    # and with it this stage, which keeps dnsmasq from starting.
    chown -R "${PUID:-500}:${PGID:-500}" "$tmp"
    rm -rf "$dir"
    mv "$tmp" "$dir"
    echo "[rpi-uefi-stage] $serial -> UEFI ($model, $(grep -h '^built=' "$dir/$model-uefi.txt"))"
  done
}

stage_model rpi5 "${RPI5_UEFI_SERIALS:-}"
stage_model rpi4 "${RPI4_UEFI_SERIALS:-}"
stage_model rpi3 "${RPI3_UEFI_SERIALS:-}"

# Remove directories staged earlier for Pis that are no longer listed.
for mark in "$OUT"/*/"$MARK"; do
  [ -f "$mark" ] || continue
  dir=$(dirname "$mark")
  serial=$(basename "$dir")
  case " $wanted " in
    *" $serial "*) ;;
    *) rm -rf "$dir"; echo "[rpi-uefi-stage] $serial removed (no longer listed)" ;;
  esac
done

[ -n "$wanted" ] || echo "[rpi-uefi-stage] no UEFI directories staged; Pis without one boot U-Boot"
echo "[rpi-uefi-stage] done"
