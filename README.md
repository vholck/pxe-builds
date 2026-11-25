# pxe-builds

Builds the images of a network-boot stack: iPXE, U-Boot and UEFI firmware for Raspberry Pi 3, 4 and 5, Linux device trees for the Pis, the Fedora CoreOS boot files, and the NFS and iSCSI server containers. Each image carries finished files; the stack that runs them (dnsmasq as ProxyDHCP + TFTP, Matchbox) only copies them into its TFTP root at start. Nothing is compiled on the boot host.

## What is here

| Directory | Image (`ghcr.io/vholck/pxe-builds/…`) | What it holds |
|---|---|---|
| [ipxe-build/](ipxe-build/) | `ipxe-build` | iPXE for x86 BIOS, x86-64 and arm64 UEFI, and the arm64 build for U-Boot; boot scripts, `dnsmasq.conf` template, patches |
| [rpi-uboot-build/](rpi-uboot-build/) | `rpi-uboot` | U-Boot for Pi 3, 4 and 5 (Pi 5 Ethernet from patches), the Raspberry Pi boot files and one shared `config.txt` |
| [rpi-uefi-build/](rpi-uefi-build/) | `rpi-uefi` | EDK2 UEFI firmware for Pi 3, 4 and 5 with network boot |
| [dts/](dts/) | (used by both Pi images) | upstream Linux device trees for the Pis, plus the RP1 UART node the Pi 5 lacks upstream |
| [coreos-build/](coreos-build/) | `coreos` | Fedora CoreOS boot scripts and the extra initrd a Pi 5 needs; rebuilt daily for new releases |
| [nfs-build/](nfs-build/) | `nfs` | nfs-ganesha server for root file systems on NFS |
| [iscsi-build/](iscsi-build/) | `iscsi` | tgt iSCSI target for machines that boot from a network disk |

Every difference from upstream (patch, build option, pin) is listed with its reason in [UPSTREAM.md](UPSTREAM.md); what exists upstream for each, and when ours can go, is in [UPSTREAM-TRACKING.md](UPSTREAM-TRACKING.md).

## How a build reaches the stack

1. A push to `main` that touches a directory, or [build.env](build.env), runs that image's workflow (`.github/workflows/build-*.yml`). The image is tagged with the commit SHA (CoreOS: a hash of its content) and `latest`.
2. The workflow then writes the new tag into the stack's repository (`stacks/pxe/.env.override` there), with the token in the secret `STACKS_TOKEN`. Without the secret the image is still pushed, and the step warns.
3. The stack's deployment picks up that commit and pulls the image.

Build settings, such as the iPXE commit, the firmware and device tree pins, the console choice and UEFI defaults, are all in [build.env](build.env). Runtime choices are made in the stack, not here: addresses, which Pis boot UEFI instead of U-Boot, and per-machine boot scripts. No serial number, MAC address or other device data is compiled into any image.

## Local builds

The Pi firmware can be built by hand on any Docker host, with the same settings CI uses:

```bash
cd rpi-uboot-build
docker compose --env-file ../build.env run --rm rpi-uboot-build        # all models, output in ./out
MODEL=rpi5 docker compose --env-file ../build.env run --rm rpi-uboot-build
```

`rpi-uefi-build/` works the same way. The other directories build with plain `docker build`; see each README.

## Upstream watch

[.github/workflows/upstream-watch.yml](.github/workflows/upstream-watch.yml) checks every day for upstream work that overlaps the patches here: posted patch series and their review state, pull requests, fork branches, new releases of pinned sources. The list is [.github/upstream-watch.json](.github/upstream-watch.json). Changes are reported to an issue in the stack's repository.

GitHub stops scheduled workflows in a repository without activity for 60 days. When that happens, run them by hand or push.
