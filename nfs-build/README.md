# nfs-build

An NFS server for diskless machines: it serves root file systems over NFSv4.2 and NFSv3 from a host directory. It runs [nfs-ganesha](https://github.com/nfs-ganesha/nfs-ganesha), a user-space server, so the host needs no kernel NFS server or module. The image also has `nfs-root`, a tool that makes one root per machine from a shared clean root.

Image: `ghcr.io/vholck/pxe-builds/nfs` (tags: the commit SHA and `latest`). Built by [build-nfs.yml](../.github/workflows/build-nfs.yml); by hand: `docker build -t local/pxe-nfs nfs-build`.

## Exports

The container serves two exports from the directory mounted at `/srv/nfs`:

| Export | Directory | Access | For |
|---|---|---|---|
| `/rw` | `/srv/nfs/rw` | read-write | one root per machine (`/rw/<name>`) |
| `/ro` | `/srv/nfs/ro` | read-only | shared roots, and the clean roots that `nfs-root` copies from |

A client mounts `<server>:/rw/<name>` or `<server>:/ro/<name>`. NFSv3 clients use the same paths as NFSv4 clients. NFSv3 has no lock manager here, so NFSv3 clients mount with `nolock` (a kernel NFS root does that anyway). Only TCP is served.

A layered root (`nfs-root create --layered`) also appears under `/rw/<name>`, as an export of its own. Its changes are kept in `/srv/nfs/layers/<name>/`.

## Running it

The entrypoint (`start.sh`) does this at every start:

1. Creates `/srv/nfs`, `rw/`, `ro/` and `layers/` if they are missing. A directory owned by root (Docker creates a missing bind-mount source as root) is given to `PUID:PGID`. This also happens while the server is off, so roots can be put in place first.
2. If `NFS_ENABLED` is not `1`, it logs that and sleeps; no server runs.
3. Writes `/etc/ganesha/ganesha.conf`, mounts the layered roots again and writes their exports.
4. Starts dbus, rpcbind and `ganesha.nfsd` (logs go to the container's output).

On `docker stop` it stops Ganesha and waits up to 5 seconds before it kills it, so the container ends within Docker's default 10 seconds.

The container exits with status 1 when it has no network interface other than `lo`. This is for running it in another container's network namespace (`network_mode: service:<name>` or `--network container:<name>`): when that container is restarted, it gets a new namespace, and this one is left with only `lo`. With a restart policy, Docker then starts it again in the new namespace.

### Environment

| Variable | Default | Required | Meaning |
|---|---|---|---|
| `NFS_ENABLED` | `0` | yes, set `1` | `1` starts the server. Any other value only prepares the directories and sleeps. |
| `NFS_CLIENTS` | `LAN_SUBNET` | no | Who may mount: addresses, networks or host names, comma-separated (Ganesha's `Clients` list). |
| `LAN_SUBNET` | none | yes, unless `NFS_CLIENTS` is set | Your network in CIDR notation (e.g. `192.0.2.0/24`), used as the client list when `NFS_CLIENTS` is empty. The container stops with an error when neither is set. |
| `NFS_LOG_LEVEL` | `EVENT` | no | Ganesha's `Default_Log_Level` (e.g. `INFO`, `DEBUG`). |
| `PUID` | `500` | no | Owner (user id) given to root-owned data directories at start. |
| `PGID` | `500` | no | Group id for the same. |

### Mounts

| Container path | What goes there |
|---|---|
| `/srv/nfs` | A host directory you mount. Holds `rw/` (machine roots), `ro/` (clean and shared roots) and `layers/` (the changes of layered roots). |

The roots are ordinary directory trees, owned and permissioned as on a real disk. Put a clean root in `ro/<name>/` with any tool that keeps owners, modes and special files (for example `tar --numeric-owner` or `cp -a` as root).

### Ports

All TCP:

| Port | Service |
|---|---|
| 2049 | NFS (NFSv4 needs only this one) |
| 111 | rpcbind (NFSv3) |
| 20048 | mount service (NFSv3) |

With host networking, the host must not run its own rpcbind or NFS server on these ports.

### Capabilities and limits

The container does not need `--privileged`, but it needs:

- **`cap_add: DAC_READ_SEARCH`**: Ganesha's VFS back end opens files by handle (`open_by_handle_at`).
- **`cap_add: SYS_ADMIN`**: needed by the VFS back end, and by `nfs-root` to mount layered roots (overlay mounts).
- **`cap_add: SYS_RESOURCE`**: Ganesha sets `PR_SET_IO_FLUSHER` and stops without it.
- **Open-file limit 4096** (`ulimits: nofile`): with Docker's default of about a million, Ganesha's RPC library fails ("fd 1024 hook failed") and nothing listens.

### Example

Compose:

```yaml
services:
  nfs:
    image: ghcr.io/vholck/pxe-builds/nfs:latest
    restart: unless-stopped
    init: true
    network_mode: host
    environment:
      NFS_ENABLED: "1"
      NFS_CLIENTS: 192.0.2.0/24
      PUID: "1000"
      PGID: "1000"
    cap_add: [DAC_READ_SEARCH, SYS_ADMIN, SYS_RESOURCE]
    ulimits:
      nofile: { soft: 4096, hard: 4096 }
    volumes:
      - /path/to/nfs-data:/srv/nfs
```

`docker run`:

```sh
docker run -d --name nfs --restart unless-stopped --init --network host \
  -e NFS_ENABLED=1 -e NFS_CLIENTS=192.0.2.0/24 \
  --cap-add DAC_READ_SEARCH --cap-add SYS_ADMIN --cap-add SYS_RESOURCE \
  --ulimit nofile=4096:4096 \
  -v /path/to/nfs-data:/srv/nfs \
  ghcr.io/vholck/pxe-builds/nfs:latest
```

A client at 192.0.2.50 then mounts, for example, `192.0.2.10:/rw/web1` (server at 192.0.2.10). On the kernel command line of a diskless Linux machine that is `root=/dev/nfs nfsroot=192.0.2.10:/rw/web1,vers=4.2 ip=dhcp rw`, or with `vers=3,nolock` for NFSv3.

## nfs-root: one root per machine

`nfs-root` runs inside the container:

```sh
docker exec <container> nfs-root <command> ...
```

| Command | What it does |
|---|---|
| `list` | Lists the clean roots (`/ro`) and the machine roots (`/rw`); layered ones with their clean root and the size of their changes. |
| `create <clean> <name>` | Copies `/ro/<clean>` to `/rw/<name>`. Fails if `<name>` exists. |
| `create --layered <clean> <name>` | Makes `/rw/<name>` without a copy: an overlay of the clean root and a layer that holds only this machine's changes. |
| `reset <clean> <name>` | Deletes `/rw/<name>` and makes it again from `/ro/<clean>`, as a copy or layered as it was. |
| `delete <name>` | Deletes `/rw/<name>`. A clean root in `/ro` is not deleted by this command; delete it on the host once no layered root uses it. |
| `save <name> <clean>` | Copies `/rw/<name>` to `/ro/<clean>` as a new clean root (fails if it exists), with an empty machine ID. |
| `rebase <clean> <name>...` | Moves machine roots to the clean root `/ro/<clean>`, typically a newer version of the system, and keeps each machine's data and identity (see below). A copy stays a copy, a layered root stays layered. |

A typical cycle: boot a machine from its own copy, install and set up what you want, power it off, `save` it as a new clean root.

- **Identity:** a new root gets `/etc/hostname` = `<name>` (if the clean root has `/etc`), the `127.0.1.1` line in `/etc/hosts` set to `<name>` (if it has one), an empty `/etc/machine-id` (systemd makes a new one at the first boot; a second copy in `/var/lib/dbus/machine-id` is removed), and new SSH host keys if the clean root has host keys.
- **Names:** a plain directory name of letters, digits, `.`, `_` and `-`, not starting with a dot.
- **Copies** use `cp -a --reflink=auto`: instant on a host file system with reflinks (Btrfs, XFS), a full copy elsewhere.
- **Layered roots** cost only the space of the changes and are made or reset at once. Their clean root must not change or go away while they use it: to update, save a new clean root under a new name.
- Power a machine off before `reset`, `delete` or `rebase`: its root disappears under it.

**Updating the system for all machines while each keeps its own data** (`rebase`). Make the new version as a clean root (boot one machine from its own copy, update it, power it off, `save` it under a new name), then move every machine root to it:

```sh
docker exec <container> nfs-root rebase debian-2026-12 web1 web2 web3
```

For each machine, `rebase` copies the paths of its keep list aside, makes the root again from the new clean root (a new identity, as with `create`), and puts the kept paths back over it, each as a whole. Everything else comes from the new clean root: programs or settings that were changed on one machine only and are not on its keep list are gone. The default keep list is the machine's data and identity:

```
/home
/root
/var/log
/etc/hostname
/etc/hosts
/etc/machine-id
/etc/ssh/ssh_host_*
```

A machine root can have its own list in `/etc/nfs-root.keep`, which replaces the default: one absolute path per line, `*` allowed, `#` starts a comment (for example add `/var/lib/postgresql` or `/etc/myapp`). Keep the identity lines in it, or the machine gets a new machine ID and new SSH host keys. Do not keep a package manager's database (`/var/lib/dpkg`, `/var/lib/apt`, `/lib/apk`) or anything else that describes the installed system: it would no longer match the new one. Accounts are part of the system: create users in the clean root, so that their IDs match the kept `/home`. The kept paths are copied aside to `/srv/nfs/.rebase/<name>` first and that copy is removed when the new root is ready; if a rebase stops halfway, the copy stays there and a new rebase of that machine refuses to start until it is removed. The idea is the same as Fedora's `readonly-root` state list or NixOS's impermanence: name what is kept, and let everything else come from the system; here it is applied on the server when the system changes, so the machines need nothing installed for it.

The entrypoint also uses `nfs-root mount-layers` (mount every layered root and write its exports); it is not meant to be run by hand.

## Differences from upstream

No patches. Ganesha comes from Debian's `trixie-backports` instead of trixie's 6.5, because 6.5 breaks NFSv4 roots for Linux 6.19 and newer. The config differs from Ganesha's defaults: numeric owners only, no grace period, no NFSv3 lock manager, TCP only, NFSv3 clients mount by the NFSv4 path, and no cache of directory contents or file attributes (the roots are also changed directly on the host). Reasons for each: [UPSTREAM.md, nfs-ganesha](../UPSTREAM.md#nfs-ganesha-nfs-service).
