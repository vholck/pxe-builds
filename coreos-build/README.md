# coreos-build

Boot files for [Fedora CoreOS](https://fedoraproject.org/coreos/) over the network: iPXE scripts that boot Fedora CoreOS stable as a live system (it runs from RAM) on x86-64 and aarch64, Raspberry Pi 5 included, under U-Boot and UEFI, and the extra initrd a Pi 5 needs for each release. Kernel, initramfs and root file system come unmodified over HTTPS from `builds.coreos.fedoraproject.org`; only the scripts, the extra initrd and your Ignition config come from your TFTP server.

Image: `ghcr.io/vholck/pxe-builds/coreos` (tags: a hash of the published files, and `latest`). It is rebuilt daily and changes only when a new stable release appears.

## A stage image

The image runs no service. At start it copies its files into the TFTP root mounted at `/out`, then exits. Run it once whenever the TFTP server is set up or started, and after pulling a new tag.

It publishes:

| Path in the TFTP root | What |
|---|---|
| `ipxe/fcos.ipxe` | Boots Fedora CoreOS as a live system |
| `ipxe/custom/custom.ipxe` | A small menu with a *Fedora CoreOS stable* entry and, on x86, *Windows PE command prompt (rescue)*, for netboot.xyz's "Custom URL Menu" (see below) |
| `ipxe/coreos/fedora-coreos-stable.ipxe` | Sets `fcos_version` to the newest stable release; written at build time |
| `coreos/initrd/fedora-coreos-<version>-aarch64.cpio` | Extra initrd for the Pi 5, one per release, for the last six stable releases |
| `coreos/ignition/README.txt` | How to add Ignition configs |
| `build-info/coreos/` | `releases` (each release and whether it has an extra initrd), `files.sha256`, and the manifest `published-files` |

How it copies:

- Each file is written under a temporary name and renamed, so a client never downloads a half-written file. Files and directories are owned by `PUID:PGID`.
- Files of the same name are overwritten at every start: do not edit the published files; put your own scripts elsewhere.
- It deletes only files that are listed in its own manifest, `build-info/coreos/published-files`, from the previous run and that this version no longer ships (for example the extra initrds of releases that dropped out of the last six). Other files in the TFTP root, and your files in `coreos/ignition/`, are never touched. Other stage images can publish into the same TFTP root at the same time.

### Environment and mounts

| Variable | Default | Required | Meaning |
|---|---|---|---|
| `PUID` | `500` | no | Owner (user id) of the published files and directories |
| `PGID` | `500` | no | Group id for the same |

| Container path | What goes there |
|---|---|
| `/out` | The TFTP root: a host directory you mount, which your TFTP server serves |

No ports and no added capabilities.

### Example

```sh
docker run --rm -e PUID=1000 -e PGID=1000 \
  -v /path/to/tftp-root:/out \
  ghcr.io/vholck/pxe-builds/coreos:latest
```

In compose, as a one-shot service:

```yaml
services:
  coreos-stage:
    image: ghcr.io/vholck/pxe-builds/coreos:latest
    restart: "no"
    environment:
      PUID: "1000"
      PGID: "1000"
    volumes:
      - /path/to/tftp-root:/out
```

## Booting CoreOS

The scripts expect an iPXE with HTTPS support that was loaded from the same TFTP server (they use `${next-server}`), such as the builds in [ipxe-build](../ipxe-build/README.md).

- **From netboot.xyz:** ipxe-build's [netbootxyz.ipxe](../ipxe-build/tftp/ipxe/netbootxyz.ipxe) sets netboot.xyz's `custom_url` to `ipxe/custom/` on the TFTP server. Then: netboot.xyz main menu → *Custom URL Menu* → *Fedora CoreOS stable*.
- **Windows PE (rescue):** the same menu has, on x86 machines, *Windows PE command prompt (rescue)*. It chains `http://<server>:8080/ipxe?rescue=windows-pe&arch=<arch>`: a [Matchbox](https://matchbox.psdn.io/) on the boot server with a group whose selector is `rescue: windows-pe` decides what boots (wimboot, `boot.wim` and the other files of a Windows ISO, and a `winpeshl.ini` of your choice). Without such a group the item says so and returns to the menu. Leaving the menu frees every loaded image first: under UEFI wimboot hands every image still loaded to Windows PE as a file.
- **Always, for one machine:** with ipxe-build's [boot.ipxe](../ipxe-build/tftp/ipxe/boot.ipxe), put a per-machine script in `ipxe/hosts/<mac>.ipxe` (MAC lower-case with hyphens, e.g. `ipxe/hosts/02-00-00-00-00-01.ipxe`):
  ```
  #!ipxe
  chain tftp://${next-server}/ipxe/fcos.ipxe
  ```
  Before the `chain` line the script may `set fcos_version <release>` (one of the last six for a Pi 5; any stable release elsewhere) and `set fcos_kargs <kernel arguments>`.
- **From your own iPXE scripts:** chain `ipxe/fcos.ipxe` the same way. If you run Matchbox yourself, a CoreOS profile per release works too; on aarch64 it must add that release's extra initrd from `coreos/initrd/` and `rd.driver.pre=rp1_pci`, as `fcos.ipxe` does.
- **Install to disk:** boot live, then `sudo coreos-installer install /dev/<disk> --ignition-file ...` as usual.

`fcos.ipxe` needs a 64-bit machine. When a step fails it requests a file that does not exist under `ipxe/log/` (for example `ipxe/log/fcos-failed-<version>`), so the failure shows in the TFTP server's log. On failure it frees what it loaded and waits up to 10 seconds for a key before it returns.

### Ignition

A machine gets its Ignition config from the TFTP root, the first of:

1. `coreos/ignition/<mac>.ign`: MAC lower-case with hyphens, e.g. `coreos/ignition/02-00-00-00-00-01.ign`
2. `coreos/ignition/default.ign`: for every machine without its own file

Without either, the live system starts without a config. The files must be Ignition JSON (spec 3.x); write them in Butane and convert with `butane`. They are yours: the stage image never changes or deletes them.

iPXE hands the file to the kernel as `/config.ign` inside an initrd, which CoreOS reads like a config embedded with `coreos-installer pxe ignition wrap`. `ignition.config.url=tftp://...` is not used: Ignition does not retry TFTP, and on a Pi 5 the network comes up too late (emergency mode in two of three tests).

### Console and device tree

- **No `console=` argument.** On a Pi 5 the device tree decides: the GPIO serial pins when no display is connected, the display otherwise (see the [rpi-uboot-build](../rpi-uboot-build/README.md) and [rpi-uefi-build](../rpi-uefi-build/README.md) READMEs). Add one with `fcos_kargs` if needed.
- **Device tree (aarch64):** Fedora's kernel needs the upstream Linux device tree on a Raspberry Pi; with Raspberry Pi's own tree the Pi 5 has no Ethernet or USB. When the firmware names the board's tree in the UEFI variable `FdtFile` (U-Boot and the UEFI firmware built in this repository do), `fcos.ipxe` loads `rpi/upstream/<FdtFile>` from the TFTP server. The rpi-uboot image publishes these trees (see [dts/README.md](../dts/README.md)). A machine without the variable keeps what its firmware hands over; if the file is missing, the firmware's tree is used.

## Why the Pi 5 needs an extra initrd

The Pi 5's Ethernet is behind the RP1 chip, which needs the `rp1_pci` driver. The CoreOS live initramfs contains the other RP1 drivers (clock, pinctrl, the Cadence MAC) but not `rp1_pci`: dracut's list of arm driver directories does not include `drivers/misc`. Without it the initramfs never gets a network and waits for its root file system forever. Details and the proposed upstream fix: [dracut-rp1-bug-report.md](dracut-rp1-bug-report.md).

[build-extra-initrd.sh](build-extra-initrd.sh) takes `rp1_pci.ko` (and any module it needs that the initramfs lacks) from the release's own kernel package (Fedora koji) and regenerates the module lists over the initramfs's module tree. The kernel unpacks the extra initrd after the main initramfs, so its module lists replace the originals: the archive fits exactly one release. `fcos.ipxe` adds it on every aarch64 machine, with `rd.driver.pre=rp1_pci`; on machines without an RP1 the driver finds no device and does nothing.

When a release's initramfs already has `rp1_pci` (the fix landed), the script writes a `.none` marker instead, no archive is published, and `fcos.ipxe` boots without an extra initrd. A release older than the last six has no archive either: `fcos.ipxe` says so and boots without it, and a Pi 5 then gets no network.

## How it is built

[build-coreos.yml](../.github/workflows/build-coreos.yml) runs daily, on a push to this directory and by hand:

1. [assemble.sh](assemble.sh) reads the stable release list, takes the extra initrds built earlier from the GitHub release `coreos-extra-initrds`, and builds the missing ones with this directory's [Dockerfile](Dockerfile) (a Fedora image whose entrypoint is `build-extra-initrd.sh`).
2. New extra initrds are uploaded to that release, so each is built once.
3. The tree is packaged with [Dockerfile.stage](Dockerfile.stage) (Alpine, entrypoint [stage.sh](stage.sh)). The image tag is a hash of the published files: when an image with that tag exists, nothing is pushed; otherwise the new image is pushed.

GitHub stops scheduled workflows in a repository without activity for 60 days; then run the workflow by hand or push.

By hand, on any Docker host:

```sh
docker build -t coreos-build coreos-build
bash coreos-build/assemble.sh <store> <out>   # <out>/tftp is the tree; <store> keeps the built extra initrds
docker run --rm -v "$PWD/out:/out" coreos-build fedora-coreos 45.20261030.3.1 /out   # one release only
```

`assemble.sh` reads `KEEP` (number of releases, default 6) and `BUILD_IMAGE` (default `coreos-build`) from the environment. To make the stage image from the tree, put `<out>/tftp` and `stage.sh` in one directory and run `docker build -f coreos-build/Dockerfile.stage <that directory>`.

## Differences from upstream

Fedora's live PXE files are used unmodified. Added: the extra initrd with `rp1_pci` on aarch64, the Ignition config handed over as an initrd instead of `ignition.config.url`, no `console=` argument, and the newest stable release followed daily. Reasons for each: [UPSTREAM.md, Fedora CoreOS](../UPSTREAM.md#fedora-coreos-coreos-stage).
