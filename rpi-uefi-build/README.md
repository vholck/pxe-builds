# rpi-uefi-build

Builds the Raspberry Pi UEFI firmware ([EDK2](https://github.com/tianocore/edk2)) for Pi 3, Pi 4 and Pi 5, and downloads the Raspberry Pi boot files that go with it. Pi 3 and Pi 4 come from the [pftf](https://github.com/pftf/RPi4) project. The Pi 5 platform is not in upstream EDK2; it comes from the [rpi5-uefi](https://github.com/NumberOneGit/rpi5-uefi) port (the maintained fork of the archived worproject/rpi5-uefi), to which this build adds network boot.

UEFI is the optional boot firmware in this repo. U-Boot ([rpi-uboot-build](../rpi-uboot-build/)) is the default and needs no per-device setup. Choose UEFI for a Pi that needs ACPI (for example Windows on ARM or ESXi-Arm), the firmware setup menu, or the UEFI Shell.

## Using the stage image

CI builds all three models from this directory ([build-rpi-uefi.yml](../.github/workflows/build-rpi-uefi.yml)) and publishes them as the stage image `ghcr.io/vholck/pxe-builds/rpi-uefi`. It holds one generic boot tree per model and a start script, `stage.sh`. Run it with the TFTP root of your TFTP server mounted at `/out`, next to the [rpi-uboot](../rpi-uboot-build/) stage image, and list the serials of the Pis that should boot UEFI in these variables (space-separated):

```
RPI5_UEFI_SERIALS=9abcdef0
RPI4_UEFI_SERIALS=a1b2c3d4 1234abcd
RPI3_UEFI_SERIALS=
```

```bash
docker run --rm -v /srv/tftp:/out -e RPI4_UEFI_SERIALS="a1b2c3d4 1234abcd" ghcr.io/vholck/pxe-builds/rpi-uefi:latest
```

At every start each listed Pi gets a `<serial>/` directory in the TFTP root with its model's tree, which its bootloader prefers over the flat U-Boot files. All other Pis keep booting U-Boot. Remove a serial from the list and start the image again to switch that Pi back to U-Boot: the script removes the directories it created for Pis that are no longer listed.

The script marks each directory it creates with a file `.rpi-uefi-stage` and never changes or removes a directory without that file, such as a hand-made override; a listed serial whose directory exists without it is skipped with a warning. So is a serial that is not 8 hex digits. It gives the directories it writes to the owner `PUID`:`PGID` (default `500`:`500`). It does not touch anything else in the TFTP root.

The serial is the last 8 hex digits of `Serial` in `/proc/cpuinfo`. It is also the directory name the Pi requests in the TFTP server's log (`a1b2c3d4/start4.elf`, on a Pi 5 `9abcdef0/config.txt`).

## Boot chain

```
Pi ROM → TFTP: bootcode.bin (Pi 3 only)
       → TFTP: <serial>/start*.elf, fixup*.dat, config.txt  (armstub=RPI_EFI.fd)
       → TFTP: <serial>/RPI_EFI.fd
       → UEFI: network boot → DHCP / ProxyDHCP (e.g. dnsmasq) → ipxe/snponly-arm64-rpi.efi or ipxe/snponly-arm64.efi (iPXE)
       → iPXE → ipxe/boot.ipxe
```

The iPXE binaries and `ipxe/boot.ipxe` come from [ipxe-build](../ipxe-build/).

A Pi 5 has no `start*.elf`: its bootloader reads `<serial>/config.txt` and loads `<serial>/RPI_EFI.fd` and the device tree itself.

## What is built

- **Pinned sources.** `PFTF_REF` pins the pftf/RPi4 commit and, through its submodules, EDK2 itself. The same sources build the Pi 3 firmware. `RPI5_UEFI_REF` pins the Pi 5 port the same way (its own EDK2 submodules). The Pi 5's Trusted Firmware-A is pinned on its own, `RPI5_TFA_TAG` and `RPI5_TFA_COMMIT` (an upstream tag that has the CVE-2025-10263 workaround the port's submodule lacks; empty `RPI5_TFA_TAG` uses the submodule). The Raspberry Pi boot files are pinned with `START_ELF_VERSION`, `DTB_VERSION` and `DTBO_VERSION`.
- **Generic firmware.** Nothing device-specific is compiled in; one `RPI_EFI.fd` per model serves every Pi of that model.
- **`config.txt` from upstream.** On the Pi 4 and Pi 5 it is the port's own `config.txt` of the pinned source, read at build time. Only `device_tree_address` and `device_tree_end` are replaced, by the values EDK2 is built with (`PcdFdtBaseAddress`, `PcdFdtSize`): where it looks for the device tree and how much of it it maps. `hdmi_force_hotplug` is never set, and the Pi 5 gets `enable_uart=1`. The pinned source has no Pi 3 file, so `build.sh` writes that one. Every line and its reason: [UPSTREAM.md](../UPSTREAM.md).
- **No Secure Boot.** The iPXE binaries of [ipxe-build](../ipxe-build/) are unsigned.
- **Baked-in setting defaults.** Settings changed in the firmware menu may not survive a reboot when the firmware is loaded over TFTP, so the defaults are set at build time (see Configuration).
- **OS console (`CONSOLE_MAIN`, `build.env`, [rule R2](../README.md#design-rules)).** The firmware describes the serial console to the OS (`stdout-path` in the device tree, the SPCR table under ACPI). EDK2's ConsolePrefDxe removes both at boot when a display is connected and its preference is "graphical". `CONSOLE_MAIN=auto` keeps that upstream default: the display is the OS's main console when one is connected, serial otherwise. `CONSOLE_MAIN=serial` makes "serial" the default: serial is always the main console and a connected display gets the output too. The Pi 3 platform does not include ConsolePrefDxe, so on a Pi 3 the serial console is always kept, whatever the setting. The Pi 3 and Pi 4 have no `hdmi_force_hotplug` (until 2026-11-22 they did): with it the firmware created a display even when none was connected, so the serial console was always removed. Without it a connected display still works; an HDMI capture device counts as one only while it is capturing (Pi 4, 2026-11-22).
- **Network options:** TFTP shell command, iSCSI, HTTP boot without TLS (iPXE does HTTPS).
- **Pi 3 onboard Ethernet.** The EDK2 Pi 3 platform has no driver for the onboard USB Ethernet chip (LAN9514 on the 3B, LAN7515 on the 3B+); its own README lists network boot from the onboard NIC as missing. This build adds one: iPXE compiled as a UEFI driver (pinned with `UEFI_IPXE_REF`) and embedded in the Pi 3 firmware image. It also adds the boot manager policy driver the Pi 3 platform lacks, without which the firmware never creates a network boot entry. Downloads through this driver are slower than under U-Boot: about 1 MB/s against 9 MB/s on a Pi 3B (the firmware's USB path polls, and a patch to iPXE already makes it three times faster than it was). See [patches/README.md](patches/README.md).

- **Pi 5 onboard Ethernet.** The Pi 5 port has no driver for the Ethernet controller in the RP1 chip, so by itself it cannot network boot. This build adds one, in the same way as for the Pi 3: iPXE compiled as a UEFI driver and embedded in the firmware image, with a driver for the RP1 Ethernet that a patch adds to iPXE. A second patch makes the firmware write the board's MAC address into the controller. See [patches/README.md](patches/README.md). The Pi 5 `config.txt` is the port's own (`usb_max_current_enable=1`, `force_turbo=1`, 32-bit framebuffer) plus `enable_uart=1`.
- **Pi 5 console on the GPIO header.** The Pi 5 port has its console only on the 3-pin debug connector. This build adds a driver for the UART on GPIO 14 and 15, so a Pi 5 is used with the same serial cable as a Pi 3 or Pi 4 (see "Diagnostics on the serial console" below).

### Diagnostics on the serial console

The serial console (115200 8N1) is always active. On a Pi 3 and Pi 4 it is on GPIO 14 and 15 of the header.

A Pi 5 has two serial ports:

- **GPIO 14 and 15**, the same pins and cable as on the earlier models: the firmware's console (boot prompt, setup menu, UEFI Shell, iPXE and its menu), output and input. It starts with the boot prompt, when the firmware has found the RP1 chip behind PCIe. The diagnostics selected by `UEFI_BUILD_TYPE` appear there too: what was printed before the port existed is replayed between the lines `--- UEFI firmware <version>: earlier output, replayed ---` and `--- end of replay, live from here ---`, later messages are printed as they happen. The firmware uses these pins because `config.txt` contains `enable_uart=1`; without that line it leaves them alone, for a HAT. See [patches/README.md](patches/README.md).
- **The 3-pin debug connector** between the HDMI sockets: the same console and the same diagnostics, live from the first line on.

`UEFI_BUILD_TYPE` selects how much the firmware prints:

| Value | Output | Notes |
|---|---|---|
| `warn` (default) | Errors and warnings from firmware drivers | Asserts do not halt the boot. Measured on a Pi 4: firmware start to PXE in 17.2 s, against 17.1 s for `release` |
| `release` | Banner and boot progress only | |
| `debug` | Everything | Slow, and a failed assert halts the boot. For diagnosing a firmware problem |

## Configuration

Build settings are in [build.env](../build.env) at the repository root, the file CI builds with; a local build reads it with `--env-file ../build.env`. `MODEL`, `SERIAL`, `FORCE_UEFI_REBUILD` and `OUT_DIR` are for local builds only: give them on the command line.

| Variable | Description | Default |
|---|---|---|
| `PFTF_REF` | pftf/RPi4 commit to build (Pi 3 and Pi 4). Bump deliberately and boot-test; check the EDK2 rows of [UPSTREAM-TRACKING.md](../UPSTREAM-TRACKING.md) for patches the new version makes unnecessary | pinned |
| `RPI5_UEFI_REF` | NumberOneGit/rpi5-uefi commit to build (Pi 5). Bump deliberately and boot-test; check the EDK2 and iPXE rows of [UPSTREAM-TRACKING.md](../UPSTREAM-TRACKING.md) (the fork's own Ethernet driver may replace ours) | pinned |
| `UEFI_IPXE_REF` | iPXE commit built as the Pi 3 and Pi 5 onboard Ethernet drivers | pinned |
| `START_ELF_VERSION`, `DTB_VERSION`, `DTBO_VERSION` | raspberrypi/firmware commits for `start*.elf`/`fixup*.dat`, device trees and overlays | pinned |
| `UEFI_BUILD_TYPE` | `warn`, `release` or `debug` (see above) | `warn` |
| `UEFI_BOOT_TIMEOUT` | Seconds the "ESC (setup), F1 (shell), ENTER (boot)" prompt is shown | `2` |
| `UEFI_SYSTEM_TABLE` | Every Pi: hardware description handed to the OS: `acpi`, `both`, `devicetree`, or `upstream` to keep each model's default (Pi 3 `both`, Pi 4 and Pi 5 `acpi`). With `both` arm64 Linux uses the Pi firmware's device tree; Raspberry Pi kernels need it and panic with ACPI only. Replaced `UEFI_RPI5_SYSTEM_TABLE` (same values and default) in 2026-11 | `both` |
| `UEFI_RPI5_DT` | Pi 5 B device tree the Pi firmware loads and EDK2 hands to the OS: `firmware` (default since 2026-11-23) = Raspberry Pi's trees, as on every other Pi ([rule R3](../README.md#design-rules)); an OS that needs the upstream tree loads it itself by the `FdtFile` variable. `upstream` = the upstream Linux tree with the RP1's GPIO UART ([dts/README.md](../dts/README.md)), as `bcm2712-rpi-5-b.dtb`, `bcm2712-d-rpi-5-b.dtb` and `bcm2712d0-rpi-5-b.dtb`, for OS boots that cannot load a tree themselves. CM5 and Pi 500 always get Raspberry Pi's. With `enable_uart=1` and no display, Linux's console is the GPIO UART; with a display, the display (EDK2 removes `stdout-path`) | `firmware` |
| `UEFI_HDMI_MODE` | HDMI mode as `<group>:<mode>` (`hdmi_group`/`hdmi_mode`), e.g. `1:4` for 720p60 or `1:16` for 1080p60. Empty lets the Pi choose, which is 640x480 when it cannot detect the display | *(empty)* |
| `UEFI_RAM_LIMIT_3GB` | Pi 4 only: `1` limits RAM to 3 GB (the upstream default), `0` uses all RAM | `0` |
| `UEFI_IPV6` | `0` builds the firmware without its IPv6 network stack, so the boot options PXE over IPv6 and HTTP boot over IPv6 do not exist and nothing waits for them (about 2 minutes without an IPv6 router, for example after iPXE hands back). `1` keeps them, as upstream | `0` |
| `MODEL` | Local builds: `rpi3`, `rpi4`, `rpi5`, or all when empty | all |
| `SERIAL` | Local builds: also create `tftp/<serial>/` for one Pi; needs a single `MODEL` | *(empty)* |
| `FORCE_UEFI_REBUILD` | `1` rebuilds even when output for these settings exists | `0` |
| `OUT_DIR` | Host path for output | `./out` |

A build is skipped when the output already matches the sources, settings, patches and build script (a fingerprint stored in `generic-<model>/<model>-uefi.txt`); changing any of them rebuilds.

## Local builds

```bash
cd rpi-uefi-build

docker compose --env-file ../build.env run --rm rpi-uefi-build                                # all models
MODEL=rpi4 SERIAL=a1b2c3d4 docker compose --env-file ../build.env run --rm rpi-uefi-build     # plus tftp/a1b2c3d4/
MODEL=rpi4 UEFI_BUILD_TYPE=debug FORCE_UEFI_REBUILD=1 docker compose --env-file ../build.env run --rm rpi-uefi-build
```

Output in `OUT_DIR`:

```
generic-rpi3/     complete boot tree for a Pi 3  (RPI_EFI.fd, start.elf, fixup.dat, *.dtb, overlays/, config.txt)
generic-rpi4/     complete boot tree for a Pi 4
generic-rpi5/     complete boot tree for a Pi 5  (RPI_EFI.fd, *.dtb, overlays/, config.txt)
tftp/<serial>/    only with SERIAL: copy this directory into the TFTP root
```

The image is large (EDK2 sources and toolchain) and the first build of it takes a while; a firmware build then takes a few minutes per model.

## Source patches

See [patches/README.md](patches/README.md).

- Pi 4: a fallback that reads the MAC address from the network controller when the board reports an all-zero MAC. It replaces the earlier per-device build that compiled a MAC address into the firmware.
- Pi 3: adds the onboard Ethernet driver and the boot manager policy driver to the firmware image (see "What is built").
- Pi 5: adds the onboard Ethernet driver to the firmware image and makes the firmware program the board's MAC address into the Ethernet controller. The driver itself is a patch to iPXE.

## Not verified

- Pi 3B+ (LAN7515). The driver includes it, but only a Pi 3B (LAN9514) has been booted.
- Pi 5 boards other than the 8 GB Pi 5 with the C1 chip (revision `d04170`): D0 boards, the 2 GB and 16 GB models, CM5, Pi 500. The firmware port lists them as supported and the device trees are shipped, but none has been booted with this build.
- Pi 5: a USB keyboard in the firmware menu, booting from SD card, USB or NVMe, and an operating system installed through ACPI.
- Whether settings changed in the firmware menu persist across reboots when booting over TFTP.
