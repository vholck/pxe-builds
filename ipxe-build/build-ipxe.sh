#!/bin/sh
# Compiles the iPXE binaries. Runs inside the Dockerfile's build stage (in CI),
# never on the boot host. Output goes to /artifacts, which becomes the image's
# /assets/tftp tree. Settings arrive as Docker build args.
set -eux

: "${IPXE_REF:?IPXE_REF (iPXE commit to build) is required}"
: "${IPXE_PRODUCT_NAME:?}" "${IPXE_KEYBOARD_MAP:?}"
ON_FAILURE="${IPXE_ON_FAILURE:-reboot}"
# How the embedded script configures the network. "dhcp" runs every
# configurator (DHCPv4 and IPv6 autoconfiguration) and returns when all are
# done; with no IPv6 router on the LAN that is the router-solicitation timeout.
case "${IPXE_IPV6:-0}" in
  0) NET_CONFIG="ifconf --configurator dhcp" ;;
  1) NET_CONFIG="dhcp" ;;
  *) echo "ERROR: IPXE_IPV6 must be 0 or 1, not '${IPXE_IPV6}'" >&2; exit 1 ;;
esac
# Which builds write to the serial port themselves (CONSOLE_SERIAL, COM1 on x86).
# Every build also prints through the firmware console. UEFI firmware that
# redirects its console to the same port (VMs, servers with serial-over-LAN)
# then shows every character twice, and both drivers read the same UART.
# Firmware that redirects (BIOS or UEFI) carries iPXE's output by itself.
# bios (default): BIOS builds only; UEFI builds rely on the firmware's redirection.
# efi: UEFI builds only (BIOS machines that redirect, UEFI ones that do not).
# all: every build (a UEFI PC with a serial cable but no redirection). off: none.
# EFI builds find the port in the ACPI SPCR table and drive only 16550-type
# UARTs; the Pis' consoles (PL011, mini UART) are not, so the Pis are unaffected.
case "${IPXE_SERIAL_CONSOLE:-bios}" in
  all)  SERIAL_CONSOLE='#define CONSOLE_SERIAL CONSOLE_USAGE_ALL\n' ;;
  bios) SERIAL_CONSOLE='#if defined ( PLATFORM_pcbios )\n#define CONSOLE_SERIAL CONSOLE_USAGE_ALL\n#endif\n' ;;
  efi)  SERIAL_CONSOLE='#if defined ( PLATFORM_efi )\n#define CONSOLE_SERIAL CONSOLE_USAGE_ALL\n#endif\n' ;;
  off)  SERIAL_CONSOLE='' ;;
  *) echo "ERROR: IPXE_SERIAL_CONSOLE must be bios, efi, all or off, not '${IPXE_SERIAL_CONSOLE}'" >&2; exit 1 ;;
esac
# Root certificates iPXE trusts. iPXE has one list for HTTPS and for imgverify.
# 1 (default): iPXE's root CA (upstream's default root) plus the netboot.xyz CA,
#   which signs netboot.xyz's menu scripts; without it every netboot.xyz submenu
#   fails with "Could not verify" while its signature checks are on. netboot.xyz's
#   own iPXE trusts the same two. A CA in this list is also trusted for HTTPS.
#   An explicit list also stops a DHCP server or script from replacing the
#   trusted roots at run time (iPXE's "trust" setting).
# 0: upstream (iPXE root CA only, replaceable at run time).
# The certificate files are pinned by SHA-256 fingerprint: a changed file fails
# the build. netboot.xyz's CA is valid until 2035-11-15 but was replaced before
# (2025-11-17); netbootxyz.ipxe says on every boot when it no longer verifies.
CERTS=/build/certs
FP_IPXE_ORG=9faf717b7f8ca2f93c256c79f8ac5591895d66d1ff3bee6397a70d29c65eed1a
FP_NETBOOT_XYZ=0832ee5fcc19cec57a751fc9f1e585292d8a359f95ef943081d1611b5ffa6812
check_fingerprint() {
  fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')
  [ "$fp" = "$2" ] || { echo "ERROR: $1 has fingerprint $fp, expected $2" >&2; exit 1; }
}
case "${IPXE_TRUST_NETBOOTXYZ:-1}" in
  1) check_fingerprint "$CERTS/ca-ipxe-org.crt" "$FP_IPXE_ORG"
     check_fingerprint "$CERTS/ca-netboot-xyz.crt" "$FP_NETBOOT_XYZ"
     TRUST_ARG="TRUST=$CERTS/ca-ipxe-org.crt,$CERTS/ca-netboot-xyz.crt"
     TRUSTED_FPS="$FP_IPXE_ORG ca-ipxe-org.crt
$FP_NETBOOT_XYZ ca-netboot-xyz.crt" ;;
  0) TRUST_ARG=""
     TRUSTED_FPS="$FP_IPXE_ORG iPXE root CA (built-in default)" ;;
  *) echo "ERROR: IPXE_TRUST_NETBOOTXYZ must be 0 or 1, not '${IPXE_TRUST_NETBOOTXYZ}'" >&2; exit 1 ;;
esac
BUILD_EXTRAS="${BUILD_EXTRA_IPXE_ARTIFACTS:-0}"
BUILD_OPTIONAL="${BUILD_OPTIONAL_IPXE_MEDIA:-0}"

OUT=/artifacts
# ipxe/ holds what clients fetch; build-info/ipxe/ records how it was built.
BIN="$OUT/ipxe"
INFO="$OUT/build-info/ipxe"
mkdir -p "$BIN" "$INFO"
START_TS=$(date +%s)

# Full clone so iPXE derives its version from the tags; then pin the commit.
git clone https://github.com/ipxe/ipxe.git /tmp/ipxe
cd /tmp/ipxe
git checkout --detach "$IPXE_REF"
git rev-parse HEAD > "$INFO/ipxe-commit"
# Source patches (patches/*.patch, made with git diff at IPXE_REF), applied in
# name order. One that no longer applies fails the build.
for p in /build/patches/*.patch; do
  [ -f "$p" ] || continue
  git apply --check "$p" || { echo "ERROR: $(basename "$p") does not apply to iPXE $IPXE_REF; upstream changed" >&2; exit 1; }
  git apply "$p"
  echo "applied $(basename "$p")"
  basename "$p" >> "$INFO/patches"
done
cd src

# ── compiled-in features ─────────────────────────────────────────────────────
mkdir -p config/local
printf '%s\n' \
  '#define DOWNLOAD_PROTO_HTTPS' \
  '#define DOWNLOAD_PROTO_FTP' \
  '#define DOWNLOAD_PROTO_NFS' \
  '#define DOWNLOAD_PROTO_FILE' \
  '#define IMAGE_TRUST_CMD' \
  '#define IMAGE_GZIP' \
  '#define IMAGE_ZLIB' \
  '#define PING_CMD' \
  '#define NSLOOKUP_CMD' \
  '#define NTP_CMD' \
  '#define REBOOT_CMD' \
  '#define POWEROFF_CMD' \
  '#define VLAN_CMD' \
  '#define DIGEST_CMD' \
  > config/local/general.h
# Highest TLS version iPXE offers. 1.3 is upstream's default. Up to iPXE 9261ebe
# TLS 1.3 failed with the Flatcar release server (alert 51, decrypt_error) and
# Alpine's, Debian's and NixOS's servers (connection closed after the
# handshake); iPXE's TLS 1.3 transcript fixes of 2026-11 (1fa3091, 5e6ea50)
# repaired them (tested 2026-11-25, b847e5f). 1.2 stays as a fallback.
case "${IPXE_TLS_MAX:-1.3}" in
  1.2) TLS_MAX='#undef TLS_VERSION_MAX\n#define TLS_VERSION_MAX TLS_VERSION_TLS_1_2\n' ;;
  1.3) TLS_MAX='' ;;
  *) echo "ERROR: IPXE_TLS_MAX must be 1.2 or 1.3, not '${IPXE_TLS_MAX}'" >&2; exit 1 ;;
esac
printf "#undef OCSP_CHECK\n${TLS_MAX}" > config/local/crypto.h
printf "#undef KEYBOARD_MAP\n#define KEYBOARD_MAP %s\n${SERIAL_CONSOLE}" \
  "${IPXE_KEYBOARD_MAP}" > config/local/console.h
# PRODUCT_SHORT_NAME matches the embedded user-class (cosmetic version banner)
printf '#undef PRODUCT_SHORT_NAME\n#define PRODUCT_SHORT_NAME "%s"\n' "${IPXE_PRODUCT_NAME}" > config/local/branding.h

# ── embedded script ──────────────────────────────────────────────────────────
sed -e "s|@IPXE_PRODUCT_NAME@|${IPXE_PRODUCT_NAME}|g" \
    -e "s|@IPXE_ON_FAILURE@|${ON_FAILURE}|g" \
    -e "s|@IPXE_NET_CONFIG@|${NET_CONFIG}|g" \
    /build/autoexec.ipxe > autoexec.ipxe
if grep -v '^#' autoexec.ipxe | grep -n '@[A-Z_]*@'; then
  echo "ERROR: unresolved placeholder in autoexec.ipxe" >&2
  exit 1
fi
cat autoexec.ipxe

# ── version label ────────────────────────────────────────────────────────────
BUILD_TS="$(date -u +%y%m%d%H%M)"
if [ -n "${IPXE_BUILD_TAG:-}" ]; then
  BUILD_LABEL="${IPXE_PRODUCT_NAME}-${IPXE_BUILD_TAG}-${BUILD_TS}"
else
  BUILD_LABEL="${IPXE_PRODUCT_NAME}-${BUILD_TS}"
fi
printf '#define VERSION_EXTRA "%s"\n' "$BUILD_LABEL" >> config/local/general.h
printf '#undef BUILD_ID\n#define BUILD_ID "%s"\n' "$BUILD_LABEL" >> config/local/general.h

# Kept for troubleshooting; stage.sh reads product-name so
# dnsmasq matches exactly the user-class compiled into the binaries.
echo "$BUILD_LABEL" > "$INFO/version.extra"
echo "$IPXE_PRODUCT_NAME" > "$INFO/product-name"
cp autoexec.ipxe "$INFO/autoexec.ipxe.embedded"
cp config/local/general.h config/local/console.h config/local/crypto.h config/local/branding.h "$INFO/"
echo "$TRUSTED_FPS" > "$INFO/trusted-roots"

CPUS=$(nproc)
run_make() {
  debug_arg=""
  [ -n "${IPXE_DEBUG:-}" ] && debug_arg="DEBUG=${IPXE_DEBUG}"
  # shellcheck disable=SC2086  # debug_arg and TRUST_ARG are empty or one word
  make -j"$CPUS" "EXTRAVERSION=-$BUILD_LABEL" EMBED=autoexec.ipxe $TRUST_ARG $debug_arg "$@"
}
arm64() { run_make CROSS_COMPILE=aarch64-linux-gnu- "$@"; }
# NAP_NULL disables iPXE's idle CPU sleep. Under U-Boot's bootefi nothing can wake
# the CPU again (no interrupt support), which freezes the menu on a Raspberry Pi.
nap_null_on()  { printf '#undef NAP_EFI\n#define NAP_NULL\n' > config/local/nap.h; }
nap_null_off() { rm -f config/local/nap.h; }
# snp.efi does not build on every iPXE revision/arch; it is an optional extra.
install_if_built() {
  if [ -f "$1" ]; then install -Dm0644 "$1" "$2"; else echo "WARNING: $1 was not built; skipping $2"; fi
}

# ── required binaries (build dirs removed after each to limit peak disk/memory) ──
run_make bin/undionly.kpxe
install -Dm0644 bin/undionly.kpxe "$BIN/undionly.kpxe"
rm -rf bin/

# BIOS with iPXE's own network drivers; for a card it has no driver for it falls
# back to the card's PXE ROM (UNDI), which the .kpxe prefix keeps loaded (issue
# #23). A BIOS loads a network boot program into base memory below 640 KB; the
# practical limit is about 500 KB, so a bigger file fails the build.
run_make bin/ipxe.kpxe
size=$(stat -c %s bin/ipxe.kpxe)
echo "ipxe.kpxe: $size bytes"
[ "$size" -le 491520 ] || { echo "ERROR: bin/ipxe.kpxe is $size bytes, more than 480 KB; a BIOS may not load it" >&2; exit 1; }
install -Dm0644 bin/ipxe.kpxe "$BIN/ipxe.kpxe"
rm -rf bin/

run_make bin-x86_64-efi/snponly.efi
install -Dm0644 bin-x86_64-efi/snponly.efi "$BIN/snponly-x86_64.efi"
rm -rf bin-x86_64-efi/

arm64 bin-arm64-efi/snponly.efi
install -Dm0644 bin-arm64-efi/snponly.efi "$BIN/snponly-arm64.efi"
rm -rf bin-arm64-efi/

nap_null_on
arm64 bin-arm64-efi/snponly.efi
nap_null_off
install -Dm0644 bin-arm64-efi/snponly.efi "$BIN/snponly-arm64-rpi.efi"
rm -rf bin-arm64-efi/

# ── extra variants (BUILD_EXTRA_IPXE_ARTIFACTS=1) ────────────────────────────
if [ "$BUILD_EXTRAS" = "1" ]; then
  run_make bin/ipxe.pxe
  run_make bin/ipxe.lkrn
  cp "$BIN/undionly.kpxe" "$BIN/undionly.kpxe.0"   # some ROMs request a .0 suffix
  install -Dm0644 bin/ipxe.pxe  "$BIN/ipxe.pxe"
  install -Dm0644 bin/ipxe.lkrn "$BIN/ipxe.lkrn"
  rm -rf bin/

  run_make bin-x86_64-efi/ipxe.efi
  run_make bin-x86_64-efi/snp.efi || true
  install -Dm0644 bin-x86_64-efi/ipxe.efi "$BIN/ipxe-x86_64.efi"
  install_if_built bin-x86_64-efi/snp.efi "$BIN/snp-x86_64.efi"
  rm -rf bin-x86_64-efi/

  arm64 bin-arm64-efi/ipxe.efi
  arm64 bin-arm64-efi/snp.efi || true
  install -Dm0644 bin-arm64-efi/ipxe.efi "$BIN/ipxe-arm64.efi"
  install_if_built bin-arm64-efi/snp.efi "$BIN/snp-arm64.efi"
  rm -rf bin-arm64-efi/

  nap_null_on
  arm64 bin-arm64-efi/ipxe.efi
  arm64 bin-arm64-efi/snp.efi || true
  nap_null_off
  install -Dm0644 bin-arm64-efi/ipxe.efi "$BIN/ipxe-arm64-rpi.efi"
  install_if_built bin-arm64-efi/snp.efi "$BIN/snp-arm64-rpi.efi"
  rm -rf bin-arm64-efi/
fi

# ── bootable media (BUILD_OPTIONAL_IPXE_MEDIA=1) ─────────────────────────────
if [ "$BUILD_OPTIONAL" = "1" ]; then
  run_make bin/ipxe.iso
  run_make bin/ipxe.usb
  install -Dm0644 bin/ipxe.iso "$BIN/ipxe.iso"
  install -Dm0644 bin/ipxe.usb "$BIN/ipxe.usb"
  rm -rf bin/
fi

rm -rf /tmp/ipxe
ls -lR "$OUT"
echo "Total build time: $(( $(date +%s) - START_TS ))s"
