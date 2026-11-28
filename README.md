# pxe-builds

Ready-made network boot files for x86 PCs and Raspberry Pi 3, 4 and 5, built from pinned upstream sources with the fixes they need, and shipped as container images:

- **iPXE** for x86 BIOS, x86-64 UEFI and arm64 UEFI, with the netboot.xyz menu working on arm64 as well as x86.
- **U-Boot** and **EDK2 UEFI firmware** for the Raspberry Pi 3, 4 and 5 that boot over the network out of the box, including the Pi 5's Ethernet, which upstream U-Boot and the Pi 5 UEFI port do not drive.
- **Upstream Linux device trees** for the Pis, with the GPIO serial port upstream lacks on the Pi 5.
- **Fedora CoreOS** network boot scripts, including the extra initrd a Pi 5 needs to find its network.
- **NFS** (nfs-ganesha) and **iSCSI** (tgt) servers in user space, for diskless machines and network disks, and an **SMB** server (Samba) for installation media.

Every image is built in GitHub Actions from this repository. Nothing has to be compiled on the machine that serves the files: a TFTP server (dnsmasq, for example) only needs the files copied into its root, and the "stage" images do exactly that when they start.

## Images

All images are public: `ghcr.io/vholck/pxe-builds/<name>`, tagged with the commit they were built from and `latest` (CoreOS: a hash of its content).

| Image | Built from | What it does when it runs |
|---|---|---|
| `ipxe-build` | [ipxe-build/](ipxe-build/) | Copies the iPXE binaries and boot scripts into the TFTP root (`ipxe/`) and renders a `dnsmasq.conf` for ProxyDHCP into `/config` |
| `rpi-uboot` | [rpi-uboot-build/](rpi-uboot-build/), [dts/](dts/) | Copies the Raspberry Pi boot files, one shared `config.txt` and U-Boot for Pi 3, 4 and 5 into the TFTP root; every Pi boots it without per-board setup |
| `rpi-uefi` | [rpi-uefi-build/](rpi-uefi-build/), [dts/](dts/) | Creates a `<serial>/` directory with the UEFI firmware for each Pi listed in `RPI3_UEFI_SERIALS`, `RPI4_UEFI_SERIALS`, `RPI5_UEFI_SERIALS`; those Pis boot UEFI instead of U-Boot |
| `coreos` | [coreos-build/](coreos-build/) | Copies the Fedora CoreOS boot scripts and the Pi 5 extra initrds for the last six stable releases; rebuilt daily |
| `nfs` | [nfs-build/](nfs-build/) | Runs nfs-ganesha for root file systems on NFS, with a helper for per-machine copies |
| `iscsi` | [iscsi-build/](iscsi-build/) | Runs tgt with one target per disk image, with a helper to make, copy and reset disks |
| `smb` | [smb-build/](smb-build/) | Runs Samba with one read-only share for installation media, for Windows Setup started from Windows PE over the network |

A stage image deletes only the files listed in its own manifest (`build-info/<image>/published-files`), so files you add to the TFTP root stay: a script `ipxe/hosts/<mac>.ipxe` for one machine, Ignition configs in `coreos/ignition/`, a hand-made `<serial>/` directory for one Pi. `build-info/` also records exactly what was built: source commits, patches, settings.

## What is added, fixed or changed

The full list, with the reason and the evidence for each item, is [UPSTREAM.md](UPSTREAM.md). In short:

**iPXE** ([details](UPSTREAM.md#ipxe-ipxe-build))
- Pinned to an iPXE master commit with the TLS 1.3 fixes that the last release (v2.0.0) lacks; HTTPS downloads from Flatcar, Alpine, Debian and NixOS servers work.
- netboot.xyz works on arm64: iPXE reports netboot.xyz's version so the menu does not replace it with its own x86 binary, and it trusts the netboot.xyz CA so the menu's signature checks pass.
- BIOS clients get `ipxe.kpxe` (iPXE's own network drivers, the card's PXE ROM as fallback) instead of `undionly.kpxe`: 13 to 23 times faster downloads in tests. Cards whose driver fails can be listed for `undionly.kpxe`.
- A second arm64 build without CPU idle sleep, because the normal one freezes under U-Boot on the Pis.
- Fixes (patches): a device tree loaded with `fdt` keeps the board's MAC address and console; it is passed through U-Boot's device tree fixups; NFS downloads no longer fail when the portmapper answers late.
- HTTPS, NFS, FTP, `imgverify`, NTP and debugging commands compiled in; IPv4 only by default (saves about 4 s per boot without an IPv6 router).

**U-Boot for the Pis** ([details](UPSTREAM.md#u-boot-rpi-uboot-build))
- Pi 5: Ethernet and USB through the RP1 chip (patch series from siderolabs/sbc-raspberrypi, rebased), PHY and link fixes, a console on the GPIO header (pins 14/15, like the Pi 3 and Pi 4) with a replay of the early boot messages.
- Pi 4: Ethernet after a firmware netboot (on the tested board no frame reached the wire at 1 Gbit/s, so DHCP never got an answer); 3 s faster start, because the SD controller of the WiFi chip is not scanned.
- Network first: DHCP, then iPXE; if that fails or iPXE returns, the local disks (SD, USB, NVMe); if nothing boots, a reset after 10 s, so a headless Pi keeps trying.
- Works with a ProxyDHCP server as well as with a single DHCP server that names the boot server.
- Fixes for upstream bugs: a pointer corruption at start (crashed iPXE on the Pi 5), stray break characters stopping the boot, warnings on empty SD slots.
- Publishes the UEFI variable `FdtFile` with the board's upstream device tree name ([rule R3](#design-rules)); the OS console follows `CONSOLE_MAIN` ([rule R2](#design-rules)).

**UEFI firmware for the Pis** ([details](UPSTREAM.md#edk2-uefi-firmware-rpi-uefi-build))
- Network boot on the Pi 3 (iPXE's USB Ethernet driver inside the firmware) and the Pi 5 (a new driver for the RP1 Ethernet; about 30 MB/s after a receive ring fix).
- Pi 5: Trusted Firmware-A from the LTS line with the CVE-2025-10263 workaround instead of the port's older copy; console and diagnostics on the GPIO header.
- Headless behaviour: reset when nothing boots, PXE before local disks before HTTP boot, no IPv6 boot options waiting minutes for a router.
- Pi 4: the device tree is now found (the address in `config.txt` pointed inside the firmware image).
- ACPI plus device tree by default, so Raspberry Pi kernels boot as well as distribution kernels; `FdtFile` and `CONSOLE_MAIN` as under U-Boot.

**Device trees** ([dts/](dts/README.md)): the Pis' trees from upstream Linux (devicetree-rebasing, pinned to a Linux release), with an RP1 UART node on the Pi 5 so Linux can use the GPIO serial port.

**Fedora CoreOS** ([details](UPSTREAM.md#fedora-coreos-coreos-stage)): Fedora's unmodified live PXE files, plus an extra initrd with `rp1_pci` for the Pi 5, and the Ignition config handed over in an initrd because Ignition does not retry a TFTP download.

**NFS and iSCSI** ([nfs-ganesha](UPSTREAM.md#nfs-ganesha-nfs-service), [tgt](UPSTREAM.md#tgt-iscsi-service)): Debian's packages with settings for network roots: Ganesha 9.14 so Linux 6.19+ clients can use NFSv4, TCP only, no caches that hide changes made on the server; one iSCSI target per disk with stable serial numbers, thin provisioning and dead-connection detection. No kernel modules on the host, no `--privileged`.

What exists upstream for each change, and when it can be dropped, is tracked in [UPSTREAM-TRACKING.md](UPSTREAM-TRACKING.md). A daily [upstream watch](.github/workflows/upstream-watch.yml) reports new patch series, pull requests and releases that touch them to [issue #1](https://github.com/vholck/pxe-builds/issues/1).

## Using the images

[examples/compose/](examples/compose/) is a complete deployment: dnsmasq as ProxyDHCP and TFTP server next to your router's DHCP, fed by the stage images, with optional Matchbox, NFS and iSCSI. Copy it, fill in `.env` from `.env.example`, and run `docker compose up -d`.

The boot flow it gives:

```
PC firmware (BIOS/UEFI) ─┐                      ┌─ ipxe/hosts/<mac>.ipxe  (one machine)
Pi boot ROM → U-Boot ────┼─→ iPXE → boot.ipxe ──┼─ Matchbox profile       (optional)
Pi boot ROM → UEFI ──────┘                      └─ IPXE_CHAIN_URI         (default: netboot.xyz menu)
```

The run-time settings of each image (variables, mounts) are in its README. Which Pis boot UEFI, what each machine boots and the network addresses are run-time choices; nothing about a particular board is compiled into any image.

## Design rules

The builds follow these rules for every platform they serve (x86 BIOS and UEFI, Pi 3, Pi 4, Pi 5). A platform that cannot follow one has a row in [UPSTREAM.md](UPSTREAM.md) with the hardware reason.

- **R1, one rule for all platforms.** A design question is answered for every platform; exceptions name their hardware reason.
- **R2, OS console.** The firmware always describes the serial console to the OS (`stdout-path` in the device tree, the SPCR table under ACPI). One build setting, `CONSOLE_MAIN`, chooses the main console for every Pi under both firmwares: `auto` (upstream behaviour) makes the display the main console when one is connected, `serial` keeps serial main with the display second.
- **R3, hardware description.** The firmware hands the OS what unmodified firmware would: Raspberry Pi's own device tree (or ACPI where EDK2 defaults to it). Both firmwares also publish the UEFI variable `FdtFile` with the name of the board's upstream Linux tree; an OS that needs that tree loads it itself (iPXE: `fdt <folder>/${efi/FdtFile:string}`), from `rpi/upstream/` in the TFTP root.
- **R4, settings.** One setting per topic, valid for every Pi family, with a per-family override only where a family really differs.
- **R6, tests.** A change to a shared rule is tested on each platform family it touches; what was tested is in the commit message, and untested platforms are named there.

## Tested on

| Platform | Firmware | Status |
|---|---|---|
| Raspberry Pi 5 (8 GB, revision C1) | U-Boot, UEFI | network boot, netboot.xyz, Fedora CoreOS, Alpine, Raspberry Pi OS and Ubuntu over NFS |
| Raspberry Pi 4 B | U-Boot, UEFI | network boot, netboot.xyz, Fedora CoreOS; the newest device trees (Linux 7.3) not yet |
| Raspberry Pi 3 B | U-Boot, UEFI | network boot, netboot.xyz; the newest device trees not yet |
| x86-64, BIOS and UEFI | iPXE in QEMU/KVM | netboot.xyz, NFS and iSCSI roots, TLS 1.3 downloads; `ipxe.kpxe` on real network cards not yet |
| Pi 500, CM5, Pi 5 revision D0 | | device trees shipped, not tested |

## Building

All build settings are in [build.env](build.env): source commits, the device tree release, `CONSOLE_MAIN`, iPXE options, UEFI defaults. A push to `main` that changes an image's directory or `build.env` rebuilds that image ([.github/workflows/](.github/workflows/)). A build that no longer applies a patch fails.

The Pi firmware can also be built on any Docker host with the same settings:

```bash
cd rpi-uboot-build
docker compose --env-file ../build.env run --rm rpi-uboot-build        # all models, output in ./out
MODEL=rpi5 docker compose --env-file ../build.env run --rm rpi-uboot-build
```

`rpi-uefi-build/` works the same way; the other directories build with `docker build` (see their READMEs).

After a successful build, CI also writes the new image tag into the private repository that deploys these images (step "Pin the image", deploy key in the secret `STACKS_DEPLOY_KEY`). In a fork without that secret the step only prints a warning.

GitHub stops scheduled workflows (the daily CoreOS build and the upstream watch) after 60 days without activity in a repository; then run them by hand or push.
