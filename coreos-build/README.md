# coreos-build: Fedora CoreOS for the pxe stack

Builds the image of the pxe stack's `coreos-stage` service. It publishes into the TFTP root:

| Path | What |
|---|---|
| `ipxe/fcos.ipxe` | Boots Fedora CoreOS stable as a live system (runs from RAM) on x86-64 and aarch64, Raspberry Pi 5 included, under U-Boot and UEFI |
| `ipxe/custom/custom.ipxe` | This stack's menu inside netboot.xyz ("Custom URL Menu" in its main menu) |
| `ipxe/coreos/fedora-coreos-stable.ipxe` | The newest stable release, written in CI |
| `coreos/initrd/fedora-coreos-<version>-aarch64.cpio` | Extra initrd for the Pi 5, one per release, for the last six stable releases |
| `coreos/ignition/` | Your Ignition configs (`<mac>.ign`, `default.ign`); the stage only writes the README there |
| `build-info/coreos/` | Releases in the image, file checksums, the stage's manifest |

## Booting CoreOS

- **From the menu:** netboot.xyz main menu → *Custom URL Menu* → *Fedora CoreOS stable*.
- **Always, for one machine:** `ipxe/hosts/<mac>.ipxe` with
  ```
  #!ipxe
  chain tftp://${next-server}/ipxe/fcos.ipxe
  ```
  Before the `chain` line the script may `set fcos_version <release>` (one of the last six for a Pi 5; any release elsewhere) and `set fcos_kargs <kernel arguments>`.
- **From Matchbox** (`MATCHBOX_ENABLED=1`): a profile per release with the extra initrd from `coreos/initrd/`; tested examples and the rules in ../matchbox/README.md.
- **Ignition:** put the config in `coreos/ignition/<mac>.ign` (MAC lower-case with hyphens) or `coreos/ignition/default.ign`. iPXE hands it to the kernel as `/config.ign` inside an initrd, which CoreOS reads like a config embedded with `coreos-installer pxe ignition wrap`. `ignition.config.url=tftp://...` is not used: Ignition does not retry TFTP, and on a Pi 5 the network comes up too late (emergency mode in two of three tests).
- **Console:** no `console=` argument. On a Pi 5 the device tree decides: the GPIO serial pins when no display is connected, the display otherwise (see the `rpi-uboot-build` and `rpi-uefi-build` READMEs). Kernel, initramfs and root file system come over HTTPS from `builds.coreos.fedoraproject.org`; only the extra initrd and Ignition come from this stack.
- **Install to disk:** boot live, then `sudo coreos-installer install /dev/<disk> --ignition-file ...` as usual.

## Why the Pi 5 needs an extra initrd

The Pi 5's Ethernet is behind the RP1 chip, which needs the `rp1_pci` driver. The CoreOS live initramfs contains the other RP1 drivers (clock, pinctrl, the Cadence MAC) but not `rp1_pci`: dracut's list of arm driver directories does not include `drivers/misc`. Without it the initramfs never gets a network and waits for its root file system forever. Details and the proposed upstream fix: [dracut-rp1-bug-report.md](dracut-rp1-bug-report.md).

[build-extra-initrd.sh](build-extra-initrd.sh) takes `rp1_pci.ko` from the release's own kernel package (Fedora koji) and regenerates the module lists over the initramfs's module tree. The archive therefore fits exactly one release. When a release's initramfs already has `rp1_pci` (the fix landed), the script writes a `.none` marker instead and `fcos.ipxe` boots without an extra initrd.

## How it is built

[.github/workflows/build-coreos.yml](../.github/workflows/build-coreos.yml) runs daily, on a push to this directory and by hand:

1. [assemble.sh](assemble.sh) reads the stable release list, takes the extra initrds built earlier from the GitHub release `coreos-extra-initrds`, and builds the missing ones with this directory's [Dockerfile](Dockerfile).
2. New extra initrds are uploaded to that release, so each is built once.
3. The image tag is a hash of the published files. When an image with that tag exists, nothing is pushed or pinned; otherwise CI pushes the image and pins it, and Portainer redeploys.

GitHub stops scheduled workflows in a repository without activity for 60 days; then run the workflow by hand or push.

By hand, on any Docker host (the boot host included):

```
docker build -t coreos-build coreos-build
bash coreos-build/assemble.sh <store> <out>   # <out>/tftp is the tree
docker run --rm -v "$PWD/out:/out" coreos-build fedora-coreos 45.20261030.3.1 /out   # one release
```
