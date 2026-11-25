#!/bin/bash
# Builds the Raspberry Pi UEFI firmware (EDK2) for Pi 3, Pi 4 and/or Pi 5 and
# collects everything one Pi needs to boot it over TFTP. Pi 3 and Pi 4 are built
# from the pftf project's sources in /build, the Pi 5 from its own EDK2 port in
# /build5 (see the Dockerfile).
#
# Output:
#   /out/generic-<model>/   complete boot tree for that model (RPI_EFI.fd, Pi
#                           firmware, device trees, config.txt). This is exactly
#                           what goes into a per-device <serial>/ TFTP directory.
#   /out/tftp/<serial>/     only when SERIAL is set: a copy for that one Pi.
#
# The firmware is generic: nothing device-specific is compiled in.
set -eu

# ── settings (defaults allow running the image without the compose file) ─────
MODELS="${MODEL:-rpi3 rpi4 rpi5}"
: "${RPI_FIRMWARE_URL:=https://github.com/raspberrypi/firmware}"
# Raspberry Pi firmware commits the boot files are taken from
: "${START_ELF_VERSION:=d131b57900035c0562af1898c00a1bf59d3b9d1e}"
: "${DTB_VERSION:=d131b57900035c0562af1898c00a1bf59d3b9d1e}"
: "${DTBO_VERSION:=d131b57900035c0562af1898c00a1bf59d3b9d1e}"
# warn (default) = errors and warnings on serial, asserts do not halt, boots as
# fast as release (measured on a Pi 4); release = quiet;
# debug = full EDK2 debug output, asserts halt the boot
: "${UEFI_BUILD_TYPE:=warn}"
# Settings menu defaults. They matter because settings changed in the firmware
# menu may not survive a reboot when the firmware is loaded over TFTP.
: "${UEFI_BOOT_TIMEOUT:=2}"          # seconds the boot prompt is shown
# Every Pi: acpi | both | devicetree | upstream (keep each model's default:
# Pi 3 both, Pi 4 and Pi 5 acpi). both (default) = ACPI and the Pi firmware's
# device tree; arm64 Linux uses the tree, which Raspberry Pi kernels need (they
# panic with ACPI only) and which gives a distribution kernel Ethernet behind
# the Pi 5's RP1. One setting for all families (rule R4; it replaced
# UEFI_RPI5_SYSTEM_TABLE, which had the same values and default).
: "${UEFI_SYSTEM_TABLE:=both}"
# Pi 5: device tree of the Pi 5 B boards the firmware loads and hands to the
# OS. firmware (default) = Raspberry Pi's trees, as on every Pi (rule R3); an
# OS that needs the upstream tree loads it itself by the FdtFile variable.
# upstream = the upstream Linux trees with the RP1's UART0 (dts/ at the
# repository root) for every OS. Boards without an upstream tree (CM5, Pi 500)
# always get Raspberry Pi's.
: "${UEFI_RPI5_DT:=firmware}"
: "${UEFI_RAM_LIMIT_3GB:=0}"         # Pi 4 only: 1 limits RAM to 3 GB (upstream default), 0 uses all RAM
# 1 = the firmware has its IPv6 network stack (upstream), with the boot options
# PXE over IPv6 and HTTP boot over IPv6. 0 = IPv4 only: those two options do not
# exist, so nothing waits for them (about 2 minutes on a network without an
# IPv6 router, e.g. after iPXE hands back).
: "${UEFI_IPV6:=0}"
# HDMI mode as <group>:<mode> (config.txt hdmi_group / hdmi_mode), e.g. 1:4 = 720p60,
# 1:16 = 1080p60. Empty = let the Pi choose (640x480 when no display is detected).
: "${UEFI_HDMI_MODE:=}"
# Main console of the OS (build.env, rule R2). EDK2's ConsolePrefDxe removes
# stdout-path and the SPCR table when a display is present and its preference
# is "graphical". auto = graphical (the upstream default): the display is main
# when connected, serial otherwise. serial = both are always kept, so serial
# is main and the display second.
: "${CONSOLE_MAIN:=auto}"
: "${FORCE_UEFI_REBUILD:=0}"

# Source tree of the model being built; set by build_model.
SRC=/build
log() { echo "[rpi-uefi-build] $*"; }
die() { echo "[rpi-uefi-build] ERROR: $*" >&2; exit 1; }

case "$UEFI_BUILD_TYPE" in release|warn|debug) ;; *) die "UEFI_BUILD_TYPE must be release, warn or debug (got '$UEFI_BUILD_TYPE')" ;; esac
# SystemTableMode value for a setting; empty = keep the model's default
system_table_mode() {
  case "$2" in
    upstream) echo "" ;;
    acpi) echo 0 ;;
    both) echo 1 ;;
    devicetree) echo 2 ;;
    *) die "$1 must be acpi, both, devicetree or upstream (got '$2')" ;;
  esac
}
system_table_mode UEFI_SYSTEM_TABLE "$UEFI_SYSTEM_TABLE" >/dev/null
[ -z "${UEFI_RPI5_SYSTEM_TABLE:-}" ] || die "UEFI_RPI5_SYSTEM_TABLE was replaced by UEFI_SYSTEM_TABLE, which applies to every Pi"
case "$UEFI_RPI5_DT" in upstream|firmware) ;; *) die "UEFI_RPI5_DT must be upstream or firmware (got '$UEFI_RPI5_DT')" ;; esac
printf '%s' "$UEFI_BOOT_TIMEOUT" | grep -Eq '^[0-9]+$' || die "UEFI_BOOT_TIMEOUT must be a number of seconds"
case "$UEFI_RAM_LIMIT_3GB" in 0|1) ;; *) die "UEFI_RAM_LIMIT_3GB must be 0 or 1" ;; esac
case "$UEFI_IPV6" in 0|1) ;; *) die "UEFI_IPV6 must be 0 or 1" ;; esac
case "$CONSOLE_MAIN" in auto|serial) ;; *) die "CONSOLE_MAIN must be auto or serial (got '$CONSOLE_MAIN')" ;; esac
HDMI_LINES=""
if [ -n "$UEFI_HDMI_MODE" ]; then
  printf '%s' "$UEFI_HDMI_MODE" | grep -Eq '^[12]:[0-9]{1,3}$' || die "UEFI_HDMI_MODE must be <group>:<mode>, e.g. 1:4 (got '$UEFI_HDMI_MODE')"
  HDMI_LINES="hdmi_group=${UEFI_HDMI_MODE%%:*}
hdmi_mode=${UEFI_HDMI_MODE##*:}"
fi

if [ -n "${SERIAL:-}" ]; then
  printf '%s' "$SERIAL" | grep -Eq '^[0-9a-f]{8}$' || die "SERIAL must be 8 lower-case hex digits, e.g. a1b2c3d4 (got '${SERIAL}')"
  # shellcheck disable=SC2086  # word splitting of the model list is intended
  set -- $MODELS
  [ "$#" -eq 1 ] || die "SERIAL=${SERIAL} requires exactly one MODEL (got '${MODELS}')"
fi

PFTF_COMMIT=$(git -C /build rev-parse HEAD)
RPI5_UEFI_COMMIT=$(git -C /build5 rev-parse HEAD)
# Trusted Firmware-A of the Pi 5 image: the tag pinned by RPI5_TFA_TAG (see the
# Dockerfile), or the rpi5-uefi submodule when that is empty
RPI5_TFA=$(cd /build5/arm-trusted-firmware && echo "$(git describe --tags --exact-match 2>/dev/null || echo submodule) $(git rev-parse HEAD)")
# iPXE commit of the Ethernet drivers the Dockerfile built (ipxe-usbnic.efi for
# the Pi 3, ipxe-rp1gem.efi for the Pi 5)
IPXE_COMMIT=$(git -C /ipxe rev-parse HEAD 2>/dev/null || echo none)
# devicetree-rebasing tag and commit the upstream device trees come from (see
# the Dockerfile)
UPSTREAM_DTS=$(cd /rpi-dts && echo "$(git describe --tags --exact-match 2>/dev/null || echo untagged) $(git rev-parse HEAD)")

# Change the default of one firmware setting (a "DynamicHii" PCD line in the .dsc):
#   <Guid>.<Pcd>|L"<Name>"|<VarGuid>|0x0|<default>
# Fails unless exactly one such line exists, so an upstream rename is noticed.
set_default() {
  local dsc=$1 name=$2 value=$3 pattern count
  pattern="(\\|L\"${name}\"\\|[A-Za-z0-9_]+\\|0x0\\|)[0-9]+[[:space:]]*\$"
  count=$(grep -cE "$pattern" "$dsc" || true)
  [ "$count" = "1" ] || die "expected exactly one '${name}' setting in $(basename "$dsc"), found ${count}; upstream changed"
  sed -i -E "s/${pattern}/\\1${value}/" "$dsc"
  grep -qE "\\|L\"${name}\"\\|[A-Za-z0-9_]+\\|0x0\\|${value}\$" "$dsc" || die "failed to set '${name}' in $(basename "$dsc")"
  log "setting default ${name}=${value}"
}

# Value of a gRaspberryPiTokenSpaceGuid PCD (e.g. PcdFdtBaseAddress) as a number:
# the platform's .dsc when it sets one, otherwise the default in RaspberryPi.dec.
fdt_pcd() {
  local dsc=$1 name=$2 value
  local dec="$SRC/edk2-platforms/Platform/RaspberryPi/RaspberryPi.dec"
  local pattern="^[[:space:]]*gRaspberryPiTokenSpaceGuid\\.${name}\\|(0x[0-9A-Fa-f]+|[0-9]+).*"
  value=$(sed -n -E "s/${pattern}/\\1/p" "$dsc" | tail -n 1)
  [ -n "$value" ] || value=$(sed -n -E "s/${pattern}/\\1/p" "$dec" | tail -n 1)
  [ -n "$value" ] || die "${name} not found in $(basename "$dsc") or RaspberryPi.dec; upstream changed"
  echo $((value))
}

# Default console preference of EmbeddedPkg's ConsolePrefDxe (used by every Pi
# platform): the value it takes when its variable is missing, which is always
# the case for a firmware loaded over TFTP. Its two default assignments are set,
# idempotently, since the edk2 tree is shared by the models of one source.
console_pref_default() {
  local c="$SRC/edk2/EmbeddedPkg/Drivers/ConsolePrefDxe/ConsolePrefDxe.c" value pattern
  case "$CONSOLE_MAIN" in auto) value=GRAPHICAL ;; serial) value=SERIAL ;; esac
  pattern='(ConsolePref\.Console[[:space:]]*=[[:space:]]*)CONSOLE_PREF_(GRAPHICAL|SERIAL);'
  [ "$(grep -cE "$pattern" "$c" || true)" = 2 ] || die "expected two default assignments in ConsolePrefDxe.c; upstream changed"
  sed -i -E "s/${pattern}/\\1CONSOLE_PREF_${value};/" "$c"
  [ "$(grep -cE "ConsolePref\\.Console[[:space:]]*=[[:space:]]*CONSOLE_PREF_${value};" "$c")" = 2 ] || die "failed to set the ConsolePrefDxe default"
  log "console preference default ${value} (CONSOLE_MAIN=${CONSOLE_MAIN})"
}

# Apply the patch files for one model. A patch that is already applied is
# skipped; one that neither applies nor is already applied fails the build.
apply_patches() {
  local model=$1 p
  for p in /patches/common/*.patch "/patches/${model}"/*.patch; do
    [ -f "$p" ] || continue
    if git -C "$SRC/edk2-platforms" apply --check "$p" 2>/dev/null; then
      git -C "$SRC/edk2-platforms" apply "$p"
      log "applied $(basename "$p")"
    elif git -C "$SRC/edk2-platforms" apply --reverse --check "$p" 2>/dev/null; then
      log "already applied: $(basename "$p")"
    else
      die "patch $(basename "$p") does not apply to edk2-platforms; upstream changed"
    fi
  done
}

# The config.txt that a pinned source ships for its port, as the base of ours:
# without CR, comments and blank lines, and without the lines this script decides
# itself. device_tree_address/_end come from the PCDs (see build_model; pftf/RPi4
# writes 0x400000 as the Pi 4's end, which matches EDK2 only with patch
# rpi4/0002 setting PcdFdtSize to 128 KB). hdmi_force_hotplug is never set.
upstream_config() {
  local file=$1 out
  [ -s "$file" ] || die "$file is missing; upstream changed"
  out=$(tr -d '\r' < "$file" | sed -E -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        -e '/^(device_tree_address|device_tree_end|hdmi_force_hotplug)=/d')
  printf '%s\n' "$out" | grep -qx 'armstub=RPI_EFI.fd' || die "$file has no armstub=RPI_EFI.fd line; upstream changed"
  printf '%s' "$out"
}

fetch() {
  # temp name first, so an interrupted transfer is never taken for a complete file
  local url=$1 dest=$2
  curl -fsSL "$url" -o "$dest.part"
  mv "$dest.part" "$dest"
}

build_model() {
  local model=$1 dsc_dir blobs dtbs dtbos config src_commit ipxe_driver=""
  # system table setting of this model; upstream_dt=1: build the upstream trees
  local table=$UEFI_SYSTEM_TABLE table_mode upstream_dt=0
  SRC=/build
  src_commit=$PFTF_COMMIT
  # No hdmi_force_hotplug (as under U-Boot and on the Pi 5): with it the firmware
  # creates a framebuffer even with no display, so ConsolePrefDxe always sees a
  # display and drops the serial console (CONSOLE_MAIN=auto). Without it a
  # connected display still works (Pi 4 with an HDMI capture device, 2026-11-22;
  # the capture device counts as a display only while it is streaming).
  case "$model" in
    rpi3)
      dsc_dir=RPi3
      ipxe_driver=$SRC/ipxe-usbnic.efi
      blobs="start.elf fixup.dat"
      dtbs="bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-cm3.dtb"
      dtbos="miniuart-bt.dtbo"
      # Written here: the pinned source (pftf/RPi4) ships no Pi 3 config.txt.
      # pftf/RPi3's file (not pinned) differs: disable_commandline_tags=2 and no
      # miniuart-bt; ours keeps the PL011 on the GPIO header as on the Pi 4.
      config='arm_64bit=1
enable_uart=1
uart_2ndstage=1
armstub=RPI_EFI.fd
disable_commandline_tags=1
disable_overscan=1
dtoverlay=miniuart-bt'
      ;;
    rpi4)
      dsc_dir=RPi4
      blobs="start4.elf fixup4.dat"
      dtbs="bcm2711-rpi-4-b.dtb bcm2711-rpi-cm4.dtb bcm2711-rpi-400.dtb"
      dtbos="miniuart-bt.dtbo upstream-pi4.dtbo"
      # pftf/RPi4's own config.txt of the pinned source, unchanged apart from
      # the lines upstream_config replaces.
      config=$(upstream_config "$SRC/config.txt")
      ;;
    rpi5)
      SRC=/build5
      src_commit=$RPI5_UEFI_COMMIT
      dsc_dir=RPi5
      ipxe_driver=$SRC/ipxe-rp1gem.efi
      [ "$UEFI_RPI5_DT" != upstream ] || upstream_dt=1
      # The Pi 5 has no start.elf: its bootloader loads config.txt, the device
      # tree and the firmware by itself.
      blobs=""
      # The board families the EDK2 port knows. A bootloader asks for the file
      # of its own board; a D0 board asks for the bcm2712d0 one first.
      dtbs="bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-d-rpi-5-b.dtb bcm2712-rpi-500.dtb bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5-cm4io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2712-rpi-cm5l-cm4io.dtb"
      dtbos="bcm2712d0.dtbo"
      # The EDK2 port's own config.txt of the pinned source, plus enable_uart=1:
      # it makes the Pi firmware name the UART on GPIO 14/15 "serial0" in the
      # device tree; patches/rpi5/0002 puts a console there only then. Without
      # the line the two pins are left alone.
      config=$(upstream_config "$SRC/config.txt")
      printf '%s\n' "$config" | grep -qx 'enable_uart=1' || config=$(printf '%s\nenable_uart=1' "$config")
      ;;
    *) die "MODEL must be rpi3, rpi4 and/or rpi5 (got '${model}')" ;;
  esac

  local generic="/out/generic-${model}" info fingerprint
  info="${generic}/${model}-uefi.txt"
  # Everything that changes the result. The build is redone when any of it changes.
  fingerprint=$( {
    echo "$src_commit $IPXE_COMMIT $START_ELF_VERSION $DTB_VERSION $DTBO_VERSION"
    # the Pi 5's Trusted Firmware-A, pinned apart from src_commit
    [ "$model" != rpi5 ] || echo "$RPI5_TFA"
    echo "$UEFI_BUILD_TYPE $UEFI_BOOT_TIMEOUT $table $UEFI_RAM_LIMIT_3GB $UEFI_HDMI_MODE $UEFI_IPV6 $CONSOLE_MAIN"
    # the upstream device trees and their sources
    [ "$upstream_dt" = 0 ] || { echo "$UPSTREAM_DTS"; cat /dts/*; }
    # the embedded iPXE driver (its build options live in the Dockerfile)
    [ -z "$ipxe_driver" ] || [ ! -f "$ipxe_driver" ] || sha256sum < "$ipxe_driver"
    cat "$0" /patches/common/*.patch "/patches/${model}"/*.patch "/patches/${model}-tfa"/*.patch /patches/ipxe/*.patch 2>/dev/null
  } | sha256sum | cut -d' ' -f1 )

  # The info file is written last, so it also marks a build as complete.
  if [ "$FORCE_UEFI_REBUILD" != "1" ] && [ -f "$generic/RPI_EFI.fd" ] && \
     grep -qx "fingerprint=${fingerprint}" "$info" 2>/dev/null; then
    log "${model}: already built with these settings; skipping (FORCE_UEFI_REBUILD=1 to rebuild)"
    return
  fi
  rm -rf "$generic"
  mkdir -p "$generic/overlays"

  # ── sources: pristine platform files, then patches and settings ────────────
  git -C "$SRC/edk2-platforms" checkout -- Platform/RaspberryPi
  # patches/rpi3 and patches/rpi5 embed this driver; the EDK2 build fails late
  # and unclearly without it
  if [ -n "$ipxe_driver" ]; then [ -s "$ipxe_driver" ] || die "${model}: $ipxe_driver is missing (built by the Dockerfile)"; fi
  apply_patches "$model"
  local dsc="$SRC/edk2-platforms/Platform/RaspberryPi/${dsc_dir}/${dsc_dir}.dsc"
  set_default "$dsc" Timeout "$UEFI_BOOT_TIMEOUT"
  table_mode=$(system_table_mode "system table" "$table")
  [ -z "$table_mode" ] || set_default "$dsc" SystemTableMode "$table_mode"
  [ "$model" != "rpi4" ] || set_default "$dsc" RamLimitTo3GB "$UEFI_RAM_LIMIT_3GB"
  # The Pi 3 platform has no ConsolePrefDxe: nothing removes stdout-path or SPCR
  # there, so its serial console is always described (as CONSOLE_MAIN=serial).
  if grep -q 'EmbeddedPkg/Drivers/ConsolePrefDxe/ConsolePrefDxe.inf' "$dsc"; then
    console_pref_default
  else
    log "${model}: ${dsc_dir}.dsc has no ConsolePrefDxe; the serial console is always kept (CONSOLE_MAIN=${CONSOLE_MAIN} has no effect)"
  fi
  # Where the Pi firmware puts the device tree (config.txt device_tree_address
  # and _end) must be where EDK2 looks for it: PcdFdtBaseAddress and PcdFdtSize
  # of the source being built (the platform's .dsc, else RaspberryPi.dec).
  # Taken from the source, not written here: upstream moved the Pi 4's tree from
  # 0x1f0000 to 0x3e0000 when its firmware image grew (edk2-platforms 991b802e8f,
  # 2024-09), and a stale address here leaves the OS without a device tree
  # ("No devicetree passed via config.txt"; seen 2026-11-22).
  local fdt_base fdt_size
  fdt_base=$(fdt_pcd "$dsc" PcdFdtBaseAddress)
  fdt_size=$(fdt_pcd "$dsc" PcdFdtSize)
  config=$(printf '%s\ndevice_tree_address=0x%x\ndevice_tree_end=0x%x' "$config" "$fdt_base" $((fdt_base + fdt_size)))
  log "${model}: device tree at 0x$(printf '%x' "$fdt_base"), up to 0x$(printf '%x' $((fdt_size))) bytes"

  # ── build ──────────────────────────────────────────────────────────────────
  export WORKSPACE=$SRC
  export PACKAGES_PATH=$SRC/edk2:$SRC/edk2-platforms:$SRC/edk2-non-osi
  export PYTHON_COMMAND=python3
  export EDK_TOOLS_PATH=$SRC/edk2/BaseTools
  export CONF_PATH=$SRC/Conf
  mkdir -p "$CONF_PATH"
  # EDK2 renamed its GCC toolchain tag from GCC5 to GCC. Use whichever this checkout defines.
  local toolchain=GCC target=RELEASE
  if grep -q '_GCC5_AARCH64_CC_PATH' "$SRC/edk2/BaseTools/Conf/tools_def.template"; then toolchain=GCC5; fi
  export GCC_AARCH64_PREFIX="${GCC_AARCH64_PREFIX:-aarch64-linux-gnu-}"
  export GCC5_AARCH64_PREFIX="$GCC_AARCH64_PREFIX"
  # No Secure Boot: the iPXE binaries this stack serves are unsigned.
  local flags="-D INCLUDE_TFTP_COMMAND=TRUE -D NETWORK_ISCSI_ENABLE=TRUE -D SMC_PCI_SUPPORT=1"
  flags="$flags -D NETWORK_TLS_ENABLE=FALSE -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE"
  [ "$UEFI_IPV6" = 1 ] || flags="$flags -D NETWORK_IP6_ENABLE=FALSE"
  case "$UEFI_BUILD_TYPE" in
    debug) target=DEBUG ;;
    warn)
      target=DEBUG
      # 0x80000002 = errors and warnings only; property mask 0x02 = print, but
      # asserts neither break nor dead-loop
      flags="$flags -D DEBUG_PRINT_ERROR_LEVEL=0x80000002 --pcd gEfiMdePkgTokenSpaceGuid.PcdDebugPropertyMask=0x02"
      ;;
  esac
  if [ "$model" = rpi5 ]; then
    # The Pi 5 firmware image starts with Trusted Firmware-A (BL31), which the
    # EDK2 build picks up from TFA_BUILD_ARTIFACTS. Same settings as the EDK2
    # port's own build script; always a release build.
    # Source patches for Trusted Firmware-A (patches/rpi5-tfa), applied to
    # pristine sources. One that no longer applies fails the build.
    git -C "$SRC/arm-trusted-firmware" checkout -- .
    local tp
    for tp in "/patches/${model}-tfa"/*.patch; do
      [ -f "$tp" ] || continue
      if ! git -C "$SRC/arm-trusted-firmware" apply --check "$tp" 2>/dev/null; then
        die "patch $(basename "$tp") does not apply to arm-trusted-firmware; upstream changed"
      fi
      git -C "$SRC/arm-trusted-firmware" apply "$tp"
      log "applied $(basename "$tp") (Trusted Firmware-A)"
    done
    log "${model}: building Trusted Firmware-A"
    make -C "$SRC/arm-trusted-firmware" \
      CROSS_COMPILE="$GCC_AARCH64_PREFIX" \
      PLAT=rpi5 \
      PRELOADED_BL33_BASE=0x20000 \
      RPI3_PRELOADED_DTB_BASE=0x3E0000 \
      SUPPORT_VFP=1 \
      SMC_PCI_SUPPORT=1 \
      DEBUG=0 \
      all > "/tmp/build-${model}-tfa.log" 2>&1 || { tail -40 "/tmp/build-${model}-tfa.log"; die "${model}: Trusted Firmware-A build failed (log above)"; }
    [ -s "$SRC/arm-trusted-firmware/build/rpi5/release/bl31.bin" ] || die "${model}: Trusted Firmware-A built but bl31.bin is missing"
    flags="$flags -D TFA_BUILD_ARTIFACTS=$SRC/arm-trusted-firmware/build/rpi5/release"
  fi
  log "${model}: building ${dsc_dir}.dsc (${target}, toolchain ${toolchain}, sources ${src_commit})"
  (
    cd "$SRC"
    # edksetup.sh is not written for "set -eu", and it parses the caller's
    # positional parameters as its own options: clear them first.
    set --
    set +eu
    # shellcheck disable=SC1091
    source "$SRC/edk2/edksetup.sh" >/dev/null
    set -eu
    # shellcheck disable=SC2086  # flags are intentionally word-split
    build -a AARCH64 -t "$toolchain" -b "$target" -p "edk2-platforms/Platform/RaspberryPi/${dsc_dir}/${dsc_dir}.dsc" $flags
  ) > "/tmp/build-${model}.log" 2>&1 || { tail -40 "/tmp/build-${model}.log"; die "${model}: EDK2 build failed (log above)"; }
  local fd="$SRC/Build/${dsc_dir}/${target}_${toolchain}/FV/RPI_EFI.fd"
  [ -s "$fd" ] || die "${model}: build finished but $fd is missing or empty"

  # ── Raspberry Pi boot files ────────────────────────────────────────────────
  local f
  for f in $blobs; do fetch "${RPI_FIRMWARE_URL}/raw/${START_ELF_VERSION}/boot/${f}" "$generic/${f}"; done
  for f in $dtbs;  do fetch "${RPI_FIRMWARE_URL}/raw/${DTB_VERSION}/boot/${f}" "$generic/${f}"; done
  for f in $dtbos; do fetch "${RPI_FIRMWARE_URL}/raw/${DTBO_VERSION}/boot/overlays/${f}" "$generic/overlays/${f}"; done
  # Pi 5 B: the upstream trees in place of Raspberry Pi's, under the names the
  # Pi firmware asks for. A D0 board asks for bcm2712d0-rpi-5-b.dtb first,
  # which gets the D0 tree too. The firmware applies config.txt to them
  # (enable_uart=1 enables the UART0 node) and EDK2 hands them to the OS.
  if [ "$upstream_dt" = 1 ]; then
    rm -rf /tmp/upstream-dt
    bash /dts/build-rpi-upstream.sh /rpi-dts /tmp/upstream-dt dtc "${GCC_AARCH64_PREFIX}gcc" rpi5
    cp /tmp/upstream-dt/broadcom/bcm2712-rpi-5-b.dtb "$generic/bcm2712-rpi-5-b.dtb"
    cp /tmp/upstream-dt/broadcom/bcm2712-d-rpi-5-b.dtb "$generic/bcm2712-d-rpi-5-b.dtb"
    cp /tmp/upstream-dt/broadcom/bcm2712-d-rpi-5-b.dtb "$generic/bcm2712d0-rpi-5-b.dtb"
    log "${model}: Pi 5 B device trees replaced by the upstream ones"
  fi
  printf '%s\n' "$config" > "$generic/config.txt"
  [ -z "$HDMI_LINES" ] || printf '%s\n' "$HDMI_LINES" >> "$generic/config.txt"
  # tryboot.txt: a copy of config.txt. After "reboot '0 tryboot'" (Ubuntu's
  # piboot-try after a kernel update, rpi-eeprom) a Pi 4 or Pi 5 reads
  # tryboot.txt instead of config.txt; over the network a missing file made the
  # Pi 5 ask for it again and again and never boot (2026-11-25, issue #3).
  cp "$generic/config.txt" "$generic/tryboot.txt"

  cp "$fd" "$generic/RPI_EFI.fd"
  cat > "$info" <<EOF
model=${model}
firmware=uefi
source_commit=${src_commit}
ipxe_driver_commit=$( [ -n "$ipxe_driver" ] && echo "$IPXE_COMMIT" || echo "not used" )
trusted_firmware=$( [ "$model" = rpi5 ] && echo "$RPI5_TFA" || echo "not used" )
build_type=${UEFI_BUILD_TYPE}
boot_timeout=${UEFI_BOOT_TIMEOUT}
system_table=${table}
device_tree=$( [ "$upstream_dt" = 1 ] && echo "upstream (devicetree-rebasing ${UPSTREAM_DTS} + RP1 UART0)" || echo firmware )
hdmi_mode=${UEFI_HDMI_MODE:-auto}
ipv6=${UEFI_IPV6}
start_elf_version=${START_ELF_VERSION}
dtb_version=${DTB_VERSION}
dtbo_version=${DTBO_VERSION}
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fingerprint=${fingerprint}
EOF
  log "${model}: done ($(stat -c %s "$generic/RPI_EFI.fd") bytes)"
}

for model in $MODELS; do
  build_model "$model"
done

# ── optional per-device directory ─────────────────────────────────────────────
if [ -n "${SERIAL:-}" ]; then
  rm -rf "/out/tftp/${SERIAL}"
  mkdir -p /out/tftp
  cp -r "/out/generic-${MODELS}" "/out/tftp/${SERIAL}"
  log "per-device directory tftp/${SERIAL}/ populated from generic-${MODELS}"
fi

chown -R "${PUID:-500}:${PGID:-500}" /out
log "done"
ls -lh /out/
