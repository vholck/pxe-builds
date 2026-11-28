# Shared device tree sources

Used by both Raspberry Pi firmware builds, `rpi-uboot-build` and `rpi-uefi-build`, so a Pi 5 gets the same device tree under U-Boot and under UEFI. Both Dockerfiles copy this directory to `/dts` from the named build context `dts` (`docker build --build-context dts=dts ...` in CI, `additional_contexts` in the compose files). A change here rebuilds both images.

## Source: devicetree-rebasing

The trees are built from [devicetree-rebasing](https://git.kernel.org/pub/scm/linux/kernel/git/devicetree/devicetree-rebasing.git), the device tree files of the Linux tree with one tag per Linux release (the same layout as U-Boot's `dts/upstream`, which is a copy of it). The release is pinned in [build.env](../build.env) by `RPI_DT_TAG` (since 2026-11-25 `v7.3-dts`; before, U-Boot v2026.10's copy = `v7.1-dts`) and `RPI_DT_COMMIT`, the commit the tag must point to. `fetch-rpi-dts.sh <tag> <commit> <dir>` fetches only `include/`, `src/arm64/broadcom/` and `src/arm/broadcom/` and fails on a commit mismatch; both Dockerfiles run it (`/rpi-dts`), so U-Boot and UEFI serve the same trees, and the pin is independent of the U-Boot version.

**Bumping `RPI_DT_TAG`:** set the tag and its commit in `build.env` (`git ls-remote <url> 'refs/tags/<tag>^{}'`), build both firmware images, and boot a Pi 5 under both firmwares with an OS that uses the upstream tree (Fedora CoreOS): Ethernet, USB, HDMI (and how long the display waits), temperature, the console on the GPIO pins. For v7.4 also a D0 board (its root compatible loses `brcm,bcm2712`) and Pi 3/4 (DMA ranges).

## What is built

`build-rpi-upstream.sh <src> <out> <dtc> <gcc> <family>` builds the upstream Linux device trees of one Pi family from devicetree-rebasing at `RPI_DT_TAG` (see above), with symbols (`dtc -@`), as `broadcom/<board>.dtb`:

| Family | Boards | Added |
| --- | --- | --- |
| `rpi3` | `bcm2837-rpi-3-b`, `bcm2837-rpi-3-b-plus`, `bcm2837-rpi-3-a-plus`, `bcm2837-rpi-zero-2-w` | nothing: the console UART is in upstream's tree |
| `rpi4` | `bcm2711-rpi-4-b`, `bcm2711-rpi-400` | nothing: the console UART is in upstream's tree |
| `rpi5` | `bcm2712-rpi-5-b`, `bcm2712-d-rpi-5-b` | `rp1-uart0.dtsi`, `rpi5-wifi-mac.dtsi` |

rpi-uboot-build builds every family and serves them as `rpi/upstream/broadcom/<board>.dtb`; boot scripts load the one an OS needs through the firmware's `FdtFile` variable (`fdt tftp://${next-server}/rpi/upstream/${efi/FdtFile:string}`, [rule R3](../README.md#design-rules)). rpi-uefi-build builds the Pi 5 trees as its board trees (`UEFI_RPI5_DT=upstream`). The Compute Modules are left out: U-Boot's `fdtfile` names (`bcm2837-rpi-cm3.dtb`, `bcm2711-rpi-cm4.dtb`) are not upstream's (`-cm3-io3`, `-cm4-io`), so a CM keeps the firmware's tree.

Upstream trees are needed because Raspberry Pi's own trees describe the RP1 chip the way Raspberry Pi's kernel expects; a distribution kernel (Fedora CoreOS, Debian) finds no Ethernet or USB with them.

## `rp1-uart0.dtsi`: the GPIO console

The upstream trees have no node for the RP1's UART0, the UART on GPIO 14 and 15 that the Pi 3 and Pi 4 use as their console. Without it Linux has no console on those pins under either firmware, and UEFI cannot find its own GPIO console either. The file adds:

- `uart0: serial@40030000` under the RP1, `arm,sbsa-uart`, enabled (since 2026-11-23; upstream's Pi 3 and Pi 4 trees ship their console UART enabled too, and a tree a loader installs with `fdt` gets no firmware fixups under UEFI). A PL011 node (`arm,pl011` with `arm,primecell`) does not work: the AMBA bus claims the registers when it creates the device, the RP1 driver already holds them, and the probe fails with `EBUSY`. The SBSA driver needs no clock and keeps the 115200 baud the firmware set.
- aliases `serial0` and `uart0` pointing to it.
- `stdout-path = "serial0:115200n8"`, so Linux puts its console there without `console=`.
- `__overrides__` `uart0` and `uart0_console`, copied from Raspberry Pi's `bcm2712-rpi.dtsi`: the Pi firmware applies `enable_uart=1` through them.

Who enables the node and decides the console:

| Who loads the tree | `enable_uart=1` (in every config.txt both firmware builds write) | Display present |
| --- | --- | --- |
| UEFI: the Pi firmware, as the board tree (only with `UEFI_RPI5_DT=upstream`) | the firmware applies `uart0_console` (node already enabled) and adds alias `console` | EDK2 (ConsolePrefDxe) removes `stdout-path` unless `CONSOLE_MAIN=serial`: Linux uses the display |
| U-Boot, from `rpi/upstream/` over TFTP (only with `UBOOT_RPI5_EFI_FDT=upstream`); the Pi firmware never sees it | patch `rpi5/0021` adds alias `console` | patch `0007` (all Pis) removes `stdout-path` unless `CONSOLE_MAIN=serial` |
| iPXE `fdt` from `rpi/upstream/` by the `FdtFile` variable, under either firmware | node enabled in the tree; under U-Boot also `0021` through the EFI Device Tree Fixup Protocol | iPXE drops `stdout-path` when the firmware's tree has none ([ipxe-build](../ipxe-build/patches/) patch `0001`); under U-Boot also `0007` |

Without a display, Linux's console is the GPIO UART: kernel messages from the start and a login prompt on the serial cable.

## `rpi5-wifi-mac.dtsi`: the Wi-Fi MAC

A Pi 5's Wi-Fi MAC is in the SoC's OTP. The Pi firmware writes it into `local-mac-address` of the node alias `wifi0` names, as it does for Ethernet through `ethernet0`. Raspberry Pi's tree has both; upstream's has neither, so brcmfmac took the `macaddr` line of the nvram file and every Pi 5 had the Wi-Fi MAC `b8:27:eb:74:f2:6c`. The file adds alias `wifi0` and an all-zero `local-mac-address` on the Wi-Fi node:

- when the Pi firmware loads the tree itself (UEFI with `UEFI_RPI5_DT=upstream`), it fills in the address;
- when iPXE loads the tree with `fdt`, it copies the address from the firmware's tree ([ipxe-build](../ipxe-build/patches/) patch `0001`);
- a loader that fills nothing leaves zeros, which brcmfmac ignores: the same as without the property.

With the alias, systemd names the Wi-Fi interface after it, `wld0` instead of `wlan0`, as `ethernet0` gives `end0`; a configuration that names `wlan0` must be changed (or match the interface by MAC address).

The Pi 3B+ and Pi 4 need nothing: their Wi-Fi modules carry their own MAC, which brcmfmac prefers over the nvram file.

## When upstream adds the node

The script fails when upstream's `rp1-common.dtsi` gets a node at `serial@40030000`. Then drop our node from `rp1-uart0.dtsi`, point the aliases and `__overrides__` at upstream's node (check its compatible works with the RP1 driver holding the registers, see above), and update the `UPSTREAM.md` row.
