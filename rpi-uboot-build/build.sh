#!/bin/bash
set -eux

# Defaults, so the image also runs without the compose file (e.g. in CI).
: "${ARCH:=arm}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${RPI_FIRMWARE_URL:=https://github.com/raspberrypi/firmware}"
# Pinned raspberrypi/firmware commit the boot files come from
: "${FIRMWARE_VERSION:=d131b57900035c0562af1898c00a1bf59d3b9d1e}"
: "${EFI_ARM64_RPI_FILE:=ipxe/snponly-arm64-rpi.efi}"
# Main console of the operating system (build.env; the same setting as under
# UEFI). Becomes the environment variable console_main, read by patches/0007
# when U-Boot hands a device tree to an EFI program:
#   auto    with a display present /chosen/stdout-path is removed, so Linux
#           makes the display its main console; without one serial is kept
#   serial  stdout-path is always kept: serial is main, the display second
# For one boot it can also be changed at the U-Boot prompt
# (setenv console_main serial; boot).
: "${CONSOLE_MAIN:=auto}"
case "${CONSOLE_MAIN}" in
  auto|serial) ;;
  *) echo "[rpi-uboot-build] ERROR: CONSOLE_MAIN must be auto or serial (got '${CONSOLE_MAIN}')" >&2; exit 1 ;;
esac

# Ready-to-serve tree: copy its contents to the TFTP root.
TFTP=/out/tftp

build_model() {
  local MODEL=$1
  # Only the Pi 5 sets it (below): no upstream tree is handed over on the others.
  local UPSTREAM_DT=0

# ── model config ──────────────────────────────────────────────────────────────
case "${MODEL}" in
  rpi3)
    DEFCONFIG=rpi_3_defconfig
    GENERIC=/out/generic-rpi3
    NEEDS_BOOTCODE=1
    FIRMWARE_BLOBS="start.elf fixup.dat"
    # bcm2710 = Pi 3B / 3B+ / CM3
    DTB_FILES="bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-cm3.dtb"
    DTBO_FILES="miniuart-bt.dtbo"
    # No wait before DHCP (see rpi4). Measured on a Pi 3B: 24.7 s from banner to
    # boot.ipxe with a 5 s sleep, 19.8 s without, cold and warm.
    PRE_DHCP_SLEEP=0
    CONFIG_TXT=$(cat <<'EOF'
arm_64bit=1
enable_uart=1
uart_2ndstage=1
kernel=u-boot.bin
disable_overscan=1
dtoverlay=miniuart-bt
framebuffer_swap=0
EOF
)
    ;;
  rpi4)
    DEFCONFIG=rpi_4_defconfig
    GENERIC=/out/generic-rpi4
    NEEDS_BOOTCODE=0
    FIRMWARE_BLOBS="start4.elf fixup4.dat"
    # bcm2711 = Pi 4B / 400 / CM4
    DTB_FILES="bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb bcm2711-rpi-cm4.dtb"
    DTBO_FILES=""
    # No wait before DHCP, as in upstream's own boot commands: U-Boot waits up to
    # 4 s for the link and retries DHCP for 28 s by itself. A 5 s sleep here was
    # pure waiting on a Pi 4 (measured: 9.5 s from banner to boot.ipxe with it,
    # 5.3 s without, cold and warm).
    PRE_DHCP_SLEEP=0
    CONFIG_TXT=$(cat <<'EOF'
arm_64bit=1
enable_uart=1
uart_2ndstage=1
kernel=u-boot.bin
disable_overscan=1
framebuffer_swap=0
EOF
)
    ;;
  rpi5)
    DEFCONFIG=rpi_arm64_defconfig
    GENERIC=/out/generic-rpi5
    NEEDS_BOOTCODE=0
    FIRMWARE_BLOBS=""
    # bcm2712 = Pi 5 and its relatives. A bootloader asks for the file of its own
    # board (a D0 board for the bcm2712d0 one first), so the same list as in
    # rpi-uefi-build. Only the Pi 5 B (C1) has been booted.
    DTB_FILES="bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-d-rpi-5-b.dtb bcm2712-rpi-500.dtb bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5-cm4io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2712-rpi-cm5l-cm4io.dtb"
    # vc4-kms-v3d-pi5: without it Raspberry Pi's kernel has no display on a
    # Pi 5 when U-Boot hands over the firmware's tree (the default): no
    # framebuffer, no DRM device (Alpine linux-rpi, 2026-11-23). Raspberry Pi OS
    # sets the generic vc4-kms-v3d, which the firmware maps to this file via
    # overlay_map.dtb; the explicit name needs no map. It does not change
    # U-Boot's output or a tree loaded with fdt.
    DTBO_FILES="bcm2712d0.dtbo vc4-kms-v3d-pi5.dtbo"
    # Upstream Linux device trees (devicetree-rebasing) for the boards that
    # have one (bcm2712-rpi-5-b, bcm2712-d-rpi-5-b), with the RP1's UART0 added
    # (dts/ at the repository root). They describe RP1 as upstream Linux
    # expects (a PCI device under pcie2); the firmware's trees describe it as
    # Raspberry Pi's kernel expects, and a distribution kernel finds no
    # Ethernet with those. See UBOOT_RPI5_EFI_FDT below.
    UPSTREAM_DT=1
    # Pi 5 Ethernet and USB sit behind the RP1 chip, which upstream U-Boot has no
    # driver for: patches/rpi5 adds them.
    # No wait before DHCP (see rpi4). Measured on a Pi 5: 16 s from U-Boot's
    # download to the iPXE download with a 5 s sleep, 10 to 10.6 s without, in
    # 8 boots out of 8, cold and warm.
    PRE_DHCP_SLEEP=0
    # Pi 5 uses config.txt but the kernel= line works the same way.
    # enable_uart=1 needs patches/0005: without it U-Boot stops at its prompt.
    CONFIG_TXT=$(cat <<'EOF'
arm_64bit=1
enable_uart=1
kernel=u-boot.bin
disable_overscan=1
dtoverlay=vc4-kms-v3d-pi5
EOF
)
    ;;
  *)
    echo "[rpi-uboot-build] ERROR: MODEL must be rpi3, rpi4, or rpi5 (got '${MODEL}')" >&2
    exit 1
    ;;
esac

# ── skip build if artifacts already exist ────────────────────────────────────
if [ "${FORCE_UBOOT_REBUILD:-0}" = "1" ]; then
  echo "[rpi-uboot-build] FORCE_UBOOT_REBUILD=1; removing existing artifacts."
  rm -rf "$GENERIC"
  [ "$NEEDS_BOOTCODE" = "1" ] && rm -f /out/bootcode.bin
fi

# ${MODEL}.txt is written last, so together with u-boot.bin it marks a completed
# build; u-boot.bin alone would also match a run whose blob downloads failed.
if [ -f "$GENERIC/u-boot.bin" ] && [ -f "$GENERIC/${MODEL}.txt" ]; then
  echo "[rpi-uboot-build] Existing artifacts detected; skipping build."
else

  # ── build U-Boot ────────────────────────────────────────────────────────────
  cd /build/u-boot
  # Undo the source patches of a previously built model in this container, so each
  # model is built from pristine sources plus exactly its own patches.
  git checkout -- .
  git clean -fdq
  # ── source patches ──────────────────────────────────────────────────────────
  # /patches/*.patch for every model, then /patches/<model>/*.patch (see
  # patches/README.md). Applied before the defconfig step because a patch may
  # change the defconfig. A patch that no longer applies fails the build instead
  # of being skipped silently.
  for p in /patches/*.patch "/patches/${MODEL}"/*.patch; do
    [ -f "$p" ] || continue
    if ! git apply --check "$p"; then
      echo "[rpi-uboot-build] ERROR: $(basename "$p") does not apply to U-Boot; upstream changed" >&2
      exit 1
    fi
    git apply --whitespace=nowarn "$p"
    echo "[rpi-uboot-build] applied $(basename "$p")"
  done
  make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" mrproper
  make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${DEFCONFIG}"
  # SERVERIP_FROM_PROXYDHCP: read serverip from siaddr in the ProxyDHCP reply
  # (yiaddr=0 packet from dnsmasq) instead of the main DHCP reply from the router.
  # patches/0004 keeps the main DHCP reply as the fallback, for a network where
  # the DHCP server itself is the boot server.
  # BOOTP_PREFER_SERVERIP: if serverip is already set, don't overwrite it on
  # subsequent DHCP calls — add this if serverip ever gets clobbered after boot.
  # NET_LEGACY instead of NET_LWIP: since v2026.10 rpi_arm64_defconfig (the Pi 5 build)
  # selects the lwIP network stack, which has no SERVERIP_FROM_PROXYDHCP. With
  # lwIP U-Boot asks the router for the iPXE file and never gets it.
  ./scripts/config --disable NET_LWIP
  ./scripts/config --enable NET_LEGACY
  ./scripts/config --enable SERVERIP_FROM_PROXYDHCP
  ./scripts/config --enable BOOTP_SEND_HOSTNAME
  # client-arch 0xb (11 = ARM64 EFI) so dnsmasq's arm64efi tag fires.
  # rpi_arm64_defconfig defaults to 0x16 (EFI BC) which dnsmasq does not match.
  ./scripts/config --set-val DHCP_PXE_CLIENTARCH 0xb
  ./scripts/config --enable PHY_BROADCOM
  # Full USB keyboard driver chain for RPi4/5 (xHCI — VL805 on PCIe for Pi4, RP1 for Pi5):
  #   CMD_USB      — the `usb start` command, run by the preboot command
  #   USB_XHCI_HCD — xHCI host controller driver
  #   USB_XHCI_PCI — PCIe bridge (VL805 on Pi4, RP1 on Pi5)
  #   USB_KEYBOARD — HID keyboard mapped to EFI_SIMPLE_TEXT_INPUT by bootefi
  # USB is started by the preboot command of every defconfig used here ("usb start"
  # in rpi_3_defconfig, "pci enum; usb start;" in rpi_4_defconfig and
  # rpi_arm64_defconfig, the latter extended by patches/rpi5/0014), so the boot
  # commands below do not start it again.
  ./scripts/config --enable CMD_USB
  ./scripts/config --enable USB_XHCI_HCD
  ./scripts/config --enable USB_XHCI_PCI
  ./scripts/config --enable USB_KEYBOARD
  # Text on a 16-bit framebuffer. The Pi 5 firmware hands over 16 bits per pixel
  # even though U-Boot asks for 32, and rpi_arm64_defconfig leaves 16-bit drawing
  # out: the logo shows, but all text is black on black and a screen clear (the
  # iPXE menu) fills the screen with one colour.
  ./scripts/config --enable VIDEO_BPP16
  # `env set -e` (UEFI variables from the shell), for the FdtFile variable below.
  ./scripts/config --enable CMD_NVEDIT_EFI
  make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

  # ── boot environment ────────────────────────────────────────────────────────
  # Compiled into the binary so it works without a saved environment (there is no
  # SD card: "Card did not respond to voltage select").
  #   bootp_vci=PXEClient  dnsmasq's ProxyDHCP answers this vendor class
  #   netboot              wait, DHCP (serverip comes from the ProxyDHCP reply),
  #                        fetch the iPXE EFI binary over TFTP and start it
  #   localboot            upstream's standard boot (bootflow scan, the upstream
  #                        bootcmd) of the local devices in upstream's
  #                        boot_targets: mmc and usb, on the Pi 5 also nvme
  #                        (patches/rpi5/0013). The network targets (pxe, dhcp)
  #                        are taken out of boot_targets for the scan and put
  #                        back afterwards: netboot did that. (bootflow scan
  #                        takes a device name only with BOOTSTD_FULL, which
  #                        these defconfigs do not enable.)
  #                        UBOOT_LOCAL_BOOT_ORDER replaces that list and order,
  #                        e.g. "usb mmc"; nvme is left out on the Pi 3 and Pi 4,
  #                        whose builds have no NVMe driver.
  #   bootcmd             run netboot; if any step of it fails (server down,
  #                        link not up yet) or iPXE returns (netboot.xyz's
  #                        "Boot from local hdd" is iPXE returning), run
  #                        localboot; if nothing boots, wait 10 seconds and
  #                        reset, so a headless Pi retries on its own instead
  #                        of sitting at the U-Boot prompt. Ctrl-C during the
  #                        wait gives the prompt.
  # The file name and the per-model parts vary, so this is generated here rather
  # than kept as a patch file.
  PRE_DHCP_SLEEP="${UBOOT_PRE_DHCP_SLEEP:-$PRE_DHCP_SLEEP}"
  if [ -z "${UBOOT_LOCAL_BOOT_ORDER:-}" ]; then
    # upstream's boot_targets without the network targets
    LOCAL_TARGETS='setenv boot_targets; for target in ${all_targets}; do if test ${target} != pxe && test ${target} != dhcp; then setenv boot_targets ${boot_targets} ${target}; fi; done'
  else
    LOCAL_ORDER=""
    for target in ${UBOOT_LOCAL_BOOT_ORDER}; do
      case "${target}" in
        mmc|usb) ;;
        nvme) if [ "${MODEL}" != rpi5 ]; then echo "[rpi-uboot-build] ${MODEL}: nvme left out of UBOOT_LOCAL_BOOT_ORDER (no NVMe driver in this build)"; continue; fi ;;
        *) echo "[rpi-uboot-build] ERROR: UBOOT_LOCAL_BOOT_ORDER may only contain mmc, usb and nvme (got '${target}')" >&2; exit 1 ;;
      esac
      LOCAL_ORDER="${LOCAL_ORDER:+${LOCAL_ORDER} }${target}"
    done
    LOCAL_TARGETS="setenv boot_targets ${LOCAL_ORDER}"
  fi
  # UEFI variable FdtFile (vendor GUID below, boot services only): the path of
  # this board's upstream Linux device tree in the layout distributions use,
  # U-Boot's own ${fdtfile} (e.g. broadcom/bcm2711-rpi-4-b.dtb). Set before
  # every boot, network or disk, so a loader (iPXE: ${efi/FdtFile:string})
  # can load the tree an OS needs with `fdt`. The firmware still hands over its
  # own tree. rpi-uefi-build publishes the same variable.
  FDTFILE_VAR_GUID=eedf58fc-1b9b-4ab0-8b6b-954d79d6b052
  # Device tree handed to iPXE and from there to the kernel it starts
  # (UBOOT_RPI5_EFI_FDT, Pi 5 only):
  #   firmware (default)  the firmware's tree, U-Boot's own (${fdt_addr}), as on
  #                       every Pi (design rule R3, README.md): an OS that needs the upstream tree
  #                       loads it itself (`fdt` by the FdtFile variable)
  #   upstream            rpi/upstream/${fdtfile} from the TFTP server, an
  #                       upstream Linux tree built below; a board without one
  #                       (CM5, Pi 500) gets the firmware's tree instead
  # It is fetched before iPXE because bootefi starts only the image loaded last.
  EFI_FDT_STEP=""
  EFI_FDT_ADDR='${fdt_addr}'
  EFI_FDT_ENV=""
  case "${UBOOT_RPI5_EFI_FDT:-firmware}" in
    upstream)
      if [ "${UPSTREAM_DT}" = 1 ]; then
        EFI_FDT_STEP='run efifdt && '
        EFI_FDT_ADDR='${efi_fdt_addr}'
        EFI_FDT_ENV='"efifdt=setenv efi_fdt_addr ${fdt_addr}; if tftpboot ${fdt_addr_r} ${serverip}:rpi/upstream/${fdtfile}; then setenv efi_fdt_addr ${fdt_addr_r}; else echo No upstream device tree for this board, using the firmware one; fi\\0" '
      fi ;;
    firmware) UPSTREAM_DT=0 ;;
    *) echo "[rpi-uboot-build] ERROR: UBOOT_RPI5_EFI_FDT must be upstream or firmware (got '${UBOOT_RPI5_EFI_FDT}')" >&2; exit 1 ;;
  esac
  sed -i '$i #define CFG_EXTRA_ENV_SETTINGS "bootp_vci=PXEClient\\0" "console_main='"${CONSOLE_MAIN}"'\\0" '"${EFI_FDT_ENV}"'"netboot=setenv autoload no && sleep '"${PRE_DHCP_SLEEP}"' && dhcp && '"${EFI_FDT_STEP}"'tftpboot ${kernel_addr_r} ${serverip}:'"${EFI_ARM64_RPI_FILE}"' && bootefi ${kernel_addr_r} '"${EFI_FDT_ADDR}"'\\0" "localboot=setenv all_targets ${boot_targets}; '"${LOCAL_TARGETS}"'; echo Trying local devices: ${boot_targets}; bootflow scan; setenv boot_targets ${all_targets}\\0" "fdtvar=env set -e -bs -guid '"${FDTFILE_VAR_GUID}"' FdtFile ${fdtfile} || echo Could not publish FdtFile\\0" "bootcmd=run fdtvar; run netboot; run localboot; echo Nothing booted, resetting in 10 seconds; sleep 10; reset\\0"' include/configs/rpi.h
  # ── version string ──────────────────────────────────────────────────────────
  # Shown in the U-Boot banner. Without this file U-Boot appends "-dirty",
  # because the tree carries patches. CI sets the suffix to -pxe-<commit>.
  printf '%s\n' "${UBOOT_VERSION_SUFFIX:--pxe}" > .scmversion
  echo "[rpi-uboot-build] active config options:"
  grep -E "SERVERIP_FROM_PROXYDHCP|BOOTP_SEND_HOSTNAME|DHCP_PXE_CLIENTARCH|CMD_USB|USB_XHCI|USB_KEYBOARD" .config || echo "(none matched)"
  # olddefconfig drops an option silently when its dependencies are not met.
  # Without this one the boot server is never found, so fail here instead.
  if ! grep -q '^CONFIG_SERVERIP_FROM_PROXYDHCP=y' .config; then
    echo "[rpi-uboot-build] ERROR: SERVERIP_FROM_PROXYDHCP is not in the final config; upstream changed" >&2
    exit 1
  fi
  echo "[rpi-uboot-build] rpi.h patch:"
  if ! grep "CFG_EXTRA_ENV_SETTINGS" include/configs/rpi.h; then
    echo "[rpi-uboot-build] ERROR: boot environment was not added to include/configs/rpi.h; upstream changed" >&2
    exit 1
  fi
  if [ "${UBOOT_DEBUG_ARTIFACTS:-0}" = "1" ]; then
    mkdir -p /out/debug
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)" 2>&1 | tee /out/debug/build-${MODEL}.log
    cp /build/u-boot/u-boot        /out/debug/u-boot-${MODEL}
    cp /build/u-boot/u-boot.map    /out/debug/u-boot-${MODEL}.map
    cp /build/u-boot/.config       /out/debug/u-boot-${MODEL}.config
  else
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)" u-boot.bin
  fi

  # ── upstream device trees, every family ─────────────────────────────────────
  # From devicetree-rebasing (the Linux device trees at the release pinned by
  # RPI_DT_TAG in build.env, fetched by the Dockerfile to /rpi-dts; Pi 5:
  # plus the RP1's UART0), with U-Boot's own dtc, served as
  # rpi/upstream/broadcom/<board>.dtb. A boot script loads the one an OS needs
  # by the FdtFile variable (`fdt .../rpi/upstream/${efi/FdtFile:string}`, rule
  # R3); on the Pi 5 with UBOOT_RPI5_EFI_FDT=upstream U-Boot also hands it over
  # itself. The script (dts/ at the repository root, copied to /dts) is shared
  # with rpi-uefi-build. A tree that does not build fails the build.
  # patches/rpi5/0021 enables the Pi 5's UART and picks the console.
  rm -rf "$GENERIC/upstream"
  bash /dts/build-rpi-upstream.sh /rpi-dts "$GENERIC/upstream" ./scripts/dtc/dtc "${CROSS_COMPILE}gcc" "${MODEL}"

  mkdir -p "$GENERIC/overlays"

  # ── fetch RPi firmware blobs ─────────────────────────────────────────────────
  fetch_if_missing() {
    local url=$1 dest=$2
    if [ ! -f "$dest" ]; then
      # temp name first, so an interrupted transfer is never taken for a complete file
      curl -fsSL "$url" -o "$dest.part"
      mv "$dest.part" "$dest"
    else
      echo "skipped $(basename "$dest") (already present)"
    fi
  }

  if [ "$NEEDS_BOOTCODE" = "1" ]; then
    fetch_if_missing \
      "${RPI_FIRMWARE_URL}/raw/${FIRMWARE_VERSION}/boot/bootcode.bin" \
      /out/bootcode.bin
  fi

  for blob in $FIRMWARE_BLOBS; do
    fetch_if_missing \
      "${RPI_FIRMWARE_URL}/raw/${FIRMWARE_VERSION}/boot/${blob}" \
      "$GENERIC/${blob}"
  done

  for dtb in $DTB_FILES; do
    fetch_if_missing \
      "${RPI_FIRMWARE_URL}/raw/${FIRMWARE_VERSION}/boot/${dtb}" \
      "$GENERIC/${dtb}"
  done

  for dtbo in $DTBO_FILES; do
    fetch_if_missing \
      "${RPI_FIRMWARE_URL}/raw/${FIRMWARE_VERSION}/boot/overlays/${dtbo}" \
      "$GENERIC/overlays/${dtbo}"
  done

  # ── write model tag ────────────────────────────────────────────────────────────
  FIRMWARE_SHA=$(curl -fsSL "https://api.github.com/repos/raspberrypi/firmware/commits/${FIRMWARE_VERSION}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])") || FIRMWARE_SHA=unknown
  # (informational only — the unauthenticated GitHub API is rate-limited, so it must not fail the build)

  # u-boot.bin and the model tag go in last: together they mark the build as complete.
  cp /build/u-boot/u-boot.bin "$GENERIC/u-boot.bin"
  cat > "$GENERIC/${MODEL}.txt" <<EOF
model=${MODEL}
firmware_sha=${FIRMWARE_SHA}
upstream_dts=devicetree-rebasing $(cd /rpi-dts && git describe --tags --exact-match 2>/dev/null || echo untagged) $(git -C /rpi-dts rev-parse HEAD)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

fi

# ── write config.txt (always — static per model, cheap to regenerate) ─────────
printf '%s\n' "${CONFIG_TXT}" > "$GENERIC/config.txt"
# tryboot.txt: a copy of config.txt. After "reboot '0 tryboot'" (Ubuntu's
# piboot-try after a kernel update, rpi-eeprom) a Pi 4 or Pi 5 reads tryboot.txt
# instead of config.txt; over the network a missing file made the Pi 5 ask for it
# again and again and never boot (2026-11-25).
cp "$GENERIC/config.txt" "$GENERIC/tryboot.txt"

# ── optional per-device override dir ──────────────────────────────────────────
# Not needed for normal use: the flat tree written by assemble_tftp serves every Pi
# of a supported model. A {serial}/ dir takes precedence over the root for that one
# device, e.g. to give it a different config.txt or U-Boot.
if [ -n "${SERIAL:-}" ]; then
  mkdir -p "$TFTP/${SERIAL}/overlays"

  for f in "$GENERIC"/*.bin "$GENERIC"/*.elf "$GENERIC"/*.dat "$GENERIC"/*.txt "$GENERIC"/*.dtb; do
    [ -f "$f" ] || continue
    cp "$f" "$TFTP/${SERIAL}/$(basename "$f")"
  done

  for f in "$GENERIC/overlays"/*.dtbo; do
    [ -f "$f" ] || continue
    cp "$f" "$TFTP/${SERIAL}/overlays/$(basename "$f")"
  done

  echo "[rpi-uboot-build] Per-device override tftp/${SERIAL}/ populated."
fi
} # end build_model

# ── flat TFTP tree ────────────────────────────────────────────────────────────
# One directory that serves every model without per-device setup. Files that differ
# per model have model-specific names (start.elf / start4.elf, bcm2710-* / bcm2711-*,
# u-boot-<model>.bin); the shared config.txt picks the right U-Boot per board.
#
# Only what the Pi bootloader and start*.elf insist on finding in the root stays
# there: bootcode.bin, start*.elf, fixup*.dat and config.txt. Everything loaded
# after config.txt is read (U-Boot, device trees, overlays) goes to rpi/, which
# config.txt selects with os_prefix. Build details go to build-info/rpi-uboot/;
# no client reads them.
assemble_tftp() {
  local os=$TFTP/rpi info=$TFTP/build-info/rpi-uboot
  mkdir -p "$os/overlays" "$info"
  local model generic f
  for model in rpi3 rpi4 rpi5; do
    generic=/out/generic-$model
    # only completed builds (see the skip check in build_model)
    [ -f "$generic/u-boot.bin" ] && [ -f "$generic/$model.txt" ] || continue
    cp "$generic/u-boot.bin" "$os/u-boot-$model.bin"
    cp "$generic/$model.txt" "$info/$model.txt"
    for f in "$generic"/*.elf "$generic"/*.dat; do
      [ -f "$f" ] || continue
      cp "$f" "$TFTP/$(basename "$f")"
    done
    for f in "$generic"/*.dtb; do
      [ -f "$f" ] || continue
      cp "$f" "$os/$(basename "$f")"
    done
    for f in "$generic/overlays"/*.dtbo; do
      [ -f "$f" ] || continue
      cp "$f" "$os/overlays/$(basename "$f")"
    done
    # upstream Linux trees of every family (rpi/upstream/broadcom/<board>.dtb):
    # loaded by boot scripts through the FdtFile variable, and on the Pi 5 by
    # U-Boot itself (UBOOT_RPI5_EFI_FDT); never by the Pi firmware
    if [ -d "$generic/upstream" ]; then
      mkdir -p "$os/upstream"
      cp -r "$generic/upstream/." "$os/upstream/"
    fi
  done
  # The firmware applies os_prefix to overlays only when <os_prefix>overlays/README
  # exists; without it, it looks in the root overlays/ and silently skips an
  # overlay it does not find there (seen on a Pi 3 with dtoverlay=miniuart-bt).
  echo "Marker file: the Raspberry Pi firmware loads overlays from <os_prefix>overlays/ only if this README exists." \
    > "$os/overlays/README"
  # Pi 3 ROM requirement: bootcode.bin at the TFTP root
  if [ -f /out/bootcode.bin ]; then cp /out/bootcode.bin "$TFTP/bootcode.bin"; fi

  # The firmware reads config.txt top to bottom and applies a [piN] section only on
  # that board family; [all] applies to every board again. os_prefix makes it load
  # the kernel (U-Boot), device tree and overlays from rpi/.
  # enable_uart=1 on a Pi 5 needs patches/0005 (see patches/README.md).
  # framebuffer_swap=0 on the Pi 3 and Pi 4: without it the firmware's framebuffer has red
  # and blue the other way round from what U-Boot draws, so U-Boot and iPXE show
  # swapped colours on HDMI (a red menu instead of a blue one).
  cat > "$TFTP/config.txt" <<'EOF'
[pi3]
kernel=u-boot-rpi3.bin
uart_2ndstage=1
dtoverlay=miniuart-bt
framebuffer_swap=0
[pi4]
kernel=u-boot-rpi4.bin
uart_2ndstage=1
framebuffer_swap=0
[pi5]
kernel=u-boot-rpi5.bin
dtoverlay=vc4-kms-v3d-pi5
[all]
os_prefix=rpi/
arm_64bit=1
enable_uart=1
disable_overscan=1
EOF
  # The same as tryboot.txt (see "write config.txt" above)
  cp "$TFTP/config.txt" "$TFTP/tryboot.txt"
  # This file repeats the per-model config.txt of each build (written by
  # build_model, used for a <serial>/ directory). Every line of those, except
  # kernel= (named per model here), must be in this file's [<model>] or [all]
  # section, or a board behaves differently from its tested serial build.
  local line section
  for model in rpi3 rpi4 rpi5; do
    generic=/out/generic-$model
    [ -f "$generic/config.txt" ] || continue
    section="pi${model#rpi}"
    while IFS= read -r line; do
      case "$line" in ''|'#'*|kernel=*) continue ;; esac
      if ! awk -v s="[$section]" -v l="$line" '
          /^\[/ { cur = $0 }
          (cur == s || cur == "[all]") && $0 == l { found = 1 }
          END { exit !found }' "$TFTP/config.txt"; then
        echo "[rpi-uboot-build] ERROR: '$line' of the $model config.txt is missing from the shared config.txt ([$section] or [all])" >&2
        exit 1
      fi
    done < "$generic/config.txt"
  done
}

# ── run ───────────────────────────────────────────────────────────────────────
MODELS="${MODEL:-rpi3 rpi4 rpi5}"

# A serial dir holds exactly one model's u-boot.bin/config.txt. Populating it while
# looping over several models would leave it with the last model's files.
if [ -n "${SERIAL:-}" ]; then
  set -- $MODELS
  if [ "$#" -ne 1 ]; then
    echo "[rpi-uboot-build] ERROR: SERIAL=${SERIAL} requires exactly one MODEL (got '${MODELS}'). Set MODEL to that Pi's model: rpi3, rpi4 or rpi5." >&2
    exit 1
  fi
fi

for MODEL in $MODELS; do
  echo ""
  echo "[rpi-uboot-build] ── building ${MODEL} ──"
  build_model "$MODEL"
done

assemble_tftp

chown -R "${PUID:-500}:${PGID:-500}" /out

echo ""
echo "[rpi-uboot-build] done"
ls -lh /out/
