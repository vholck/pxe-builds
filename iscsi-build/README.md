# iscsi-build

An iSCSI target for machines that boot from a network disk: one disk file per machine, served over iSCSI from a host directory. It runs [tgt](https://github.com/fujita/tgt), a user-space target, so the host needs no kernel iSCSI target (LIO) or module, and the container is not privileged. The image also has `iscsi-disk`, a tool that makes, copies and deletes the disks.

Image: `ghcr.io/vholck/pxe-builds/iscsi` (tags: the commit SHA and `latest`). Built by [build-iscsi.yml](../.github/workflows/build-iscsi.yml); by hand: `docker build -t local/pxe-iscsi iscsi-build`.

## Disks and targets

The directory mounted at `/srv/iscsi` holds:

| Path | What |
|---|---|
| `base/<name>.raw` | Installed systems that machine disks are copied from. Not served. |
| `disks/<name>.raw` | One disk per machine, served as the target `<ISCSI_IQN>:<name>`, the disk at LUN 1. |

Disk files are raw and sparse: a disk uses on the host only what was written to it. Blocks the machine discards (TRIM, `fstrim`) become holes in the file again.

LUN 0 is tgt's controller, so the disk is at LUN 1. iPXE boots a disk with:

```
sanboot iscsi:<server>:::1:<ISCSI_IQN>:<name>
```

Targets exist only in the running tgtd: the entrypoint publishes every disk in `disks/` again at each start, and `iscsi-disk` publishes a disk when it makes one. Each target has a SCSI serial number and device ID derived from the disk's name, so a disk looks the same to its machine after every restart.

## Running it

The entrypoint (`start.sh`) does this at every start:

1. Creates `/srv/iscsi`, `base/` and `disks/` if they are missing. A directory owned by root (Docker creates a missing bind-mount source as root) is given to `PUID:PGID`. This also happens while the target is off, so disks can be put in place first.
2. If `ISCSI_ENABLED` is not `1`, it logs that and sleeps; no target runs.
3. Starts `tgtd` in the foreground (logs go to the container's output), on port 3260 of every address the container has.
4. Publishes every disk with `iscsi-disk publish-all`. A disk whose file name is not a valid name (see below) is skipped with a message.

On `docker stop` it does what upstream's `tgtd.service` does: system offline, every target offline, targets deleted (open sessions are closed), then tgtd ends. If tgtd has not ended after 5 seconds it is killed. (tgtd ignores SIGTERM, so a plain stop would wait Docker's 10 seconds and kill it.)

The container exits with status 1 when it has no network interface other than `lo`. This is for running it in another container's network namespace (`network_mode: service:<name>` or `--network container:<name>`): when that container is restarted, it gets a new namespace, and this one is left with only `lo`. With a restart policy, Docker then starts it again in the new namespace.

### Environment

| Variable | Default | Required | Meaning |
|---|---|---|---|
| `ISCSI_ENABLED` | `0` | yes, set `1` | `1` starts the target. Any other value only prepares the directories and sleeps. |
| `ISCSI_CLIENTS` | `LAN_SUBNET` | no | Who may connect: IPv4 or IPv6 addresses or networks (e.g. `192.0.2.0/24`), comma-separated. Host names are not accepted. A target is not shown to other initiators, and their login fails. |
| `LAN_SUBNET` | none | yes, unless `ISCSI_CLIENTS` is set | Your network in CIDR notation (e.g. `192.0.2.0/24`), used as the client list when `ISCSI_CLIENTS` is empty. The container stops with an error when neither is set. |
| `ISCSI_IQN` | `iqn.2026-11.pxe.stack` | no | First part of every target name: `<ISCSI_IQN>:<disk name>`. Converted to lower case. |
| `PUID` | `500` | no | Owner (user id) given to root-owned data directories at start, and to disk and base files that `iscsi-disk` writes. |
| `PGID` | `500` | no | Group id for the same. |

There is no CHAP: access is limited by address only.

### Mounts

| Container path | What goes there |
|---|---|
| `/srv/iscsi` | A host directory you mount. Holds `base/` and `disks/`. |

### Ports

| Port | Service |
|---|---|
| 3260/tcp | iSCSI |

### Capabilities

None. The container runs unprivileged without added capabilities. At start tgtd logs that it cannot set its OOM score and open-file limit and that RDMA (iSER) is missing; that does not affect iSCSI over TCP.

### Example

Compose:

```yaml
services:
  iscsi:
    image: ghcr.io/vholck/pxe-builds/iscsi:latest
    restart: unless-stopped
    init: true
    ports:
      - "3260:3260"
    environment:
      ISCSI_ENABLED: "1"
      ISCSI_CLIENTS: 192.0.2.0/24
      ISCSI_IQN: iqn.2026-11.example.boot
      PUID: "1000"
      PGID: "1000"
    volumes:
      - /path/to/iscsi-data:/srv/iscsi
```

`docker run`:

```sh
docker run -d --name iscsi --restart unless-stopped --init -p 3260:3260 \
  -e ISCSI_ENABLED=1 -e ISCSI_CLIENTS=192.0.2.0/24 \
  -v /path/to/iscsi-data:/srv/iscsi \
  ghcr.io/vholck/pxe-builds/iscsi:latest
```

The client list is checked against the address the initiator connects from, as tgtd sees it.

## iscsi-disk: one disk per machine

`iscsi-disk` runs inside the container:

```sh
docker exec <container> iscsi-disk <command> ...
```

| Command | What it does |
|---|---|
| `list` | Lists the bases and the disks: size (apparent and used on the host), target name, connected machines. |
| `new <name> <size>` | Makes an empty sparse disk (e.g. `20G`), for an OS's own installer, and publishes it. |
| `copy <base> <name>` | Copies `base/<base>.raw` to the disk `<name>` and publishes it. Fails if the disk exists. |
| `reset <base> <name>` | Deletes the disk `<name>` and copies it again from `<base>`. |
| `delete [-f] <name>` | Deletes the disk `<name>`. |
| `save <name> <base>` | Copies the disk `<name>` to `base/<base>.raw` as a new base. Fails if the base exists. |

A typical cycle: boot a machine from its own disk, install and set up what you want, power it off, `save` it as a new base.

- **Names:** lower-case letters, digits, `.` and `-` (iSCSI names have no capitals or `_`), not starting with `.` or `-`. A name that contains the machine's MAC address, such as `debian-02-00-00-00-00-01`, lets one iPXE script serve every machine (see the examples).
- **Copies** are full copies of the sparse file; instant only on a host file system with reflinks.
- **Identity:** a copy keeps the base's machine ID and SSH host keys if the base has them. Before `save`, clear them on the machine if copies should get their own (e.g. `truncate -s 0 /etc/machine-id; rm /etc/ssh/ssh_host_*`).
- **Disks in use:** `reset`, `delete` and `save` refuse while a machine is connected to the disk. A machine that was switched off never logs out, so the target counts it as connected until its pings go unanswered: tgt pings every 15 seconds and closes the connection after 4 missed pings. The commands wait up to 80 seconds for the connection to go before they refuse.
- **`delete -f`** does not wait: it closes the connection, and a machine that is still running loses its disk. Such a machine keeps trying to get its disk back, and a new disk made under the same name while it runs is taken over and damaged. That is why `reset` has no `-f`.
- Changing commands run one at a time (a lock file).

The entrypoint also uses `iscsi-disk publish-all`; it is not meant to be run by hand.

## Making a base disk: get-debian-iscsi-disk.sh

[get-debian-iscsi-disk.sh](get-debian-iscsi-disk.sh) is not in the image: it is a script you run on the Docker host (it needs only Docker). It prepares Debian 13 as a base disk for x86-64 machines (UEFI and BIOS) that boot from iSCSI:

```sh
sh get-debian-iscsi-disk.sh <data dir> <ssh public key file> [name]
```

`<data dir>` is the parent of the host directory mounted at `/srv/iscsi`: the script writes `<data dir>/iscsi/base/<name>.raw` (default name `debian`). So if you mount `/path/to/data/iscsi` at `/srv/iscsi`, give it `/path/to/data`. It fails if the base exists.

It downloads Debian's generic cloud image (`debian-13-generic-amd64` from cloud.debian.org, checked against the published `SHA512SUMS`), grows it to `DISK_SIZE`, and changes it in a privileged helper container (it loop-mounts the image):

- open-iscsi in the initramfs takes over the connection iPXE made, from the firmware table iPXE leaves (iBFT). The initramfs does no DHCP of its own; it keeps the address iPXE got.
- systemd-networkd keeps that address and renews it by DHCP with the MAC address as client ID, as iPXE did. The boot waits for one network link, not all.
- cloud-init is off.
- SSH for root with your key only. Host keys and the machine ID are made at the first boot, so every copy gets its own.
- No fixed hostname: the initramfs names the machine after its disk (the part of the target name after the last `:`). A name set in the machine (`hostnamectl set-hostname`) wins.

| Variable | Default | Meaning |
|---|---|---|
| `DISK_SIZE` | `4G` | Size of the base disk; the root partition and file system fill it. |
| `ROOT_PASSWORD_HASH` | _(empty)_ | Optional password for root on the console, as a hash from `openssl passwd -6`. SSH stays key-only. |

Then make a machine's disk from it, e.g. `docker exec <container> iscsi-disk copy debian debian-02-00-00-00-00-01`.

## iPXE examples

Two iPXE scripts in [examples/](examples/). Both find the disk by the machine's MAC address (lower-case, with hyphens), so the same script works for every machine. They use `${next-server}` as the target's address and the default `ISCSI_IQN`; change both if yours differ. Run them from your iPXE boot flow, for example as the per-machine script `ipxe/hosts/<mac>.ipxe` that the boot script of [ipxe-build](../ipxe-build/README.md) chains.

| Script | What it does |
|---|---|
| [iscsi-disk.ipxe](examples/iscsi-disk.ipxe) | Boots the disk `debian-<mac>` with `sanboot`. If that fails, it returns so the normal boot goes on. |
| [iscsi-install.ipxe](examples/iscsi-install.ipxe) | Attaches the disk `<os>-<mac>` (`set os fcos`) with `sanhook` and boots it. If the disk is empty, it chains `ipxe/matchbox.ipxe` from the TFTP server, which must hand the machine to a Matchbox you run yourself, whose profile starts an installer that installs onto the attached disk. The `ipxe-build` image writes `ipxe/matchbox.ipxe` when it runs with `MATCHBOX_ENABLED=1`. For systems that install themselves from a live system, such as Fedora CoreOS. |

The OS on the disk must bring its own iSCSI client that takes over from the iBFT; `get-debian-iscsi-disk.sh` prepares Debian that way.

## Differences from upstream

No patches; Debian's tgt package without a `targets.conf`. `iscsi-disk` makes the targets with `tgtadm`: one target per disk named after the disk, the disk at LUN 1, access by address list instead of `ALL`, no CHAP, serial number and device ID from the disk name, thin provisioning on, and pings every 15 seconds with the connection closed after 4 missed ones (tgt's default: no pings). Reasons for each: [UPSTREAM.md, tgt](../UPSTREAM.md#tgt-iscsi-service).
