#!/bin/sh
# Runs each time the ipxe-build image starts. Publishes what was built into
# this image: the iPXE binaries and boot scripts go to the TFTP root, and
# dnsmasq.conf is rendered with this host's network settings.
set -eu

SRC=/assets/tftp
OUT=/out
CONF=/config

: "${LAN_GATEWAY:?}" "${LAN_NETMASK:?}" "${PXE_LAN_IP:?}" "${IPXE_CHAIN_URI:?}"

# netboot.xyz chained directly does not work with this iPXE: its menu sees a
# version mismatch and loads its own x86 iPXE binary ("Machine type 0x8664 is not
# supported" on a Pi, a replaced iPXE on x86). ipxe/netbootxyz.ipxe avoids that,
# so a setting that still names the bare site (an old deployment variable,
# for example) is pointed at the wrapper.
case "${IPXE_CHAIN_URI%/}" in
  http://boot.netboot.xyz|https://boot.netboot.xyz)
    echo "[stage] IPXE_CHAIN_URI=${IPXE_CHAIN_URI} chains netboot.xyz directly, which does not work with this iPXE; using tftp://${PXE_LAN_IP}/ipxe/netbootxyz.ipxe instead"
    IPXE_CHAIN_URI=tftp://${PXE_LAN_IP}/ipxe/netbootxyz.ipxe
    ;;
esac

echo "[stage] publishing $(cat "$SRC/build-info/ipxe/version.extra") to the TFTP root"

# Copy to a temporary name and rename, so a client never downloads a half-written
# file. Files that are not part of the image (Pi firmware, hand-placed ipxe/hosts/
# scripts) are left alone.
# Ownership is set file by file, on what this script wrote. The three stage
# containers of a deployment run at the same time on the same directory: a
# "chown -R" over all of it fails when another stage renames one of its
# temporary files in that moment, and a failed stage keeps dnsmasq from starting.
own() { chown "${PUID:-500}:${PGID:-500}" "$@"; }

cd "$SRC"
find . -type f | while read -r f; do
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
# so hand-placed files (ipxe/hosts/ scripts) and other images' files are safe.
# Before the first manifest existed the files below were published to the TFTP
# root; they moved to ipxe/ and build-info/ipxe/.
# The root snponly-arm64-rpi.efi is deliberately not on the list: U-Boot builds
# from before the move (per-device {serial}/ directories made by hand) have that
# name compiled in. Delete it by hand once no such directory is left.
MANIFEST=$OUT/build-info/ipxe/published-files
LEGACY="undionly.kpxe undionly.kpxe.0 snponly-x86_64.efi snponly-arm64.efi
ipxe.pxe ipxe.lkrn ipxe-x86_64.efi snp-x86_64.efi ipxe-arm64.efi snp-arm64.efi
ipxe-arm64-rpi.efi snp-arm64-rpi.efi ipxe.iso ipxe.usb
boot.ipxe netbootxyz.ipxe hosts/README.txt version.extra
debug/autoexec.ipxe.embedded debug/branding.h debug/console.h debug/crypto.h
debug/general.h debug/ipxe-commit debug/product-name debug/build-inputs.sha256
debug/ca-certificates.crt"
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
  echo "[stage] removed $f (no longer published)"
  # drop directories this left empty
  d=$(dirname "$f")
  while [ "$d" != . ] && rmdir "$OUT/$d" 2>/dev/null; do d=$(dirname "$d"); done
done
cp /tmp/published-files "$MANIFEST.stage-tmp"
own "$MANIFEST.stage-tmp"
mv -f "$MANIFEST.stage-tmp" "$MANIFEST"

# Matchbox (optional matchbox service, sharing dnsmasq's address): boot.ipxe
# chains ipxe/matchbox.ipxe after the per-device script. The file exists only
# while MATCHBOX_ENABLED=1, so without Matchbox no client tries to reach it.
# Not in the manifest above: it is written or removed here on every start.
case "${MATCHBOX_ENABLED:-0}" in
  1)
    cat > "$OUT/ipxe/matchbox.ipxe.stage-tmp" <<'EOF'
#!ipxe
# Written by the ipxe-build stage because MATCHBOX_ENABLED=1 (removed
# when it is not). Chained by ipxe/boot.ipxe after the per-device script.
# Matchbox listens on port 8080 of this boot server and answers with the iPXE
# script of the profile whose group matches this machine; for a machine no
# group matches it answers 404, this chain fails, and boot.ipxe goes on with
# the default (IPXE_CHAIN_URI). Same labels as Matchbox's own /boot.ipxe.
chain --autofree http://${next-server}:8080/ipxe?mac=${netX/mac:hexhyp}&uuid=${uuid}&serial=${serial:uristring}&hostname=${hostname:uristring}&domain=${domain:uristring}&arch=${buildarch:uristring}
EOF
    own "$OUT/ipxe/matchbox.ipxe.stage-tmp"
    mv -f "$OUT/ipxe/matchbox.ipxe.stage-tmp" "$OUT/ipxe/matchbox.ipxe"
    echo "[stage] Matchbox enabled: ipxe/boot.ipxe asks http://${PXE_LAN_IP}:8080 after ipxe/hosts/"
    ;;
  *)
    # a wrong value must not stop the stage: dnsmasq waits for it
    case "${MATCHBOX_ENABLED:-0}" in
      0|'') ;;
      *) echo "[stage] WARNING: MATCHBOX_ENABLED=${MATCHBOX_ENABLED} is not 0 or 1; Matchbox stays off" >&2 ;;
    esac
    rm -f "$OUT/ipxe/matchbox.ipxe"
    ;;
esac

# Escape the characters that are special in a sed replacement.
esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

# The user-class dnsmasq matches must be the one compiled into the binaries.
PRODUCT_NAME=$(cat "$SRC/build-info/ipxe/product-name")

# BIOS clients: the iPXE they are given, and the machines that keep
# undionly.kpxe. A wrong value must not stop the stage (dnsmasq waits for it):
# it is reported and the default is used.
BIOS_FILE=${IPXE_BIOS_FILE:-ipxe.kpxe}
case "$BIOS_FILE" in
  ipxe.kpxe|undionly.kpxe) ;;
  *) echo "[stage] WARNING: IPXE_BIOS_FILE=${BIOS_FILE} is not ipxe.kpxe or undionly.kpxe; using ipxe.kpxe" >&2
     BIOS_FILE=ipxe.kpxe ;;
esac
: > /tmp/bios-undi-macs
for mac in $(printf '%s' "${IPXE_BIOS_UNDI_MACS:-}" | tr ',;' '  '); do
  m=$(printf '%s' "$mac" | tr 'A-F-' 'a-f:')
  if printf '%s' "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
    echo "dhcp-mac=set:biosundi,$m" >> /tmp/bios-undi-macs
  else
    echo "[stage] WARNING: IPXE_BIOS_UNDI_MACS: '$mac' is not a MAC address; ignored" >&2
  fi
done

sed \
  -e "s|@LAN_GATEWAY@|$(esc "$LAN_GATEWAY")|g" \
  -e "s|@LAN_NETMASK@|$(esc "$LAN_NETMASK")|g" \
  -e "s|@PXE_LAN_IP@|$(esc "$PXE_LAN_IP")|g" \
  -e "s|@IPXE_CHAIN_URI@|$(esc "$IPXE_CHAIN_URI")|g" \
  -e "s|@IPXE_PRODUCT_NAME@|$(esc "$PRODUCT_NAME")|g" \
  -e "s|@IPXE_BIOS_FILE@|$BIOS_FILE|g" \
  -e '/^#@BIOS_UNDI_MACS@$/{r /tmp/bios-undi-macs' -e 'd;}' \
  /assets/dnsmasq.conf > "$CONF/dnsmasq.conf.stage-tmp"

if grep -v '^#' "$CONF/dnsmasq.conf.stage-tmp" | grep -n '@[A-Z_]*@'; then
  echo "[stage] ERROR: unresolved placeholder in dnsmasq.conf (see above)" >&2
  exit 1
fi
mv -f "$CONF/dnsmasq.conf.stage-tmp" "$CONF/dnsmasq.conf"

echo "[stage] BIOS clients get ipxe/${BIOS_FILE}; ipxe/undionly.kpxe for: $(sed 's/^dhcp-mac=set:biosundi,//' /tmp/bios-undi-macs | tr '\n' ' ')"
echo "[stage] done; default chain target: ${IPXE_CHAIN_URI}"
