# Where this repository differs from upstream

One list of everything the images of this repository build or configure differently from the projects they are built from: which version is pinned, what is changed, why, and where the change lives. Each row links to the full description (cause, measurements, what was tried).

**Keep it current:** a new patch, a changed build option or a new pin gets a row here in the same commit. A row whose reason is gone is removed together with the change.

**Upstream status:** what already exists elsewhere for each of these (merged, in review, in a fork), when ours can be dropped, and what could be contributed is tracked in [UPSTREAM-TRACKING.md](UPSTREAM-TRACKING.md). Check it before adding a patch, and at every version bump.

How a change is made:

- **Patch**: a file under the stack's `patches/`, applied by the build script. A patch that no longer applies fails the build.
- **Build option**: set by the build script (`build.sh`, `build-ipxe.sh`) or the `Dockerfile`.
- **Setting**: a value in [build.env](build.env); CI reads it when it builds the image.
- **Config file**: a file this repository writes and the upstream software only reads (`config.txt`, `dnsmasq.conf`, iPXE scripts).

## What is built, and for which boards

Nothing is built per individual board: no serial number, MAC address or other device data is compiled into any file. A build is per CPU architecture (iPXE) or per Raspberry Pi model family (firmware), and one build serves every board of that kind.

| Built file | One build per | Boards it serves | Why it is a separate build |
|---|---|---|---|
| iPXE `ipxe.kpxe` | CPU architecture | any x86 PC with BIOS PXE (the default file for BIOS) | BIOS needs its own boot format; this one carries iPXE's own network drivers and keeps the card's PXE ROM as fallback |
| iPXE `undionly.kpxe` | CPU architecture | x86 PCs with BIOS PXE that are listed in `IPXE_BIOS_UNDI_MACS`, or all of them with `IPXE_BIOS_FILE=undionly.kpxe` | Drives the card only through its PXE ROM (UNDI): works with every card, but much slower |
| iPXE `snponly-x86_64.efi` | CPU architecture | any x86-64 PC with UEFI PXE | UEFI program for x86-64 |
| iPXE `snponly-arm64.efi` | CPU architecture | any arm64 machine with UEFI PXE, including a Pi running the UEFI firmware | UEFI program for arm64 |
| iPXE `snponly-arm64-rpi.efi` | firmware it runs under | every Pi model under U-Boot | The arm64 UEFI program built without CPU idle sleep, because idle sleep hangs under U-Boot |
| U-Boot `u-boot-rpi3.bin` | Pi model family | Pi 3B, 3B+, CM3 | Upstream U-Boot has a separate configuration for the Pi 3 family (`rpi_3`): its SoC, Ethernet and USB differ from the other families |
| U-Boot `u-boot-rpi4.bin` | Pi model family | Pi 4B, 400, CM4 | Upstream U-Boot has a separate configuration for the Pi 4 family (`rpi_4`): its SoC, Ethernet and USB differ from the other families |
| U-Boot `u-boot-rpi5.bin` | Pi model family | Pi 5 (booted: 8 GB, revision C1). Device trees for the D0 revision, Pi 500 and CM5 are shipped; those boards are untested | Built from upstream's generic 64-bit configuration (`rpi_arm64`) with the RP1 patches, which only the Pi 5 family needs |
| UEFI `RPI_EFI.fd` for the Pi 3 | Pi model family | Pi 3B, 3B+, CM3 | EDK2 has a separate platform for the Pi 3 family |
| UEFI `RPI_EFI.fd` for the Pi 4 | Pi model family | Pi 4B, 400, CM4 | EDK2 has a separate platform for the Pi 4 family |
| UEFI `RPI_EFI.fd` for the Pi 5 | Pi model family | Pi 5 (booted: 8 GB, revision C1). The port also covers the D0 revision, Pi 500 and CM5; those boards are untested here | The Pi 5 platform is not in upstream EDK2; it is built from a different source tree |

The Raspberry Pi boot files (`start*.elf`, device trees) are downloaded, not built. Which U-Boot a Pi loads is chosen by the shared `config.txt` (`[pi3]`, `[pi4]`, `[pi5]` sections), so one TFTP root serves all models.

What is per individual board is decided when the stack runs, not at build time:

| Per-board choice | Keyed by | Where |
|---|---|---|
| UEFI firmware instead of U-Boot | the Pi's serial number | `RPI5_UEFI_SERIALS`, `RPI4_UEFI_SERIALS`, `RPI3_UEFI_SERIALS` in stacks/pxe/.env.override; the stage container then creates `<serial>/` in the TFTP root |
| What a client boots instead of the default menu | the client's MAC address | a script `ipxe/hosts/<mac>.ipxe` in the TFTP root |
| Any other firmware file for one Pi | the Pi's serial number | a hand-made `<serial>/` directory in the TFTP root |

## Pinned versions

| Upstream | Pinned at | Where |
|---|---|---|
| [iPXE](https://github.com/ipxe/ipxe) | commit `b847e5f` (master 2026-11-24; newest release v2.0.0 of 2026-03 lacks the TLS 1.3 fixes) | `IPXE_REF` in stacks/pxe/.env.override; `UEFI_IPXE_REF` in [rpi-uefi-build/.env.override](rpi-uefi-build/.env.override) for the drivers inside the UEFI firmware |
| [U-Boot](https://github.com/u-boot/u-boot) | tag `v2026.10` | [rpi-uboot-build/Dockerfile](rpi-uboot-build/Dockerfile) |
| Linux device trees of the Pis ([devicetree-rebasing](https://git.kernel.org/pub/scm/linux/kernel/git/devicetree/devicetree-rebasing.git), source of `rpi/upstream/` and of the Pi 5 UEFI trees with `UEFI_RPI5_DT=upstream`) | tag `v7.3-dts` = commit `44ab803` (Linux 7.3). Not U-Boot's copy (v2026.10 has 7.1), so the trees follow Linux releases without a U-Boot bump; v7.4 brings Pi 5 thermal, fan PWM, USB-C OTG and changes the D0 tree, so it is taken after a Pi 5 test (issue #21) | `RPI_DT_TAG`, `RPI_DT_COMMIT` in the root .env; fetched by [dts/fetch-rpi-dts.sh](dts/fetch-rpi-dts.sh) |
| EDK2 for Pi 3 and Pi 4 ([pftf/RPi4](https://github.com/pftf/RPi4) and its submodules) | commit `3db317e` | `PFTF_REF` in [rpi-uefi-build/.env.override](rpi-uefi-build/.env.override) |
| EDK2 for Pi 5 ([NumberOneGit/rpi5-uefi](https://github.com/NumberOneGit/rpi5-uefi) and its submodules) | commit `ad501cf` | `RPI5_UEFI_REF`, same file. The Pi 5 is not in upstream EDK2; this fork of the archived worproject port is itself the deviation |
| [Trusted Firmware-A](https://github.com/ARM-software/arm-trusted-firmware) (BL31, first stage of the Pi 5 UEFI image) | tag `lts-v2.14.15` = commit `28b7463`, instead of the Pi 5 port's submodule (`000fe22`, 2025-07-11, an upstream `integration` commit between v2.13 and v2.14): that one lacks upstream's `WORKAROUND_CVE_2025_10263` for `plat/rpi/rpi5` (issue #25), which the LTS line has and v2.15.0 does not. Same build flags as the port's `build.sh`. Empty `RPI5_TFA_TAG` goes back to the submodule | `RPI5_TFA_TAG`, `RPI5_TFA_COMMIT` in [rpi-uefi-build/.env.override](rpi-uefi-build/.env.override); fetched by the [Dockerfile](rpi-uefi-build/Dockerfile) |
| [Raspberry Pi firmware](https://github.com/raspberrypi/firmware) (`start*.elf`, device trees) | commit `d131b57` | `FIRMWARE_VERSION` (U-Boot stack), `START_ELF_VERSION`, `DTB_VERSION`, `DTBO_VERSION` (UEFI stack) |
| [nfs-ganesha](https://github.com/nfs-ganesha/nfs-ganesha) (image built here, optional service) | not pinned: Debian's `trixie-backports` package when the image is built (9.14-1~bpo13+1 on 2026-11-24; trixie itself has 6.5, see "nfs-ganesha (nfs service)"); the image prints its version at start | [nfs-build/Dockerfile](nfs-build/Dockerfile) |
| [tgt](https://github.com/fujita/tgt) (image built here, optional service) | not pinned: Debian trixie's package when the image is built (1.0.85-1.3 on 2026-11-24); the image prints its version at start | [iscsi-build/Dockerfile](iscsi-build/Dockerfile) |
| [Debian cloud image](https://cloud.debian.org/images/cloud/) (`debian-13-generic-amd64`, base of the iSCSI example disk) | not pinned: `trixie/latest` when [get-debian-iscsi-disk.sh](iscsi-build/get-debian-iscsi-disk.sh) runs, checked against the `SHA512SUMS` next to it (Debian publishes no signature for it) | [iscsi-build/get-debian-iscsi-disk.sh](iscsi-build/get-debian-iscsi-disk.sh) |
| [netboot.xyz](https://netboot.xyz) | not pinned: the menu is loaded from `boot.netboot.xyz` at boot | [netbootxyz.ipxe](ipxe-build/tftp/ipxe/netbootxyz.ipxe) |

## iPXE (ipxe-build)

Three source patches, described in [ipxe-build/patches/README.md](ipxe-build/patches/README.md); the rest is build options and settings.

| What differs | Why | How |
|---|---|---|
| Extra protocols and commands: HTTPS, FTP, NFS, `file:`, `imgverify`, gzip/zlib images, `ping`, `nslookup`, `ntp`, `reboot`, `poweroff`, VLAN, `digest` | netboot.xyz needs HTTPS and image verification; the rest is for boot scripts and debugging | Build option, [build-ipxe.sh](ipxe-build/build-ipxe.sh); table in the pxe README, "Compiled-in iPXE features" |
| No OCSP check of TLS certificates | A boot must not fail because an OCSP server cannot be reached | Build option, same script |
| iPXE's own serial console in BIOS builds (upstream: off in every build) | Headless BIOS clients are driven over a serial cable. UEFI builds leave it off, as upstream does: UEFI firmware that redirects its console to serial already carries iPXE's output, and with both on every character came twice (QEMU OVMF, 2026-11-20) | Setting `IPXE_SERIAL_CONSOLE` (`bios` default, `efi`, `all`, `off` = upstream) |
| Trusted roots: iPXE's root CA and the netboot.xyz CA (upstream: iPXE's root CA only, replaceable at run time) | netboot.xyz signs its menu scripts with its own CA and checks them by default; without it every submenu fails with `Could not verify` (seen 2026-11-20 on the Pi 5 and in QEMU). netboot.xyz's own iPXE trusts the same two. The netboot.xyz CA is then also trusted for HTTPS | Setting `IPXE_TRUST_NETBOOTXYZ` (`1` default, `0` = upstream); certificates in `ipxe-build/certs/`, fingerprints pinned in `build-ipxe.sh` |
| Signature check of one netboot.xyz file before the menu | A changed netboot.xyz CA would make every submenu fail; the check says so on screen with the steps to switch signature checks off in the menu, and logs `ipxe/log/netbootxyz-signature-check-failed-...` in dnsmasq | Config file, [netbootxyz.ipxe](ipxe-build/tftp/ipxe/netbootxyz.ipxe) |
| Product name `iPXE-mod`, sent as DHCP user class, and a build label in the version | dnsmasq must tell this iPXE from a ROM or stock iPXE to answer with the menu instead of the binary again | Setting `IPXE_PRODUCT_NAME`, `IPXE_BUILD_TAG` |
| An embedded start script instead of iPXE's built-in autoboot | Takes the boot server and boot file from the ProxyDHCP answer, or from the DHCP server itself when there is no ProxyDHCP server, sets the clock (a Pi has none and HTTPS needs it), chains `boot.ipxe`, and leaves with a failure status so UEFI firmware goes on to its next boot option | Config file, [autoexec.ipxe](ipxe-build/autoexec.ipxe) |
| IPv4 only by default | iPXE's `dhcp` also waits for an IPv6 router; without one that costs about 4 s per boot | Setting `IPXE_IPV6` (`0` default, `1` = stock behaviour) |
| A second arm64 binary, `snponly-arm64-rpi.efi`, without CPU idle sleep | Under U-Boot nothing wakes the CPU again, and the menu freezes on a Pi | Build option (`NAP_NULL`), same script |
| BIOS clients get `ipxe.kpxe` (iPXE's own drivers, UNDI fallback) instead of `undionly.kpxe` | iPXE's chainloading guide uses `undionly.kpxe`, which drives the card through its PXE ROM. In the x86 BIOS VM (2026-11-25, iPXE `b847e5f`) that was 13 to 23 times slower over HTTP (539 MB: 112-116 s against 5-9 s) and NixOS was up after 140 s against 26 s. netboot.xyz also defaults to `ipxe.kpxe`. A card iPXE has no driver for falls back to UNDI inside `ipxe.kpxe`; a card whose iPXE driver misbehaves is listed in `IPXE_BIOS_UNDI_MACS` | Build of `bin/ipxe.kpxe` in [build-ipxe.sh](ipxe-build/build-ipxe.sh) (fails above 480 KB), settings `IPXE_BIOS_FILE`, `IPXE_BIOS_UNDI_MACS` ([stage.sh](ipxe-build/stage.sh), [dnsmasq.conf](ipxe-build/dnsmasq.conf)) |
| Extra variants and boot media are not built | Not needed by the stack | Settings `BUILD_EXTRA_IPXE_ARTIFACTS`, `BUILD_OPTIONAL_IPXE_MEDIA` |
| A tree loaded with `fdt` gets the firmware tree's `local-mac-address` (alias `ethernet0`) and loses `stdout-path` when the firmware tree has none | Upstream passes a loaded tree unchanged: on a Pi 4 Linux then used a random MAC (lost DHCP reservation, Matchbox group, host script), and the firmware's console choice did not apply | Patch [ipxe-build/patches/0001](ipxe-build/patches/README.md) |
| A tree loaded with `fdt` is passed through the firmware's EFI Device Tree Fixup Protocol (U-Boot) | Upstream never calls it; systemd-boot and other EFI loaders do. U-Boot then applies its own fixups (MAC, board revision, memory, console rule `0007`) to that tree | Patch [ipxe-build/patches/0002](ipxe-build/patches/README.md) |
| An `nfs://` download sends its first LOOKUP only once the NFS connection is open | Upstream sends it as soon as the MOUNT reply arrives; when that reply comes before the portmapper's answer for the NFS port, the LOOKUP goes into an unconnected interface and the download fails with `0x420e2001` (issue #6). A slow portmapper reply triggers it every time | Patch [ipxe-build/patches/0003](ipxe-build/patches/README.md) |

## iPXE as a driver inside the UEFI firmware (rpi-uefi-build)

Details: [rpi-uefi-build/patches/README.md](rpi-uefi-build/patches/README.md).

| What differs | Why | How |
|---|---|---|
| iPXE built as a UEFI driver with only the Pi 3 USB Ethernet drivers, on the firmware's USB stack | EDK2 has no driver for the Pi 3's Ethernet chip | Build option, [Dockerfile](rpi-uefi-build/Dockerfile) |
| Receive path polls the chip only when no packet is queued | Downloads through the Pi 3 driver were three times slower | Patch `ipxe/0001` |
| New driver for the Pi 5's Ethernet (Cadence GEM in the RP1 chip), `rp1gem` | iPXE knows this controller only on device-tree boards, not behind PCIe under UEFI | Patch `ipxe/0002` |
| Opening the device waits up to 5 s for the link | The firmware's PXE and HTTP boot check the link once, right after opening the device, and give up silently while it is still negotiating (the firmware's start renegotiates it on the Pi 5) | Patch `ipxe/0003` |
| Receive ring of the Pi 5 Ethernet driver (`cgem`) 64 descriptors instead of 8 | With 8 the ring overflowed on TCP bursts: downloads under UEFI ran at 0.2 to 0.9 MB/s, with 64 at about 30 MB/s | Patch `ipxe/0004` |
| The driver offers no boot option of its own (`EFI_DOWNGRADE_UX`); the firmware's own PXE client is the only PXE boot option | Upstream's driver adds a "UEFI PXEv4 (MAC:...)" option that runs iPXE inside the firmware, beside the firmware's own "UEFI PXEv4 ... 2": after iPXE handed back, the second one started iPXE and the menu again, before any local disk; and iPXE inside the firmware is not wanted as the boot path | Build option, [Dockerfile](rpi-uefi-build/Dockerfile) |

## U-Boot (rpi-uboot-build)

Details: [rpi-uboot-build/patches/README.md](rpi-uboot-build/patches/README.md) and [README.md](rpi-uboot-build/README.md).

| Applies to | What differs | Why | How |
|---|---|---|---|
| all | Pi 4 Ethernet: `ID_MODE_DIS` cleared for `rgmii-rxid` | Every transmitted frame was dropped at 1 Gbit/s, so DHCP never got an answer | Patch `0001`; analysis in [GENET-TX-FIX.md](rpi-uboot-build/GENET-TX-FIX.md) |
| all | `discovered_ram_size` moved out of the area the relocation table uses | v2026.10 corrupts one of its own pointers at start; on the Pi 5 that crashed iPXE. Drop when upstream fixes it | Patch `0002` |
| all | The SD controller wired to the WiFi chip is not scanned for a card | Cost 3.3 s on every Pi 4 boot | Patch `0003` |
| all | PL011 serial driver drops characters received with an error flag | The Pi 5 firmware leaves a break character in the UART; U-Boot took it for a key and stopped at its prompt. The Pi 3's console is the same driver; the Pi 4's is the mini UART and is not affected | Patch `0005` |
| all | Pi 3 SD driver forgets a command that failed | Without it every probe of an empty card slot printed `WARNING at drivers/mmc/bcm2835_sdhost.c:414` lines; upstream bug, Linux clears the request | Patch `0006` |
| Pi 5 | Support for the RP1 chip: its clock, GPIO, pins, Ethernet, the board start-up code, defconfig | Upstream has no RP1 driver, so no network and no USB on a Pi 5. Not ours: from siderolabs/sbc-raspberrypi PR 88, rebased to v2026.10. Drop when upstream supports the Pi 5's Ethernet | Patches `rpi5/0001` to `rpi5/0014` (nine files left after the rebase) |
| Pi 5 | Ethernet PHY reset and set up once, not at every interface start | iPXE lost the ProxyDHCP answer in about half of the boots | Patch `rpi5/0015` |
| Pi 5 | Second console on GPIO 14/15 | Same serial cable as Pi 3 and Pi 4; upstream prints only on the 3-pin debug connector | Patch `rpi5/0017` |
| Pi 5 | Ethernet negotiation starts when the device is found | 4 s faster to iPXE | Patch `rpi5/0018` |
| Pi 5 | Output from before the GPIO console existed is replayed on it, between marker lines | The RP1 UART is unreachable until PCIe is up | Patch `rpi5/0019` |
| Pi 5 | EFI programs (iPXE, the kernel it starts) may use RAM below 4 GB, not only the first 1 GB; DRAM below 4 GB mapped; `LMB_ARCH_MEM_MAP` on with `BCM2712` | Upstream reserves all RAM above the first bank; Flatcar's 363 MB initrd failed with EFI out of resources. Every BCM2712 DMA master reaches 4 GB | Patch `rpi5/0020` |
| Pi 5 | Optional: iPXE (and the kernel it starts) gets the upstream Linux device tree from `rpi/upstream/` instead of the firmware's | Off by default since 2026-11-23 (rule R3: every Pi hands over the firmware's tree, an OS that needs another loads it by `FdtFile`); for OS boots that cannot load a tree themselves, since distribution kernels find no Ethernet or USB with Raspberry Pi's | Setting `UBOOT_RPI5_EFI_FDT` (`firmware` default = upstream U-Boot's behaviour, `upstream`); trees built by [dts/build-rpi-upstream.sh](dts/build-rpi-upstream.sh) |
| Pi 5 | The upstream trees get a node for the RP1's UART0 (GPIO 14/15, `arm,sbsa-uart`, enabled as upstream's Pi 3/4 trees ship their console UART), aliases `serial0`/`uart0`, `stdout-path = "serial0:115200n8"`, the firmware's `uart0`/`uart0_console` parameters, and symbols (`dtc -@`) | Upstream has no RP1 UART node (Linux 7.3 and 7.4-rc4, 2026-11-25): no Linux console on the GPIO pins. The build fails once upstream adds one | [dts/rp1-uart0.dtsi](dts/rp1-uart0.dtsi), shared with rpi-uefi-build ([dts/README.md](dts/README.md)) |
| Pi 5 | In an upstream tree U-Boot hands over: the UART0 node enabled and alias `console` added when the firmware's tree has its UART0 enabled (`enable_uart=1`) | The Pi firmware never sees that tree, so it cannot apply `enable_uart=1` | Patch `rpi5/0021` |
| Pi 5 | In Raspberry Pi's own tree (the default): `stdout-path` changed from `serial10:115200n8` (debug connector) to `serial0:115200n8` (GPIO 14/15) when the firmware's UART0 is enabled | Raspberry Pi's Pi 3 and Pi 4 trees name `serial0`, the GPIO UART; the Pi 5 tree names the debug connector, so the OS console was on other pins than on every other Pi (Alpine `linux-rpi`: `ttyAMA10`). Raspberry Pi OS gets the same with `console=serial0` on its command line; a tree handed over through EFI must say it itself. The display rule (`0007`) still applies | Patch `rpi5/0021` |
| all | In every tree U-Boot hands to an EFI program: `/chosen/stdout-path` removed when a display is present (video device up), unless the environment variable `console_main` is `serial` (from `CONSOLE_MAIN` in the root `.env`, default `auto`) | Platform rule R2: the same OS console choice on every Pi and under both firmwares; EDK2's ConsolePrefDxe removes it the same way. Upstream U-Boot keeps `stdout-path`, so Linux stayed on serial with a display. Precedent upstream: Apple boards change `stdout-path` in `ft_board_setup` by console devices (`arch/arm/mach-apple/board.c`) | Patch `0007`, setting `CONSOLE_MAIN` |
| all | Boot server taken from the ProxyDHCP answer; classic network stack instead of lwIP on the Pi 5 | On this stack's kind of network the router only hands out addresses and dnsmasq names the boot server; without the option U-Boot asks the router for the iPXE file. lwIP cannot do it | Build option (`SERVERIP_FROM_PROXYDHCP`, `NET_LEGACY`), [build.sh](rpi-uboot-build/build.sh) |
| all | Without a ProxyDHCP answer, the boot server is taken from the DHCP server's own answer | With the option above, upstream ignores the DHCP server's boot server, so the build would only work behind a ProxyDHCP server | Patch `0004` |
| all | PXE client architecture 11 (arm64 UEFI), host name sent, Broadcom PHY driver | dnsmasq selects the arm64 iPXE binary by architecture 11; the Pi 5 default is another value | Build option |
| all | USB host, xHCI and USB keyboard drivers | A USB keyboard must work in iPXE and its menu | Build option |
| all | UEFI variable `FdtFile` (own vendor GUID) with U-Boot's `${fdtfile}`, set before every boot; `env set -e` built in (`CMD_NVEDIT_EFI`) | Lets a loader pick the upstream Linux tree an OS needs (`fdt` in iPXE) while the firmware keeps handing over its own tree (rule R3). No convention for this exists (systemd-boot matches the tree's `compatible` instead); rpi-uefi-build publishes the same variable | Build option and compiled-in boot command (`fdtvar`) |
| all | 16-bit framebuffer text | The Pi 5 firmware hands over 16 bits per pixel; without it all text is black on black | Build option (`VIDEO_BPP16`) |
| all | Compiled-in boot commands: DHCP, fetch iPXE over TFTP, start it; when that fails or iPXE returns, upstream's standard boot of the local devices (SD card, USB, on the Pi 5 NVMe; list and order settable with `UBOOT_LOCAL_BOOT_ORDER`); when nothing boots, wait 10 s and reset. Upstream tries the local devices first and the network after them, and stops at its prompt when nothing boots | The network boot comes first, because a disk with an old OS would otherwise always win; the local devices come next, so netboot.xyz's "Boot from local hdd" and a Pi without a boot server still boot a disk; a headless Pi with nothing to boot must retry by itself instead of waiting at a prompt | Build option (generated environment) |
| all | Version string `2026.10-pxe-<commit>` | Shows which build a board runs; without it U-Boot says `-dirty` | Build option |

## EDK2 UEFI firmware (rpi-uefi-build)

Details: [rpi-uefi-build/patches/README.md](rpi-uefi-build/patches/README.md) and [README.md](rpi-uefi-build/README.md).

| Applies to | What differs | Why | How |
|---|---|---|---|
| all | When nothing boots: wait 10 s for a key, then reset | Upstream waits for a key for ever; a headless Pi then never recovers | Patch `common/0001` |
| all | Boot options sorted every boot: PXE, then local disks, then HTTP boot, then setup and shell | Upstream keeps the creation order, which put HTTP boot before the disks; "Boot from local hdd" then waited a minute for an HTTP boot server this stack does not have | Patch `common/0002` |
| all | UEFI variable `FdtFile` (vendor GUID `eedf58fc-1b9b-4ab0-8b6b-954d79d6b052`, boot services only) with the path of the board's upstream Linux device tree (`broadcom/bcm2711-rpi-4-b.dtb`, ...), set at ReadyToBoot in every system table mode | The same variable U-Boot publishes (rule R3): a loader (iPXE `fdt`) loads the tree an OS needs while the firmware keeps handing over its own tree or ACPI. Names as in U-Boot's `fdtfile` table | Patch `common/0003` |
| Pi 3 | iPXE Ethernet driver embedded; boot manager policy driver added | The Pi 3 platform cannot network boot from its onboard Ethernet without them | Patch `rpi3/0001` |
| Pi 4 | MAC address read back from the Ethernet controller when the firmware reports all zeros | Safety net for boards that report no MAC | Patch `rpi4/0001` |
| Pi 4 | `PcdFdtSize` 128 KB instead of the 64 KB default | Upstream's own `config.txt` gives the device tree 0x3e0000 to 0x400000, but EDK2 mapped only the first 64 KB; the Pi 4 tree is 56 KB before overlays. Same value as the Pi 5 port | Patch `rpi4/0002` |
| Pi 5 | iPXE Ethernet driver embedded; the board's MAC written into the controller | The Pi 5 port has no Ethernet driver | Patch `rpi5/0001` |
| Pi 5 | Console on GPIO 14/15 (new serial driver), RP1 started before the consoles | Same serial cable as the other models | Patch `rpi5/0002` |
| Pi 5 | Diagnostics also on GPIO 14/15, with a replay of what was printed before that port existed (new serial port library, 64 KiB of RAM reserved at `0x400000`) | One cable shows everything, as on the other models; upstream prints diagnostics only on the debug connector | Patch `rpi5/0003` |
| Pi 5 | Boot messages of Trusted Firmware-A are recorded for the same replay; the UEFI side keeps a record that was started that way | Trusted Firmware-A prints only on the debug connector and runs before UEFI | Patch `rpi5-tfa/0001` (Trusted Firmware-A) and patch `rpi5/0004` (EDK2) |
| Pi 5 | In Raspberry Pi's own tree: `stdout-path` changed from `serial10:115200n8` to `serial0:115200n8` (GPIO 14/15) when the GPIO UART is enabled | Same rule as U-Boot's `rpi5/0021`: the OS console on the same pins as on the Pi 3 and Pi 4. ConsolePrefDxe still removes `stdout-path` with a display unless `CONSOLE_MAIN=serial` | Patch `rpi5/0005` |
| all | No Secure Boot; TFTP shell command, iSCSI, HTTP boot without TLS | The iPXE binaries are unsigned; iPXE does HTTPS itself | Build option, [build.sh](rpi-uefi-build/build.sh) |
| all | No IPv6 network stack by default, so no PXE over IPv6 and no HTTP boot over IPv6 | Without an IPv6 router each of the two options waits about a minute before the firmware moves on, for example to a USB disk after iPXE hands back (measured on a Pi 5: 3 min 12 s from iPXE leaving to the disk with them) | Setting `UEFI_IPV6` (`0`; `1` = upstream) |
| all | Default build prints errors and warnings, asserts do not halt | Diagnostics without the cost of a debug build | Setting `UEFI_BUILD_TYPE` (`warn`) |
| Pi 4, Pi 5 (the Pi 3 platform has no `ConsolePrefDxe`, so its serial console is always kept, as with `serial`) | Console preference default (EmbeddedPkg `ConsolePrefDxe`) from `CONSOLE_MAIN`: `auto` = graphical, the upstream default (with a display connected the driver removes `stdout-path` and the SPCR table, so the display is the OS's main console); `serial` = serial (both kept, serial main, display second). No `hdmi_force_hotplug` on the Pi 3 and Pi 4 (removed 2026-11-22): with it the firmware made a display even with none connected, so the driver always removed the serial console | Rule R2 (`docs/proposals/platform-consistency.html`): the firmware describes the serial console, the deployment chooses the main one. The variable is never saved when the firmware comes over TFTP, so its default decides | Setting `CONSOLE_MAIN` in the root `.env` (`auto`) |
| all | Defaults of firmware settings set at build time: boot prompt 2 s, system table mode, full RAM on the Pi 4 | Settings changed in the menu do not survive a reboot when the firmware comes over TFTP | Settings `UEFI_BOOT_TIMEOUT`, `UEFI_SYSTEM_TABLE`, `UEFI_RAM_LIMIT_3GB` |
| Pi 4 | System table mode `both` (ACPI and device tree) instead of the port's `acpi`; the Pi 3's default is already `both` | Raspberry Pi kernels (Alpine `linux-rpi`, Raspberry Pi OS) need a device tree and panic with ACPI only; with `both` arm64 Linux uses the tree, distribution kernels too (Fedora CoreOS tested). Same mode as the Pi 5 | Setting `UEFI_SYSTEM_TABLE` (`both`; `upstream` = each model's default) |
| Pi 5 | System table mode `both` (ACPI and device tree) instead of the port's `acpi` | With a complete device tree arm64 Linux uses it, and only the tree gives a distribution kernel Ethernet behind RP1 and the GPIO console | Setting `UEFI_SYSTEM_TABLE`, shared with the Pi 3 and Pi 4 (`both`; `upstream` = the port's default) |
| Pi 5 B | Optional: the firmware loads the upstream Linux trees with the RP1's UART0 (`bcm2712-rpi-5-b.dtb`, `bcm2712-d-rpi-5-b.dtb`, and the D0 tree also as `bcm2712d0-rpi-5-b.dtb`) instead of Raspberry Pi's; CM5 and Pi 500 keep Raspberry Pi's | Off by default since 2026-11-23 (rule R3); for OS boots that cannot load a tree themselves | Setting `UEFI_RPI5_DT` (`firmware` default = Raspberry Pi's trees, `upstream`); trees from [dts/](dts/README.md) |

## Raspberry Pi firmware configuration (`config.txt`)

Written by the two build scripts; the boot files themselves are unchanged. Under UEFI the Pi 4 and Pi 5 files start from the port's own `config.txt` in the pinned source, read at build time (pftf/RPi4 `config.txt`, NumberOneGit/rpi5-uefi `config.txt`), with the device tree addresses replaced and our lines added; the Pi 3 file is written by `build.sh` (the pinned source ships none for it).

| Applies to | Line | Why |
|---|---|---|
| all, both firmwares | `enable_uart=1` | Serial console. On a Pi 5 it also makes the firmware name the UART on GPIO 14/15 `serial0`, which is the condition for the GPIO console in U-Boot and UEFI |
| Pi 3, Pi 4 | `uart_2ndstage=1` | The Pi firmware's own messages on serial |
| Pi 3 | `dtoverlay=miniuart-bt` | Puts the full UART on the GPIO pins instead of Bluetooth |
| U-Boot | `kernel=u-boot.bin`, `arm_64bit=1`, `framebuffer_swap=0` (Pi 3, Pi 4) | Start U-Boot as the 64-bit kernel; correct colours |
| U-Boot Pi 5 | `dtoverlay=vc4-kms-v3d-pi5` (and the overlay file) | With Raspberry Pi's tree (the default since 2026-11-23) Raspberry Pi's kernel has no display without it: no framebuffer, no DRM device (Alpine 3.24 `linux-rpi`, 2026-11-23); with it the kernel log and login show on HDMI. Raspberry Pi OS sets the generic `dtoverlay=vc4-kms-v3d` on every board, which the firmware maps to this file through `overlays/overlay_map.dtb`; the explicit name needs no map file and leaves the Pi 3 and Pi 4 unchanged. No effect on a tree loaded with `fdt` or on U-Boot's own output |
| UEFI | `armstub=RPI_EFI.fd`, `device_tree_address`, `device_tree_end` | Start the UEFI firmware. The two addresses are read at build time from `PcdFdtBaseAddress` and `PcdFdtSize` of the source being built (the platform's `.dsc`, else `RaspberryPi.dec`): Pi 3 0x1f0000 to 0x200000, Pi 4 and Pi 5 0x3e0000 to 0x400000 (Pi 4 through patch `rpi4/0002`). Until 2026-11-22 the Pi 4's were written as 0x1f0000, the address before upstream enlarged its firmware image (edk2-platforms `991b802e8f`, 2024-09); the Pi firmware then put the device tree inside the UEFI image and EDK2 found none, so a Pi 4 never got a device tree under UEFI. pftf/RPi4's own file ends the Pi 4 tree at 0x400000 (and so does a comment in its `RPi4.dsc`), but its `PcdFdtSize` is the 64 KB default: EDK2 maps only 0x3e0000 to 0x3f0000 and copies the tree from there (`FdtDxe`), so a tree reaching past 0x3f0000 would be read from unmapped memory. Patch `rpi4/0002` sets `PcdFdtSize` to 128 KB, so EDK2's mapping and upstream's `config.txt` now agree |
| UEFI Pi 4 | `enable_gic=1`, `arm_boost=1`, `disable_commandline_tags=1`, `dtoverlay=upstream-pi4` | Upstream's: the lines of pftf/RPi4's own `config.txt`, taken unchanged |
| all, both firmwares | `tryboot.txt`, a copy of `config.txt` | After `reboot '0 tryboot'` (Ubuntu's piboot-try after a kernel update, rpi-eeprom) a Pi 4 or Pi 5 reads `tryboot.txt` instead of `config.txt`; without it over the network the Pi 5 asked for it again and again and never booted (2026-11-25) |
| UEFI Pi 5 | `usb_max_current_enable=1`, `force_turbo=1`, `framebuffer_depth=32` | Upstream's: the lines of the Pi 5 port's own `config.txt`, taken unchanged; `enable_uart=1` is added |

## Does it depend on ProxyDHCP?

The pxe stack itself is a ProxyDHCP server: that is its design, so that the router stays the DHCP server. The files it builds do not require one:

| Stage | With ProxyDHCP (this stack) | With one DHCP server that also names the boot server |
|---|---|---|
| Pi boot ROM / bootloader, PC firmware | standard PXE | standard PXE |
| U-Boot | boot server from the ProxyDHCP answer | boot server from the DHCP answer (patch `0004`); it asks that server for `ipxe/snponly-arm64-rpi.efi` |
| iPXE embedded script | boot server and chain target from the ProxyDHCP answer | from the DHCP answer (`next-server`, `filename`); the server has to tell this iPXE (user class `iPXE-mod`) apart and give it a script, as for any iPXE chainloading setup |
| UEFI firmware's own PXE | standard PXE | standard PXE |

Only the ProxyDHCP column is tested; the lab has no network of the other kind.

## nfs-ganesha (nfs service)

No patches; Debian's package from `trixie-backports` with a config written by [start.sh](nfs-build/start.sh). Settings that differ from Ganesha's defaults or from a plain container:

| What differs | Why | How |
|---|---|---|
| Ganesha 9.14 from `trixie-backports` instead of trixie's 6.5 | Ganesha 6.5 answers the NFSv4.1 operation GET_DIR_DELEGATION with OP_ILLEGAL. Linux 6.19 and newer ask for directory delegations by default and turn that answer into "Remote I/O error" on directory lookups: Ubuntu 26.04 (kernel 7.0) could not boot from an NFSv4 root (`Failed to write /etc/machine-id: Remote I/O error`, issue #2). Fixed upstream in V7.0 (commit 98eb77c). Tested 2026-11-24 in the UEFI VM: Ubuntu over NFSv4.2 boots with 9.14 and fails with 6.5; Debian over NFSv3 still boots. The rows below were found with 6.5 and are kept, not retested with 9.14 | [Dockerfile](nfs-build/Dockerfile) |
| Owners as numbers only (`Only_Numeric_Owners`) | A root file system has groups the server's container does not know; by name they arrive as `nobody` and system services in the root fail | Config |
| No grace period (`Graceless`) | The service restarts with dnsmasq; a client with its root on NFS must not wait 90 s for it | Config |
| No NFSv3 lock manager (`Enable_NLM = false`) | It needs statd, which is not in the container; NFS roots mount with `nolock` | Config |
| TCP only (`Enable_UDP = false`, `Transports = TCP`) | One UDP request (a Linux client's first try at the NFSv3 mount service) makes Ganesha 6.5 log "svc_dg_rendezvous: Bad message sa_family is 0xffff" about 4000 times a second without end, with over one CPU core busy; Linux, the initramfs NFS client and iPXE use TCP | Config |
| NFSv3 clients mount by the NFSv4 path (`Mount_Path_Pseudo`) | One path per export for every client: `/rw/...`, `/ro/...` | Config |
| No cache of directory contents and file attributes (`Dir_Chunk = 0`, `Attr_Expiration_Time = 0`) | The roots are also changed on the boot host, not only through the server (`nfs-root`, the `get-*-root.sh` scripts). With Ganesha's cache a root that was deleted and made again was served as the old, empty one for minutes, and iPXE found no kernel in it (2026-11-23) | Config |
| Open-file limit 4096 (Docker default: about a million) | With the default, Ganesha 6.5's RPC library fails ("fd 1024 hook failed") and nothing listens | `ulimits` in docker-compose.yml |
| Capabilities `DAC_READ_SEARCH`, `SYS_ADMIN`, `SYS_RESOURCE` instead of `--privileged` | The least Ganesha's VFS back end starts with; without `SYS_RESOURCE` Ganesha 6.5 stops | `cap_add` in docker-compose.yml |

## tgt (iscsi service)

No patches; Debian's package, no `targets.conf`: [iscsi-disk](iscsi-build/iscsi-disk) makes the targets with `tgtadm` from the files in `dockerdata/pxe/iscsi/disks/`, at every start ([start.sh](iscsi-build/start.sh)) and when a disk is made. The container is not privileged and has no added capabilities; tgtd logs at start that it cannot set its OOM score and open-file limit and that RDMA (iSER) is missing, which does not matter here. Settings that differ from tgt's defaults:

| What differs | Why | How |
|---|---|---|
| One target per disk, named `<ISCSI_IQN>:<file name>`, the disk at LUN 1; target ids are allocated at run time | A machine names its disk; the name stays when ids change. LUN 0 is tgt's controller: iPXE's default LUN 0 fails with an input/output error (2026-11-23), so root paths say LUN 1 | `iscsi-disk` |
| Access for `ISCSI_CLIENTS` or `LAN_SUBNET` (tgt's ACL by address or network), not `ALL`; no CHAP | As for the NFS service: the LAN only, no passwords in the first version. A target the initiator may not use is not listed and its login fails ("Target not found"), tested 2026-11-24. `iscsi-disk` checks that each entry is an address or network: tgt takes any text and then lets nobody in | `tgtadm --op bind` |
| SCSI serial number and device ID from the disk's name (`scsi_sn`, `scsi_id`) | tgt derives them from the target id, which changes when disks come and go; an OS that identifies disks by serial (Windows, `/dev/disk/by-id`) would see another disk after a restart | `tgtadm --params` |
| Thin provisioning on (`thin_provisioning=1`) | The disk files are sparse: blocks the machine discards (TRIM, `fstrim`) become holes in the file again instead of staying used on the boot host (tested 2026-11-24: discarding 512 MB of a copied Debian disk freed 312 MB of the file) | `tgtadm --params` |
| Pings every 15 s, connection closed after 4 unanswered (`nop_interval=15`, `nop_count=4`; tgt: off) | Without them a machine that was switched off, and the session iPXE leaves behind when the OS takes over, stay connected for over half an hour (TCP keepalive), and `iscsi-disk delete`/`reset` refuse. Tested 2026-11-24 with a frozen initiator: closed 71 s after it stopped answering. iPXE does not answer pings (`iscsi_rx_nop_in` ignores them); its session closes after a minute and iPXE opens a new one if it still needs the disk (`sandev_reopen` in `sanboot.c`; read in the source, not yet seen in a boot) | `tgtadm --op update --mode target` |

## netboot.xyz

| What differs | Why | How |
|---|---|---|
| iPXE reports netboot.xyz's current release number as its own version before loading the menu | Otherwise the menu replaces a "foreign" iPXE with its own x86 binary: on arm64 that fails, on x86 it throws this build away | Config file, [netbootxyz.ipxe](ipxe-build/tftp/ipxe/netbootxyz.ipxe) |
| A failed or ended menu is retried, then iPXE leaves with a failure status | A client that boots nothing must start over by itself | Config file, [boot.ipxe](ipxe-build/tftp/ipxe/boot.ipxe) |
| `custom_url` set to this stack's `ipxe/custom/` before the menu loads | Puts this stack's own menu (Fedora CoreOS) into the netboot.xyz main menu as "Custom URL Menu"; netboot.xyz chains `${custom_url}/custom.ipxe` without a signature check | Config file, [netbootxyz.ipxe](ipxe-build/tftp/ipxe/netbootxyz.ipxe); menu in [custom.ipxe](coreos-build/tftp/ipxe/custom/custom.ipxe) |

## Fedora CoreOS (coreos-stage)

Kernel, initramfs and root file system are Fedora's unmodified live PXE files, loaded over HTTPS from `builds.coreos.fedoraproject.org`. What this stack adds:

| What differs | Why | How |
|---|---|---|
| Extra initrd with `rp1_pci.ko` and regenerated module lists, on aarch64, plus `rd.driver.pre=rp1_pci` | The live initramfs lacks `rp1_pci` (dracut-ng's arm driver list has no `drivers/misc`), so a Pi 5 gets no network and never fetches its root file system. One archive per release (it replaces that initramfs's module lists); kept for the last six stable releases. Dropped automatically for a release whose initramfs has the module | Build script, [build-extra-initrd.sh](coreos-build/build-extra-initrd.sh); [dracut-rp1-bug-report.md](coreos-build/dracut-rp1-bug-report.md) |
| Ignition config handed over as `/config.ign` inside an iPXE initrd instead of `ignition.config.url` | Ignition does not retry a TFTP URL, and on a Pi 5 the network comes up after its first try (emergency mode in two of three tests, 2026-11-21) | Config file, [fcos.ipxe](coreos-build/tftp/ipxe/fcos.ipxe) |
| No `console=` argument | On a Pi 5 the device tree picks the console (GPIO serial without a display, the display otherwise); a fixed argument would override that | Same file; `fcos_kargs` adds one per machine |
| Release followed: newest stable, checked daily | "stable" was chosen; the image changes only when a new release appears | [build-coreos.yml](.github/workflows/build-coreos.yml), [assemble.sh](coreos-build/assemble.sh) |

