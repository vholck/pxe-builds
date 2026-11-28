# iPXE source patches

Applied by [build-ipxe.sh](../build-ipxe.sh) in name order to the iPXE commit pinned by `IPXE_REF` ([build.env](../../build.env)), before anything is compiled. Every iPXE binary built here gets them. A patch that no longer applies fails the build. The names of the applied patches are recorded in `build-info/ipxe/patches` in the TFTP root.

Create a patch with `git diff` in a checkout of iPXE at `IPXE_REF` (with `core.autocrlf=false`, so the patch keeps iPXE's LF line endings). `.gitattributes` marks `*.patch` as `-text`, so git never changes them.

Existing work and when each patch can go: [UPSTREAM-TRACKING.md](../../UPSTREAM-TRACKING.md). Why each one exists: [UPSTREAM.md](../../UPSTREAM.md).

## `0001-fdt-carry-over-mac-and-console-from-firmware-tree.patch`

A device tree loaded with iPXE's `fdt` command (for example the upstream Linux tree an OS expects) knows nothing about the board it runs on. iPXE passed it on as it was. On a Raspberry Pi 4 Linux then gave the Ethernet port a random MAC address, so the board lost its DHCP reservation, its Matchbox group and its `ipxe/hosts/<mac>.ipxe` script once Linux was up.

The patch copies two things from the firmware's own tree (the system tree iPXE was started with) into the loaded one, when the loaded tree has the same node:

- `local-mac-address` of aliases `ethernet0` and `wifi0`, unless the firmware's value is missing or all zeros (on a Pi 5 the firmware has the board's Wi-Fi MAC; without it Linux used the nvram file's address, the same on every Pi 5);
- the absence of `/chosen/stdout-path`: when the firmware removed it (because a display is the main console, `CONSOLE_MAIN=auto`), it is removed from the loaded tree too, so the firmware's console choice holds for every tree.

Nothing changes when no `fdt` image is loaded: iPXE then passes the firmware's tree, as before.

## `0002-efi-fdt-apply-firmware-dt-fixup-protocol.patch`

When the firmware provides the EFI Device Tree Fixup Protocol (U-Boot does; EDK2 on the Pi does not), iPXE hands a tree loaded with `fdt` to it before installing it, with "apply fixups" and "reserve memory". The firmware then applies to that tree everything it applies to its own: MAC addresses, board revision and serial number, memory, and our U-Boot console rule (patch `0007` of rpi-uboot-build). systemd-boot, OpenBSD's EFI loader, efibootguard and Ubuntu's stubble do the same; iPXE did not call it. Patch 0001 still covers firmware without the protocol.

Tested on a Raspberry Pi 4 (2026-11-22), Fedora CoreOS 45 live with the upstream `bcm2711-rpi-4-b.dtb` loaded by `fdt`:

- U-Boot: iPXE logged the MAC copy and `fixed up by firmware`; Linux reported `Raspberry Pi 4 Model B Rev 1.5` (the revision comes from U-Boot's fixup; without the patch it was `Raspberry Pi 4 Model B`), no random MAC, the board answered on its reserved address, console on `ttyS1`.
- UEFI: MAC copied, no random MAC, reserved address; no fixup protocol, as expected.

## `0003-nfs-wait-for-nfs-connection-before-lookup.patch`

iPXE's NFS client asks the portmapper for the MOUNT port, connects to mountd, and at the same time asks the portmapper for the NFS port; it opens the NFS connection only when that answer arrives. When the MOUNT reply came first, `nfs_step()` sent the first LOOKUP at once: the NFS interface was still unconnected, reports an unlimited window, and the LOOKUP went nowhere. The download failed with `Error 0x420e2001` (EPIPE from `xfer_deliver()`), seen once on 2026-11-23 loading a kernel from a layered NFS root (issue #6).

The patch makes `nfs_step()` wait until the portmapper is done and the NFS connection is open; the connection's window change calls it again.

Tested 2026-11-25 in the x86 BIOS VM (`undionly.kpxe`), five `imgfetch nfs://192.168.1.202/ro/debian/boot/netboot/version` in a row, with portmapper replies (TCP source port 111) delayed by 400 ms on the VM's tap (`tc netem`): without the patch 5 of 5 failed with `0x420e2001`, with it 5 of 5 fetched, also at 1500 ms, and the 12 MB Debian kernel loaded twice at 400 ms. UEFI and arm64 builds compile the same code but were not run against the delay. Without the delay both builds fetched all five.
