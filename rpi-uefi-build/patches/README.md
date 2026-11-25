# Source patches

Patch files for `edk2-platforms`, applied by `build.sh` before each build:

- `common/*.patch` for every model
- `rpi3/*.patch`, `rpi4/*.patch`, `rpi5/*.patch` for one model

Patch files for Trusted Firmware-A, the first stage of the Pi 5 firmware image (`/build5/arm-trusted-firmware`, pinned by `RPI5_TFA_TAG` and `RPI5_TFA_COMMIT`; the submodule of `RPI5_UEFI_REF` when `RPI5_TFA_TAG` is empty), applied by `build.sh` before it builds that stage:

- `rpi5-tfa/*.patch`

Pi 3 and Pi 4 are built from the `edk2-platforms` of pftf/RPi4 (`/build` in the build image, pinned by `PFTF_REF`), the Pi 5 from the `edk2-platforms` of the Pi 5 port (`/build5`, pinned by `RPI5_UEFI_REF`). A `common` patch has to apply to both.

Patch files for iPXE, applied by the `Dockerfile` before it builds the Pi 3 and Pi 5 Ethernet drivers:

- `ipxe/*.patch`, made with `git diff` at the iPXE commit pinned by `UEFI_IPXE_REF`

Create a patch with `git diff` inside `/build/edk2-platforms` (Pi 5: `/build5/edk2-platforms`) of the build image, at the pinned commit. `build.sh` uses `git apply --check`: a patch that no longer applies fails the build instead of being skipped silently.

`.gitattributes` marks `*.patch` as `-text` so git never converts their line endings; some EDK2 sources use CRLF and a converted patch no longer applies.

## Current patches

### `common/0001-reset-when-nothing-boots.patch`

Makes a Pi that found nothing to boot start over by itself. Upstream, when every boot option has failed, the firmware prints `No bootable option or device was found. Press any key to enter the Boot Manager Menu.` and waits for a key without a time limit. A Pi without keyboard and disk then stays there for good, for example after the boot server was unreachable once, or after the netboot.xyz menu timed out and iPXE handed back to the firmware. With the patch the firmware waits 10 seconds for a key and then resets; a key still opens the Boot Manager Menu.

### `common/0002-boot-order-pxe-disks-http.patch`

Sorts the boot options, every boot, in this order: network boot through PXE, then the local devices (USB, SD, NVMe), then HTTP boot, then the applications built into the firmware (setup screen, shell). Upstream keeps the order in which the options were created, and that depends on which devices the firmware found when: on a Pi 3 it was PXEv4, HTTPv4 and only then a disk. When iPXE hands back to the firmware (netboot.xyz "Boot from local hdd"), the firmware goes on to the next option, so the disk only came after HTTP boot had waited about a minute for a server that this stack does not provide.

HTTP boot stays available, last among the boot devices: on a network that offers it instead of PXE it still boots, and on this one it no longer stands between iPXE and the disk. If HTTP boot came before the disk on a network that does answer it, it would most likely serve the same iPXE menu again, the loop that `ipxe/0003` and `EFI_DOWNGRADE_UX` removed. Options of the same kind keep their relative order. An order set in the setup screen does not survive a reboot anyway when the firmware comes over TFTP, so the patch takes nothing away there.

The patch also keeps the network first when a disk is present at start-up: the firmware may create the disk's option before the network ones (on the Pi 3 the stick was `Boot0001`, PXE `Boot0002`), and in upstream's order the disk would then boot before the network.

Tested on a Pi 3 (2026-11-20): without a disk the options are PXEv4, HTTPv4, UiApp, Shell, and the network boot is unchanged; with a USB stick, PXEv4, the stick, HTTPv4, UiApp, Shell; "Boot from local hdd" started GRUB from the stick 12 s after iPXE left, without HTTP boot in between (before: HTTP boot first, 60 s). The same on a Pi 4 (2026-11-20): PXEv4, the stick, HTTPv4, UiApp, Shell; GRUB 1 s after iPXE left. Not yet run on a Pi 5, whose firmware is built from a separate tree with the same `PlatformBm.c`.

### `common/0003-fdtdxe-publish-fdtfile-variable.patch`

Publishes the UEFI variable `FdtFile` (vendor GUID `eedf58fc-1b9b-4ab0-8b6b-954d79d6b052`, boot services only, ASCII without a terminating NUL): the path of the board's upstream Linux device tree in the layout distributions use, for example `broadcom/bcm2711-rpi-4-b.dtb`. The names and the board table are those of U-Boot's `fdtfile` (`board/raspberrypi/rpi/rpi.c`, Pi 5 D0 stepping included), and rpi-uboot-build publishes the same variable, so a boot script reads it the same way under both firmwares (iPXE: `${efi/FdtFile:string}`) and loads the tree an OS needs with `fdt`. The firmware itself still hands over Raspberry Pi's tree or ACPI, unchanged.

The variable is set in `FdtDxe` at ReadyToBoot (variable services are certainly up by then) and in every system table mode, also ACPI only, where `FdtDxe` otherwise does nothing. Boards without an upstream tree (Pi 1 and 2, unknown revision codes) get no variable. The patch uses only what both source trees share (the firmware protocol's `GetModelRevision`, the runtime services from the entry point), so one patch applies to both.

### `rpi4/0001-rpi4-mac-fallback-from-genet.patch`

Safety net for a Pi 4 whose VideoCore mailbox returns an all-zero MAC address (reported for some board revisions). When that happens the firmware reads the address back from the GENET network controller, where the Raspberry Pi firmware has already programmed it for its own network boot.

### `rpi4/0002-rpi4-fdt-size-128k.patch`

Sets `PcdFdtSize` to 128 KB (0x3e0000 to 0x400000) in `RPi4.dsc`, as the Pi 5 port does in `RPi5.dsc`. Upstream leaves the Pi 4 at the 64 KB default of `RaspberryPi.dec`, while pftf/RPi4's `config.txt` and the memory comment in `RPi4.dsc` give the device tree 128 KB (`device_tree_end=0x400000`). EDK2 maps only `PcdFdtSize` bytes and `FdtDxe` reads the tree from there, so a tree larger than 64 KB would be read partly from unmapped memory. The Pi 4 tree is 56 KB before the firmware adds its overlays and `/chosen` (2026-11-22), so the 64 KB window was close to full. The range 0x3f0000 to 0x400000 is used by nothing else (RAM starts at 0x400000). `build.sh` reads the size from the `.dsc`, so `config.txt` now ends the tree at 0x400000, as upstream's does.

It does nothing on a board that reports its MAC correctly. Verified on a Pi 4 by forcing the mailbox result to zero in a test build: without the patch PXE fails with "Server response timeout"; with it the Pi boots with its real MAC.

### `rpi3/0001-rpi3-onboard-ethernet-and-boot-policy.patch`

Makes the Pi 3 firmware able to network boot from its onboard Ethernet. Two additions to `RPi3.dsc` / `RPi3.fdf`:

- **Onboard Ethernet driver.** EDK2 has no driver for the Pi 3's USB Ethernet chip (LAN9514 on the 3B, LAN7515 on the 3B+). The patch embeds `/build/ipxe-usbnic.efi` in the firmware image. That file is iPXE built as a UEFI driver with only the `smsc95xx` and `lan78xx` drivers, talking to the chip through the firmware's USB stack (`USB_HCD_USBIO`, as in iPXE's own `rpi` configuration). The `Dockerfile` builds it from the commit in `UEFI_IPXE_REF`.
- **Boot manager policy driver** (`BootManagerPolicyDxe`). The Pi platform code asks this driver to connect the network devices before it lists boot options. The Pi 4 platform includes it, the Pi 3 platform does not; without it the firmware prints `Failed to locate gEfiBootManagerPolicyProtocolGuid`, finds nothing to boot, and resets in a loop.

Seen on a Pi 3B before the patch: `BdsDxe: No bootable option or device was found` (also with the April 2026 build from pftf/RPi3). With both additions the firmware gets a DHCP lease, answers ping from the UEFI Shell, and boots through iPXE to the netboot.xyz menu. With only the Ethernet driver the Shell has working network but the firmware still does not boot from it.

### `rpi5/0001-rpi5-onboard-ethernet.patch`

Makes the Pi 5 firmware able to network boot from its onboard Ethernet. The EDK2 port for the Pi 5 has no Ethernet driver (its README lists "RP1 Ethernet" as not working), so the unpatched firmware ends at `No bootable option or device was found` on a Pi without a disk. Two additions:

- **Onboard Ethernet driver** (`RPi5.fdf`). Embeds `/build5/ipxe-rp1gem.efi` in the firmware image: iPXE built as a UEFI driver with the RP1 Ethernet driver that `ipxe/0002` adds. The `Dockerfile` builds it from the commit in `UEFI_IPXE_REF`.
- **MAC address** (`RpiPlatformDxe`). The Raspberry Pi bootloader leaves the Ethernet controller's address registers empty. When the firmware's RP1 bus driver has found the chip, the platform driver asks the VideoCore firmware for the board's MAC address and writes it into the controller, where a network driver expects to find it. Seen on a Pi 5 before this was added: the driver came up as `00:00:00:00:00:00`, received packets, and DHCP got no answer.

Seen on a Pi 5 (8 GB, revision `d04170`) with both additions: DHCP lease with the board's own MAC, the stack's iPXE over TFTP, `boot.ipxe`, the netboot.xyz menu. The firmware's own `PXE over IPv4` boot option works through the same driver.

### `rpi5/0002-rpi5-console-on-the-gpio-header.patch`

Gives the Pi 5 firmware a console on GPIO 14 and 15, where the Pi 3 and Pi 4 have theirs. On a Pi 5 these pins belong to UART0 of the RP1 chip, which sits behind PCIe; the port's only serial port is the debug UART on the 3-pin connector. Two parts:

- **Serial port driver** (`Rp1UartDxe`, new). When the firmware's RP1 bus driver has found the chip, the driver sets up UART0 (a PL011, clocked from the RP1's 50 MHz crystal), connects GPIO 14 and 15 to it, with a pull-up on the receive pin, and publishes it as a second serial port with a device path of its own. Characters received with an error flag are dropped, so the line going low at a reset or when a cable is plugged in is not taken for a key press.
- **Boot manager** (`PlatformBootManagerLib`). Lists the new port in the console variables next to the existing one, prints the boot prompt on it, and starts the RP1 bus driver before the consoles are connected. The last point is needed: left to the normal order, the RP1 is started after the console phase, and a terminal that appears then is not made a console any more (seen: the terminal's start-up sequences on the cable and nothing after them).

The pins are taken only when the device tree from the Raspberry Pi firmware names this UART `serial0` and enables it, which is what `enable_uart=1` in `config.txt` does (`build.sh` writes that line). Without it the driver does nothing and the pins stay free for a HAT. The driver also does nothing when the RP1's UART clock is not in its power-on state.

The patch by itself puts only the console on the pins, starting with the boot prompt; `rpi5/0003` adds the firmware's diagnostics. The existing console on the debug UART is unchanged; both are active.

An earlier attempt made the RP1 UART the firmware's only serial port: the firmware then hangs right after `RPI_EFI.fd` is loaded, because it prints long before the RP1 can be reached.

### `rpi5/0003-rpi5-diagnostics-on-the-gpio-console.patch`

Puts the firmware's diagnostics (errors and warnings, or everything in a `debug` build) on the GPIO console as well, including what was printed before that console existed. Without it they appear only on the debug UART, because the library they are printed through has to work from the first instruction, long before the RP1 can be reached.

- **Serial port library** (`Rpi5SerialPortLib`, new; replaces `PL011SerialPortLib` for every module except `SerialDxe`). It drives the debug UART as before and also keeps a copy of what it prints: in a 64 KiB record until the GPIO port is up, on the GPIO port directly afterwards. The record sits at a fixed address, the first 64 KiB of system RAM (`0x400000`), because the library is linked into every module separately and the first of them runs before there is any other way to share data. The instance linked into the first module (SEC) starts an empty record at each boot.
- **Memory map** (`RaspberryPiMem.c`). Reserves those 64 KiB, so neither the firmware's allocator nor an operating system uses them.
- **`Rp1UartDxe`.** When the GPIO port is ready it prints the record between two marker lines, then hands the port's address to the library. At ExitBootServices it switches the copy off: the RP1 and the memory belong to the operating system from there on.
- **`SerialDxe` keeps the stock library.** It carries the console text for the debug UART. The GPIO port has a console of its own; a copy would print every character there twice.

```
--- UEFI firmware EDK2-DEV: earlier output, replayed ---
UEFI firmware (version EDK2-DEV built at 21:01:50 on Nov 18 2026)
Failed to get Asset Tag: Not Found
--- end of replay, live from here ---
```

The markers are there because the replayed lines are not printed when they happened: in a timed capture they all carry the time of the replay. If more was printed than the record holds, the second marker says how many bytes are missing. Messages of Trusted Firmware-A are added by `rpi5-tfa/0001` and `rpi5/0004`.

Tested on a Pi 5: the replay and live diagnostics on the GPIO cable, console text printed once, and the Debian 13 installer started from this firmware (the kernel's `Exiting boot services` and the installer's first screen).

### `rpi5/0005-rpi5-gpio-uart-as-the-os-console.patch`

Raspberry Pi's own Pi 5 tree (handed over by default, `UEFI_RPI5_DT=firmware`) names the debug connector's UART as the console (`stdout-path = "serial10:115200n8"`), while Raspberry Pi's Pi 3 and Pi 4 trees name `serial0`, the UART on GPIO 14 and 15, which is `serial0` on the Pi 5 too. `FdtDxe` changes it to `serial0:115200n8` when that UART is enabled (`enable_uart=1`, applied by the Pi firmware when it loads the tree), the same rule as rpi-uboot-build's `rpi5/0021`. A tree that names another UART (the upstream trees name `serial0` already) is left alone, and ConsolePrefDxe still removes `stdout-path` when a display is the main console. Tested on a Pi 5 (2026-11-23): Alpine's `linux-rpi` had its console on `ttyAMA10` before, `ttyAMA0` (GPIO) with the patch, login on the serial cable.

### `rpi5-tfa/0001-rpi5-record-boot-messages-for-the-gpio-console.patch` and `rpi5/0004-rpi5-keep-the-record-started-by-tf-a.patch`

Put the boot messages of Trusted Firmware-A (BL31) on the GPIO console too. BL31 is the first code of the firmware image; it prints its version lines on the debug UART and then starts the UEFI firmware. It has its own console code, so `rpi5/0003` did not see those lines.

- **`rpi5-tfa/0001`** (Trusted Firmware-A). Adds a second console that writes into the record `rpi5/0003` introduced (same address, same layout), and starts that record, since BL31 runs first. Only boot messages are recorded; at runtime BL31 does not touch the record. It also maps the record's memory for BL31 and raises two table limits for that.
- **`rpi5/0004`** (UEFI). The first UEFI module no longer empties the record when BL31 has marked it as started in this boot; it clears the mark, so a record left over from an earlier boot is still thrown away.

The replay then starts with BL31's lines:

```
--- UEFI firmware EDK2-DEV: earlier output, replayed ---
NOTICE:  BL31: v2.13.0(release):000fe22-dirty
NOTICE:  BL31: Built : 21:45:51, Nov 18 2026
UEFI firmware (version EDK2-DEV built at 21:45:55 on Nov 18 2026)
ReplaceTableEntry: splitting block entry with MMU disabled
Failed to get Asset Tag: Not Found
--- end of replay, live from here ---
```

BL31 flushes every write to the record from the data cache. The UEFI firmware starts with the MMU and the caches off and continues the record in RAM; without the flush BL31's cached copy of the record's header later replaced what UEFI had written, and UEFI's first line (its banner) was missing from the replay (seen on the first test build).

Tested on a Pi 5: the replay as above after a power-off boot, twice, and the Debian 13 installer started from this firmware. `-dirty` in BL31's version is the patch itself. The `ReplaceTableEntry: splitting block entry with MMU disabled` line is EDK2's own and not a fault. Its MMU code prints it when it has to split a large page-table entry that is in use and covers the page tables or the code doing the split; it then switches the MMU off for that one update. It is not caused by the 64 KiB these patches reserve: a test build that reserved a full 2 MiB, so that the system RAM started on a large-page boundary as before, printed the same line.

### `ipxe/0002-rp1-ethernet-driver-for-uefi.patch`

Adds a UEFI driver for the Ethernet controller of the Pi 5 to iPXE (`rp1gem`). The controller is a Cadence GEM inside the RP1 chip, which sits behind PCIe. iPXE already has a Cadence GEM driver (`cgem`), but only for boards that describe the controller in a device tree. The patch:

- splits `cgem`'s probe into bus-independent functions (`cgem_alloc`, `cgem_register`, `cgem_unregister`), with the device-tree probe as one caller;
- adds `drivers/net/efi/rp1gem.c`, the other caller. It attaches to the handle on which the firmware's RP1 bus driver publishes its bus protocol, asks that protocol where the RP1 peripherals are mapped, and drives the controller at offset `0x100000`. The firmware's own driver keeps the PCI device; this driver uses the PCI I/O protocol only to get DMA buffers the chip can reach;
- does not reset the PHY for this controller. The PHY keeps the setup the Raspberry Pi bootloader gave it (clock delays, negotiated link); the U-Boot port needed a patch for the same reason;
- takes the hardware address from the controller's registers when no device tree supplies one;
- parks unused priority transmit queues on a spare descriptor. Harmless where there are none (the RP1 reports none).

The driver keeps the speed setting the bootloader left in the controller, which is the speed of the link the Pi was just booted over. A link that comes back at another speed afterwards (a different switch port without a power cycle) is not followed.

### `ipxe/0001-efi-snp-receive-without-extra-poll.patch`

Makes downloads through the Pi 3 Ethernet driver about three times faster. The driver hands packets to whatever runs next (the iPXE the pxe stack serves, or any other UEFI network client) through UEFI's network interface. iPXE polled the network chip again on every single packet it handed over, and on this USB path a poll that finds nothing waits for a timeout. The patch polls only when no packet is queued.

Measured on a Pi 3B, 42 MB over HTTP from the iPXE served by the pxe stack: 117 s without the patch, 38 to 43 s with it. For comparison: 10 s when the driver's own iPXE does the download, 4.5 s under U-Boot. Collecting several packets per poll was also tried and made it worse (171 s, with stalls).

### `ipxe/0003-efi-snp-wait-for-link-at-initialize.patch`

When the firmware opens the network device (`Initialize` of UEFI's network interface), the driver now waits up to 5 s for the link before it returns. The firmware's PXE and HTTP boot check the link once, right after opening the device, and give up silently if it is down; only a driver with the Adapter Information Protocol gets a longer wait from them, and iPXE has none. On a Pi 5 the link renegotiates when the firmware starts the RP1 (`MnpSyncSendPacket: No network cable detected` right after every reset), so at the first boot option it is still down.

This mattered once the driver stopped offering a boot option of its own (`EFI_DOWNGRADE_UX` in the [Dockerfile](../Dockerfile)). Upstream's driver adds "UEFI PXEv4 (MAC:...)", which runs iPXE inside the firmware and waits for the link itself; the firmware's own PXE client adds a second "UEFI PXEv4 ... 2". With both, iPXE handing back (netboot.xyz's "Boot from local hdd") led to the second option and the menu again, before any local disk. Without the driver's option and without this patch, the firmware's PXE option failed silently at every boot, HTTP boot reported `Could not detect network connection`, and the Pi reset in a loop.

Tested on a Pi 5 (2026-11-19): the boot options are UiApp, one "UEFI PXEv4", "UEFI HTTPv4" and the shell; a power-off boot reaches the menu through `>>Start PXE over IPv4` (4 s after the boot prompt), and "Boot from local hdd" goes on to `>>Start HTTP Boot over IPv4` instead of the menu. The firmware's own DHCP makes the menu come about 4 s later than through the driver's option. A cable that is unplugged costs 5 s each time a boot option opens the device.

### `ipxe/0004-cgem-larger-receive-ring.patch`

Raises the receive ring of iPXE's Cadence GEM driver (`cgem.h`, used by `rp1gem` for the Pi 5's Ethernet) from 8 to 64 descriptors, from 12 KB to 96 KB of receive buffers. With 8, the ring overflowed when a server sent a TCP window's worth of frames, frames were dropped and TCP slowed down after each loss, so downloads under the Pi 5's UEFI firmware ran at 0.2 to 0.9 MB/s and very large files almost stalled. U-Boot's own driver is not affected.

Tested on a Pi 5 (2026-11-21), the same HTTPS files from the iPXE shell under UEFI: Fedora CoreOS kernel (17.3 MB) 95.3 s before, 0.9 s after; its initramfs (98.3 MB) 114.6 s before, 3.4 s after; Flatcar's initrd (363 MB) about 1 % a minute before, 11.5 s after.

## Not patches

- The 3 GB RAM limit is a firmware setting, changed through `UEFI_RAM_LIMIT_3GB`.
- The earlier per-device build that compiled a MAC address into the firmware is gone; the fallback above replaces it and needs no per-device data.

### Console lines that are not faults

The default `warn` build prints the error messages of upstream drivers. Some of them appear on every boot of a Pi without an SD card or monitor. They are left as upstream prints them:

- **Pi 3: `Data Stage Error for device 0x1: 0x2` and `... device 0x2: 0x2`** at the boot prompt. Printed by `Platform/RaspberryPi/Drivers/DwUsbHostDxe/DwUsbHostDxe.c` when the data stage of a USB control transfer fails. `0x2` is `EFI_USB_ERR_STALL`: the device refused a request it does not support. Devices 1 and 2 are the board's LAN9514 hub and Ethernet controller (`0424:9514`, `0424:ec00`), which have no string descriptors; the refused request is most likely the one for the string table. With a USB stick plugged in, `Data Stage Error for device 0x3: 0x40` blocks follow (a few at start-up and again when the firmware opens the stick). Seen with a Kingston DataTraveler on 2026-11-20: the stick was listed, and booted GRUB right after these lines, so they do not mean the stick failed.
- **Pi 5: `Error reported by SDHCI`, `Error interrupt status = 1`, `TRB failed with Device Error` and a dump of the request**, four times, without an SD card. Printed by EDK2's `MdeModulePkg/Bus/Pci/SdMmcPciHcDxe/SdMmcPciHci.c` for every command that fails. Status bit 0 is a command timeout, and the dumps show commands 1, 8, 5 and 55 on slot 0: the driver tries in turn for an eMMC, SD and SDIO card in the empty slot and gets no answer.
- **Pi 5: `RpiFirmwareAllocFb: mailbox transaction error ... 0x80000001` and `Could not start DisplayDxe: Device Error`.** No monitor is connected, so the VideoCore firmware gives the UEFI firmware no framebuffer. With a monitor (tested with an HDMI capture stick that was capturing) the lines are not printed and the console appears on HDMI.
- **Pi 5: `PCIe: Link down (timeout)`.** Nothing is connected to the PCIe connector.
