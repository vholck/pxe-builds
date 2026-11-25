# rpi-uboot-build

Builds [U-Boot](https://github.com/u-boot/u-boot) for Raspberry Pi 3, 4 and 5 and downloads the Raspberry Pi firmware files needed to network boot them. U-Boot brings up ethernet (including the Pi 3's USB-attached LAN9514), fetches the ARM64 iPXE binary over TFTP and starts it.

The pxe stack normally gets these files from the `rpi-uboot` image that CI builds from this directory ([build-rpi-uboot.yml](../.github/workflows/build-rpi-uboot.yml)). Run this stack yourself only for a local or debug build, or to create a per-device override.

## Boot chain

```
Pi ROM → TFTP: bootcode.bin (Pi 3 only)
       → TFTP: start.elf + fixup.dat (Pi 3) / start4.elf + fixup4.dat (Pi 4)
       → TFTP: config.txt  ([pi3]/[pi4]/[pi5] section selects kernel=u-boot-<model>.bin, os_prefix=rpi/)
       → TFTP: rpi/<device tree>.dtb, rpi/u-boot-<model>.bin
       → U-Boot DHCP (PXEClient vendor class) → dnsmasq ProxyDHCP reply → serverip set
       → U-Boot bootcmd → TFTP: ipxe/snponly-arm64-rpi.efi  (path baked in at build time —
                          dnsmasq runs as ProxyDHCP only and cannot deliver the filename
                          to U-Boot, so it cannot be supplied via DHCP)
       → iPXE → ipxe/boot.ipxe
```

The Pi bootloader looks in a `<serial>/` directory first and falls back to the TFTP root. Pi 5 has no `bootcode.bin` or `start*.elf`; its EEPROM loads `config.txt` and the kernel directly.

## Output layout

```
out/
├── tftp/                      ← copy the contents of this directory to the TFTP root
│   ├── bootcode.bin           ← Pi 3 ROM requirement
│   ├── config.txt             ← shared by all models, see below
│   ├── start.elf, fixup.dat           (Pi 3)
│   ├── start4.elf, fixup4.dat         (Pi 4)
│   ├── rpi/                   ← loaded through os_prefix=rpi/ in config.txt
│   │   ├── u-boot-rpi3.bin, u-boot-rpi4.bin, u-boot-rpi5.bin
│   │   ├── bcm2710-*.dtb, bcm2711-*.dtb, bcm2712-*.dtb
│   │   └── overlays/miniuart-bt.dtbo, README   ← the firmware uses rpi/overlays/ only if README exists
│   ├── build-info/rpi-uboot/  ← rpi3.txt, rpi4.txt, rpi5.txt: build info per model
│   └── {serial}/              ← optional per-device override (only when SERIAL is set)
├── generic-rpi3/              ← per-model build cache, not served
├── generic-rpi4/
└── generic-rpi5/
```

### One tree for all models

Only the files the Pi bootloader and `start*.elf` insist on finding in the TFTP root stay there: `bootcode.bin`, `start*.elf`, `fixup*.dat` and `config.txt`. Everything loaded after `config.txt` has been read (U-Boot, the device tree, overlays) is in `rpi/`, selected with `os_prefix=rpi/`. A per-device `{serial}/` directory is self-contained and does not use `rpi/`.

Files that differ per model have model-specific names, so they can share one directory. The two that would collide, the U-Boot binary and `config.txt`, are handled like this:

- U-Boot is written as `rpi/u-boot-<model>.bin`.
- `config.txt` uses section filters. The firmware reads it top to bottom and applies a `[pi4]` section only on Pi 4 hardware (4B, 400, CM4), a `[pi3]` section only on Pi 3 hardware, and so on. `[all]` applies to every board again.

```
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
[all]
os_prefix=rpi/
arm_64bit=1
enable_uart=1
disable_overscan=1
```

`enable_uart=1` applies to every model. On a Pi 5 it needs `patches/0005`: without that patch U-Boot stops at its prompt and never boots (see `patches/README.md`). With `enable_uart=1` the Pi 5 also gets a U-Boot console on GPIO 14 and 15 (`patches/rpi5/0017`), like the Pi 3 and Pi 4. That console starts later than theirs, so U-Boot's first lines are printed there as a marked replay (`patches/rpi5/0019`); the banner itself goes to the debug connector only.

`framebuffer_swap=0` on the Pi 3 and Pi 4 puts red and blue in the order U-Boot draws them. Without it U-Boot and iPXE show swapped colours on HDMI (a red netboot.xyz menu instead of a blue one). The Pi 5 does not need it.

Any Pi of a supported model boots from this tree without registering its serial or MAC anywhere. What each Pi boots after that is decided in iPXE; see "Per-device boot targets" in the pxe README.

### Per-device override

A `<serial>/` directory in the TFTP root takes precedence over the flat files for that one Pi. Use it when a single Pi needs different firmware settings or a different boot firmware (for example the UEFI firmware from [rpi-uefi-build](../rpi-uefi-build/)). Set `SERIAL` (with a single `MODEL`) to create `tftp/<serial>/`, or run `add-serial.sh` afterwards.

The serial is the last 8 hex digits of `grep Serial /proc/cpuinfo`, or read it from the dnsmasq log when the Pi requests `<serial>/start4.elf`.

## U-Boot DHCP and serverip

U-Boot is built with these non-default options:

| Option | Purpose |
|--------|---------|
| `bootp_vci=PXEClient` (env) | Sends `PXEClient` as vendor class so dnsmasq proxy mode replies |
| `CONFIG_DHCP_PXE_CLIENTARCH=0xb` | Client architecture 11 (ARM64 EFI), which dnsmasq matches with `dhcp-match=set:arm64efi,option:client-arch,11` |
| `CONFIG_SERVERIP_FROM_PROXYDHCP` | Reads `serverip` from `siaddr` in the ProxyDHCP reply (U-Boot ignores option 66). When no ProxyDHCP server answers, the DHCP server's own `siaddr` is used ([patches/0004](patches/)) |
| `CONFIG_BOOTP_SEND_HOSTNAME` | Sends board hostname in DHCP requests for model identification in logs |
| `netboot` (env) | Runs dhcp to get serverip, then TFTP-fetches the EFI binary by a hardcoded filename and boots it with bootefi. On the Pi 5 with `UBOOT_RPI5_EFI_FDT=upstream` it first fetches `rpi/upstream/${fdtfile}` (`efifdt`) and hands that device tree to bootefi; without one for the board, the firmware's |
| `localboot` (env) | Upstream's standard boot (`bootflow scan`, upstream's own `bootcmd`) of the local devices in upstream's `boot_targets`: `mmc` and `usb`, on the Pi 5 also `nvme`, or the list in `UBOOT_LOCAL_BOOT_ORDER`. The network targets `pxe` and `dhcp` are taken out of `boot_targets` for the scan and put back afterwards |
| `fdtvar` (env), `CONFIG_CMD_NVEDIT_EFI` | Publishes the UEFI variable `FdtFile` (vendor GUID `eedf58fc-1b9b-4ab0-8b6b-954d79d6b052`, boot services only): the path of the board's upstream Linux device tree in the layout distributions use, U-Boot's own `${fdtfile}` (e.g. `broadcom/bcm2711-rpi-4-b.dtb`). A loader reads it to load the tree an OS needs; iPXE: `fdt <OS tree folder>/${efi/FdtFile:string}`. U-Boot still hands over the firmware's tree. Run first by `bootcmd`, so it is there for network and local boots |
| `bootcmd` (env) | Runs `fdtvar`, then `netboot`. If a step fails (server down, link not up yet) or iPXE returns (netboot.xyz's "Boot from local hdd" is iPXE returning), it runs `localboot`, so an SD card, USB drive or NVMe drive with an OS boots. If nothing boots, it waits 10 seconds and resets, so a headless Pi keeps retrying instead of stopping at the U-Boot prompt. Ctrl-C during the wait gives the prompt |
| Pi 5 patches | Upstream U-Boot has no Ethernet on the Pi 5. [patches/rpi5/](patches/rpi5/) adds it; see [patches/README.md](patches/README.md) |
| Version string | The banner reads `U-Boot <version>-pxe-<commit>` for CI builds and `<version>-pxe` for local ones (`UBOOT_VERSION_SUFFIX`), instead of `-dirty` |
| USB (`CMD_USB`, `USB_XHCI_*`, `USB_KEYBOARD`) | A USB keyboard works in iPXE. USB is started by the preboot command of each defconfig (`usb start`), not by the boot commands |
| GENET patch | [patches/0001-bcmgenet-clear-ID_MODE_DIS-for-rgmii-rxid.patch](patches/); background in [GENET-TX-FIX.md](GENET-TX-FIX.md) |

## Configuration

Build settings are in [build.env](../build.env) at the repository root, the file CI builds with; a local build reads it with `--env-file ../build.env`. `MODEL`, `SERIAL`, `FORCE_UBOOT_REBUILD`, `UBOOT_DEBUG_ARTIFACTS` and `OUT_DIR` are for local builds only: give them on the command line.

| Variable | Description | Default |
|----------|-------------|---------|
| `MODEL` | Target Pi model(s): `rpi3`, `rpi4`, `rpi5`, or a space-separated list. Must be a single model when `SERIAL` is set | all three |
| `SERIAL` | Optional. Creates the per-device override `tftp/<serial>/` | *(empty)* |
| `FIRMWARE_VERSION` | raspberrypi/firmware commit the boot files come from. Also used by CI | pinned |
| `UBOOT_PRE_DHCP_SLEEP` | Seconds U-Boot waits before DHCP, for all models. Empty keeps the per-model default in `build.sh`. U-Boot waits for the link and retries DHCP by itself, so a wait is not needed for a working network | `0` on every model |
| `UBOOT_LOCAL_BOOT_ORDER` | Local devices `localboot` tries, in this order: any of `mmc` (SD card), `usb` and `nvme` (Pi 5 only; left out on the Pi 3 and Pi 4), space-separated, e.g. `usb mmc`. Empty keeps upstream's order (`mmc usb`, on the Pi 5 `mmc nvme usb`). Also used by CI | *(empty)* |
| `UBOOT_RPI5_EFI_FDT` | Device tree the Pi 5's U-Boot hands to iPXE and from there to the kernel it starts: `firmware` (default since 2026-11-23) = the firmware's tree, as on every other Pi (rule R3); an OS that needs the upstream tree loads it itself by the `FdtFile` variable (`fcos.ipxe`, the Matchbox CoreOS example); the Pi 5's `config.txt` sets `dtoverlay=vc4-kms-v3d-pi5`, without which Raspberry Pi's kernel has no display (its serial console is the debug connector, `serial10`, either way). `upstream` = the upstream Linux tree served as `rpi/upstream/<fdtfile>` (built from devicetree-rebasing at `RPI_DT_TAG` in the `build.env`, with the RP1's GPIO UART added, see [dts/README.md](../dts/README.md)), which distribution kernels need for Ethernet and USB behind RP1; with `enable_uart=1` Linux's console is the GPIO UART when no display is connected (patch `rpi5/0021`); a board without one (CM5, Pi 500) gets the firmware's tree. Use it for OS boots that cannot load a tree themselves (netboot.xyz entries). Local boot (`localboot`) is not affected. Also used by CI | `firmware` |
| `CONSOLE_MAIN` | Main console of the operating system, set in the `build.env` for every Pi and both firmwares: `auto` = the display when one is connected, else serial; `serial` = serial also with a display (the display gets output too). U-Boot gets it as the environment variable `console_main` (patch `0007`); for one boot it can be changed at the U-Boot prompt | `auto` |
| `EFI_ARM64_RPI_FILE` | EFI binary path (relative to the TFTP root) baked into U-Boot bootcmd — must match the path the `pxe` stack serves. Also used by CI | `ipxe/snponly-arm64-rpi.efi` |
| `FORCE_UBOOT_REBUILD` | `1` rebuilds and re-downloads everything for the selected models | `0` |
| `UBOOT_DEBUG_ARTIFACTS` | `1` copies the U-Boot ELF, map and `.config` to `out/debug/` | `0` |
| `OUT_DIR` | Host path to write output files into | `./out` |

## Usage

```bash
cd rpi-uboot-build

# Build all models; output in $OUT_DIR/tftp
docker compose --env-file ../build.env run --rm rpi-uboot-build

# One model only
MODEL=rpi4 docker compose --env-file ../build.env run --rm rpi-uboot-build

# Per-device override for one Pi (no rebuild if the model is already built)
MODEL=rpi4 SERIAL=12345678 docker compose --env-file ../build.env run --rm rpi-uboot-build
bash add-serial.sh rpi4 9abcdef0 "$OUT_DIR"      # more Pis of the same model

# Force a full rebuild
MODEL=rpi4 FORCE_UBOOT_REBUILD=1 docker compose --env-file ../build.env run --rm rpi-uboot-build
```

A build is only treated as complete once `u-boot.bin` and the `<model>.txt` build-info file both exist in `generic-<model>/`, so a run that failed halfway is redone on the next start.
