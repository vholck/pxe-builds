# Source patches

Patch files for U-Boot, applied by `build.sh` before the build: `*.patch` in this directory for every model, then `<model>/*.patch` (for example `rpi5/`) for that model only, each in file name order. `build.sh` uses `git apply --check`: a patch that no longer applies fails the build instead of being skipped silently.

Create a patch with `git diff` inside `/build/u-boot` of the build image, at the U-Boot version pinned in the Dockerfile. `.gitattributes` marks `*.patch` as `-text` so git never converts their line endings.

## Current patches

### `0001-bcmgenet-clear-ID_MODE_DIS-for-rgmii-rxid.patch`

Fixes transmit on the Pi 4's GENET network controller. U-Boot set `ID_MODE_DIS` for both `rgmii` and `rgmii-rxid`; for `rgmii-rxid` it must be cleared, otherwise the PHY drops every transmitted frame at 1 Gbit/s and DHCP never gets an answer. Full analysis in [../GENET-TX-FIX.md](../GENET-TX-FIX.md).

### `0002-rpi-keep-discovered_ram_size-out-of-bss.patch`

Ours, and needed on every model with U-Boot v2026.10. That version added a variable, `discovered_ram_size`, that the Raspberry Pi board code writes before U-Boot relocates itself. At that point the variable's storage overlaps the relocation table, so the write destroys one relocation entry and one pointer in the running U-Boot keeps its old address. Which pointer depends on the build.

In the Pi 5 build it was a list head in the EFI code: starting an EFI program then wrote a pointer into the file just loaded at `kernel_addr_r`, and iPXE crashed with an undefined instruction as soon as it configured the network. The patch moves the variable out of the overlapping area. Not fixed upstream when written (checked on `master`, 2026-11-17). Drop it when upstream fixes it.

### `0003-mmc-bcm2835-skip-the-sdio-wifi-slot.patch`

Ours. Saves about 3 seconds of every Pi 4 boot. The Pi 3 and Pi 4 have a second SD controller, `mmcnr@7e300000`, that is wired to the on-board WiFi chip. U-Boot treated it as a card slot, and when it scans the disks before starting iPXE it tried to find a card there: on a Pi 4 that printed `Timeout waiting for cmd & data inhibit` and `mmc1 busy timeout increasing to: ...` and took 3.3 s (measured on serial). The patch makes the driver leave a slot alone that holds no storage: one the device tree marks `non-removable` and that has a child node other than a storage card (`mmc-card`), which is how an SDIO function such as the WiFi chip is described. The real card slot (`mmc@7e340000` on the Pi 4, `mmc@7e202000` on the Pi 3) and a soldered eMMC are not touched. Upstream has no handling for SDIO-only slots. Not tested with an SD card inserted.

### `0004-bootp-use-the-dhcp-server-when-no-proxydhcp-answers.patch`

Ours. Removes a dependency on ProxyDHCP. The build enables `SERVERIP_FROM_PROXYDHCP`, which this stack needs: the router hands out addresses and dnsmasq names the boot server in a separate ProxyDHCP answer. With that option upstream U-Boot takes the boot server only from a ProxyDHCP answer and ignores the one a normal DHCP answer carries. On a network where one DHCP server does both jobs, `serverip` then stays empty and U-Boot cannot load iPXE.

With the patch U-Boot uses the DHCP server's own answer when no ProxyDHCP server has named a boot server. A ProxyDHCP answer still wins. The file U-Boot asks that server for is still `ipxe/snponly-arm64-rpi.efi` (`EFI_ARM64_RPI_FILE`).

One side effect on a network like the stack's own: many routers put their own address into the boot server field of their DHCP answers (the lab's does). If the ProxyDHCP server is down, U-Boot now asks the router for the iPXE file and waits for that to time out before it resets and tries again, where it used to fail at once.

Tested on a Pi 5 on the stack's own network (ProxyDHCP present: boots as before). The case the patch is for, a DHCP server that is also the boot server, has not been run: the lab has no such network.

### `0005-serial-pl01x-drop-characters-received-with-an-error.patch`

Ours. Without it a Pi 5 started with `enable_uart=1` in `config.txt` never boots: U-Boot ends its autoboot countdown at the `U-Boot>` prompt and waits there. The firmware leaves one break character in the receive buffer of the debug UART (read from the register on a Pi 5: `0x500`, a zero byte with the break and framing error flags), and U-Boot's PL011 driver reported any received byte as a key press. With the patch the driver drops bytes that carry an error flag; a real key still stops autoboot. Not caused by a cable: it happens with nothing connected to the UART pins.

Applied to every model, because the driver is not specific to the Pi 5: it is also the Pi 3's console driver (with the `miniuart-bt` overlay the Pi 3's console is the PL011). The Pi 4's console is the mini UART, a different driver, so the patch changes nothing there. Seen and tested only on a Pi 5 so far; until 2026-11 the file was `rpi5/0016`.

### `0006-mmc-bcm2835-sdhost-forget-a-failed-command.patch`

Ours. Removes false warnings from the Pi 3 console. The Pi 3's SD card slot is driven by `bcm2835_sdhost`. When a command to the slot fails, for example because no card is inserted and the card does not answer, the driver returns the error but keeps the failed command as the one in progress. The next command then trips a `WARN_ON` in the driver, and every probe of an empty slot (at start-up, before iPXE, and in the local-disk scan) printed lines of `WARNING at drivers/mmc/bcm2835_sdhost.c:414/bcm2835_send_command()!`. With the patch the driver forgets a request that failed, as the Linux driver does. A working card is not affected: only the error path changes. Upstream has the same code (checked on `master`, 2026-11-19; the driver has not changed since 2024). The Pi 4 and Pi 5 card slots use a different driver. Tested on a Pi 3 without an SD card (2026-11-20): no warning lines at start-up or in the local-disk scan, only upstream's one-line `Card did not respond to voltage select! : -110` per probe; the network boot and a USB stick boot through `localboot` work as before.

### `0007-rpi-os-console-on-the-display-when-one-is-present.patch`

Ours; platform rule R2 (the same OS console choice on every Pi and under both firmwares, see docs/proposals/platform-consistency.html). The device tree U-Boot hands to an EFI program names the serial port in `/chosen/stdout-path`, and Linux started without `console=` makes that its main console, also when a display is connected. EDK2 on the same boards removes `stdout-path` when a display is present (ConsolePrefDxe, "graphical" preference). The patch does the same in `ft_board_setup()` for every model: when U-Boot's video device is up, it removes `stdout-path` unless the environment variable `console_main` is `serial`. `build.sh` sets `console_main` from `CONSOLE_MAIN` (root `.env`, `auto` or `serial`). U-Boot's config.txt has no `hdmi_force_hotplug`, so the video device is up only when the firmware found a display.

It prints one line before the handover: `RPI: OS console on the display (stdout-path removed)` or `RPI: OS console on serial (stdout-path kept)` (`, console_main=serial` added when a display is present). Upstream has no such rule for the Pi; the closest is the Apple board code, which points `stdout-path` at the framebuffer in `ft_board_setup` when a keyboard is present. Until 2026-11-22 only the Pi 5 had a display rule (in `rpi5/0021`).

## Tried and not kept

- Lowering U-Boot's `Not a PE-COFF file` message to debug level. iPXE offers every file it downloads to the firmware as a possible EFI program first, scripts included, so the line is printed after every script. It is noise there, but it is also the only hint when the iPXE binary itself arrives corrupt, so it stays as upstream prints it.

### `rpi5/0001` to `rpi5/0014`: Raspberry Pi 5 support (the RP1 chip)

Upstream U-Boot has no driver for the RP1 chip, which carries the Pi 5's Ethernet and USB, so a stock build starts on a Pi 5 and then has no network. These patches add the missing pieces: the RP1 device with its clock, GPIO and pin drivers, Ethernet (macb) on the RP1, the board code that starts the RP1, and the defconfig changes.

They are not ours. They come from [siderolabs/sbc-raspberrypi pull request 88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) (open and unmerged when taken, branch head `9abca1be155611111be455ce4c10bc98ebf49108`, written for U-Boot v2026.01). Each file keeps its original header and number. The published files did not apply as they were, so they were first re-exported against U-Boot v2026.04 and then rebased onto v2026.10.

U-Boot v2026.10 has its own BCM2712 PCIe driver, reset drivers and memory map, so the set is smaller than the original 14:

| Patch | State for v2026.10 |
| --- | --- |
| `0001` BCM2712 SoC support | cut down to the `BCM2712` Kconfig option and the board type header; upstream's memory map is used |
| `0002` built-in device trees | dropped; U-Boot uses the device tree the firmware passes, and upstream's device tree files changed |
| `0003` PCIe controller | cut down to the RP1's PCI IDs; upstream's driver is used |
| `0005` reset drivers | dropped; upstream has the same drivers |
| `0011` NVMe address translation | dropped; upstream fixed it its own way, and NVMe is not used here |
| `0004`, `0006` to `0010`, `0012` to `0014` | rebased, content unchanged apart from merge fixes (`0014` no longer sets the reset drivers, which the upstream defconfig already enables) |

Drop the set when upstream U-Boot supports the Pi 5's Ethernet.

On a U-Boot version bump: first go through the U-Boot rows of [UPSTREAM-TRACKING.md](../../UPSTREAM-TRACKING.md) and drop each patch whose "Drop when" is met (for the Pi 5 set: Torsten Duwe's RP1 series upstream). Then clone U-Boot with both tags, commit the patches one by one on the old tag, cherry-pick them onto the new tag and resolve what conflicts, then export each commit with `git diff` below the old header. Boot a Pi 5 on the result before pushing; `build.sh` only proves that the patches apply.

### `rpi5/0015-net-macb-init-the-phy-only-once.patch`

Ours, and required for a reliable boot. With the patches above, every start of the Ethernet interface pulses the PHY's reset line and reconfigures the PHY, so the link drops and renegotiates each time. U-Boot's own `dhcp` and `tftpboot` cope with that. iPXE, which starts DHCP immediately after U-Boot hands the interface over, does not: on a Pi 5 about half of the boots lost the ProxyDHCP answer, iPXE then did not know the boot server and rebooted. The patch resets and configures the PHY only on the first start.

Measured on a Pi 5: 2 of about 8 boots reached `boot.ipxe` without it, 5 of 5 with it, and the time from U-Boot to `boot.ipxe` dropped from about 45 s to about 19 s.

### `rpi5/0017-rpi-console-on-the-gpio-header.patch`

Ours. Gives the Pi 5 a console on GPIO 14 and 15, the pins where the Pi 3 and Pi 4 have theirs, so the same serial cable works on all three. Without it U-Boot on a Pi 5 talks only to the debug UART on the 3-pin connector between the HDMI ports, and those GPIO pins are not connected to any UART while U-Boot runs.

The console is added only when the firmware's device tree names the RP1's UART0 `serial0` and enables it, which is what `enable_uart=1` in `config.txt` does; with `enable_uart=0` nothing changes. It is a second console next to the debug UART and HDMI, for output and input, so U-Boot, iPXE and the netboot.xyz menu can be read and driven over the cable. The RX pin gets its pull-up so that an unconnected pin is not read as key presses. The device tree handed to what boots next is not changed.

Limits: U-Boot's first lines (banner, memory, `MMC:`) are printed before the RP1 chip is up, so they cannot be printed on the cable when they happen; `rpi5/0019` replays most of them. The firmware's own messages never appear on GPIO. The patch relies on the RP1's UART clock running from the 50 MHz crystal, which is how the board starts; if it finds anything else it prints a message and adds no console. It needs `0005` so that line noise is not taken for a key.

### `rpi5/0018-net-macb-start-autonegotiation-at-probe.patch`

Ours. Makes the Pi 5 boot about 4 seconds faster. Before it, the Ethernet PHY was reset and configured at the first start of the interface, which is U-Boot's `dhcp`, and that start then waited about 3.5 seconds for the link to be negotiated. The patch resets and configures the PHY when U-Boot finds the network device (the `Net:` line) and starts the negotiation there without waiting. The link comes up during the USB scan and the boot delay, and `dhcp` finds it up.

A start that comes before the negotiation has finished prints `Waiting for autonegotiation...` and waits for it instead of restarting it. If the early setup fails, the first start does the setup again as before. It builds on `rpi5/0015` (the PHY is still set up only once).

Measured on a Pi 5, from the `Net:` line to the iPXE banner: 9.3 s without the patch, 5.1 s with it (two resets and two boots from power-off). The first DHCP answer also arrives sooner (about 0.1 s instead of 0.8 s), because the first requests are no longer sent into a link that has just come up. Not tested: a boot with the Ethernet cable unplugged.

### `rpi5/0019-rpi-replay-earlier-output-on-the-gpio-console.patch`

Ours. Shows on the GPIO console what U-Boot printed before that console existed. It turns on U-Boot's console recorder for the Pi 5 build (`CONFIG_CONSOLE_RECORD`, 8 KiB, from relocation on) and, when `rpi5/0017` starts the GPIO console, prints the recorded text there between two marker lines:

```
--- U-Boot 2026.10-pxe-<commit> (<build date>): earlier output, replayed ---
RPI 5 Model B (0xd04170)
Core:  81 devices, 20 uclasses, devicetree: board
MMC:   mmc@fff000: 0, mmc@1100000: 1
...
RPI: RP1 initialized successfully
--- end of replay, live from here ---
Net:   eth0: ethernet@100000
```

The markers are there because the replayed lines are not printed when they happen: in a timed capture they all carry the time of the replay. The replay goes to the GPIO console only; the debug UART and HDMI saw the lines live. Recording stops after the replay. The banner and the `DRAM:` line are printed before relocation and are not recorded, which is why the first marker gives the version. The replay takes under 0.1 s.

The patch also selects the UART function before it enables the TX pad and leaves the line idle for 2 ms before the first character.

One or two junk bytes (`0xd5 0x00` after a reset, zero bytes after a power cut) show up in a capture just before the first marker. They are not sent by U-Boot's console: a capture with a time for every read shows them in the same millisecond as the `resetting ...` line, 22 seconds before the console starts. The reset lets go of the TX pin, the line drops, and the serial adapter reports that as a character. Nothing in U-Boot can prevent it; a `gpio=14=pu` line in `config.txt` did not either (tried).

Tested on a Pi 5: a reset and a boot from power-off show the replay and reach `boot.ipxe`; with `enable_uart=0` (no GPIO console, nothing replayed) the board boots as before.

### `rpi5/0020-rpi-let-efi-payloads-use-ram-below-4gb-on-the-pi-5.patch`

Ours. Programs U-Boot starts with `bootefi` (iPXE, and the Linux kernel iPXE starts) take their memory from U-Boot's memory manager (LMB). Upstream reserves all RAM above `ram_top` there, which on a Raspberry Pi is the end of the first DRAM bank, about 1 GB, because some BCM2711 devices cannot DMA further. On a Pi 5 with 8 GB that left about 990 MB: Flatcar's 363 MB initrd failed with `EFI stub: ERROR: Failed to load initrd: 0x8000000000000009` (out of resources), because iPXE holds the initrd and the EFI stub needs a copy. Upstream's BCM2712 MMU map also covered only the first 1 GB.

The patch, for the BCM2712 only:
- maps DRAM up to the top of the RAM the firmware reports below 4 GB (from its `/memory` nodes; never less than upstream's first 1 GB, which also holds the framebuffer above the first bank);
- turns on `LMB_ARCH_MEM_MAP` with `BCM2712` in `lib/Kconfig` (the option has no prompt, so a defconfig line is ignored) and adds a board `lmb_arch_add_memory()` that adds the DRAM banks and reserves only RAM above 4 GB.

Every DMA master of the BCM2712 reaches that range: the AXI bus and the PCIe inbound window to RP1 (USB, Ethernet) cover 64 GB from address 0 (`dma-ranges` in the firmware's device tree), and the SD controller uses 32-bit SDMA. Other SoCs keep the `ram_top` limit.

By RAM size: 1 GB boards keep what they had; 2 GB and 4 GB boards give all their RAM; 8 GB and 16 GB boards give the first 4 GB and keep the rest reserved as before. Only the 8 GB board was tested; the other sizes follow from the banks the firmware reports (checked by calculation).

Tested on the 8 GB Pi 5: `bdinfo` shows only `0x100000000-0x1ffffffff` reserved (before: everything from `0x40000000`); writing and reading `0xfff00000` from the U-Boot prompt works; Flatcar's initrd loads (`EFI stub: Loaded initrd`) with both device trees; iPXE, the netboot.xyz menu and Debian 13's installer work as before.

### `rpi5/0021-rpi-gpio-uart-as-the-os-console.patch`

Ours. Puts the OS console on GPIO 14 and 15, as on the Pi 3 and Pi 4, for both trees a Pi 5 can hand over.

**Raspberry Pi's own tree** (the default, `UBOOT_RPI5_EFI_FDT=firmware`): it names the debug connector's UART in `stdout-path` (`serial10:115200n8`), while Raspberry Pi's Pi 3 and Pi 4 trees name `serial0`, the GPIO UART, which is `serial0` on the Pi 5 too. When the firmware's UART0 is enabled (`enable_uart=1`), `stdout-path` becomes `serial0:115200n8` and U-Boot prints `RPI: device tree: OS console on the GPIO UART (serial0)`. Raspberry Pi OS gets the same with `console=serial0,115200` on its command line; a tree handed over through EFI must say it itself. Without the patch Alpine's `linux-rpi` had its console on `ttyAMA10` (2026-11-23).

**An upstream device tree**: gives Linux a console on GPIO 14 and 15 when U-Boot hands over an upstream device tree (`UBOOT_RPI5_EFI_FDT=upstream`). Those trees, built from `dts/` at the repository root, carry the RP1's UART0 as an `arm,sbsa-uart` node (enabled in the tree since 2026-11-23, so the `okay` below changes nothing any more) with the aliases `serial0` and `uart0` and `stdout-path = "serial0:115200n8"` (see [dts/README.md](../../dts/README.md)). When the firmware loads such a tree itself, as it does under UEFI, it applies `config.txt` to it. A tree U-Boot fetches over TFTP never passes through the firmware, so the patch does the same in `ft_board_setup()`, which runs on every tree `bootefi` hands over:

when the firmware's own tree has its UART0 enabled (`enable_uart=1`, the same test as `rpi5/0017`), the node gets `status = "okay"` and the alias `console`, as the firmware's `uart0_console` parameter does. Whether `stdout-path` stays is decided for every model by `0007`.

It prints one line, for example `RPI: device tree: GPIO UART enabled`. Other trees are left alone. The firmware test moves into a function shared with `rpi5/0017`.

## Not a patch

`build.sh` switches the Pi 5 build from the lwIP network stack back to the classic one (`NET_LEGACY`). Since v2026.10 `rpi_arm64_defconfig` selects lwIP, which cannot take the boot server from the ProxyDHCP answer; U-Boot then asks the router for the iPXE file. The build fails if `SERVERIP_FROM_PROXYDHCP` is missing from the final configuration.

The boot environment (`bootp_vci`, `netboot` and `bootcmd`) is generated by `build.sh`, because it contains the iPXE file name and per-model parts.

`build.sh` also builds the upstream Linux device trees of every family from devicetree-rebasing at `RPI_DT_TAG` (root `.env`; Pi 5: with the RP1's UART0 added; `dts/build-rpi-upstream.sh` at the repository root, shared with rpi-uefi-build) and serves them as `rpi/upstream/broadcom/`, for boot scripts that load one by the `FdtFile` variable. With `UBOOT_RPI5_EFI_FDT=upstream` (default) `netboot` fetches `rpi/upstream/${fdtfile}` before iPXE and hands it to `bootefi`, so the kernel iPXE starts gets it; a board without an upstream tree (CM5, Pi 500) gets the firmware's tree. The firmware's tree describes RP1 as Raspberry Pi's kernel expects (`simple-bus` under PCIe); upstream Linux expects a PCI device node (`pci1de4,1`), so a distribution kernel finds no Ethernet or USB behind RP1 with the firmware's tree.
