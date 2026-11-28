# smb-build

An SMB file server for installation media: one read-only share from which an installer started over the network reads its files. Made for Windows Setup run from Windows PE (booted with iPXE and wimboot), which cannot install from HTTP. It runs [Samba](https://www.samba.org/) (`smbd` only: no NetBIOS, no Active Directory, no printing).

Image: `ghcr.io/vholck/pxe-builds/smb` (tags: the commit SHA and `latest`). Built by [build-smb.yml](../.github/workflows/build-smb.yml); by hand: `docker build -t local/pxe-smb smb-build`.

## The share

The directory mounted at `/srv/smb` is served as `\\<server>\install`, read-only:

| Path in the share | For |
|---|---|
| `<name>\` | the contents of one installation ISO (Windows: `setup.exe`, `sources\install.wim`, ...) |
| `unattend\` | answer files for Windows Setup (`autounattend.xml` and the like) |

Clients log in with `SMB_USER` and `SMB_PASSWORD` (default `install` and `install`). Windows does not connect to a share as a guest over SMB2/3 by default, and Windows 11 24H2 and Server 2025 require signing, which a guest session cannot do, so the share has an account. The password only satisfies Windows: the share is read-only, and whoever installs from it has to know the password anyway (for Windows PE it is in the script that runs `net use`), so a default works out of the box. Set your own when the share holds answer files with passwords in them and not everyone on the network should read them.

## Running it

The entrypoint (`start.sh`) does this at every start:

1. Creates `/srv/smb` and `/srv/smb/unattend` if they are missing. A directory owned by root (Docker creates a missing bind-mount source as root) is given to `PUID:PGID`. This also happens while the server is off, so media can be put in place first.
2. If `SMB_ENABLED` is not `1`, it logs that and sleeps; no server runs.
3. Creates the account `SMB_USER` with the user id `PUID`, so `smbd` reads the files as their owner, and writes `/etc/samba/smb.conf`.
4. Runs `smbd` in the foreground (logs go to the container's output).

On `docker stop` it stops `smbd` and waits up to 5 seconds before it kills it. Like the nfs image, the container exits with status 1 when it has no network interface other than `lo` (it runs in another container's network namespace, and that container was restarted); a restart policy then starts it in the new namespace.

### Environment

| Variable | Default | Required | Meaning |
|---|---|---|---|
| `SMB_ENABLED` | `0` | yes, set `1` | `1` starts the server. Any other value only prepares the directories and sleeps. |
| `SMB_PASSWORD` | `install` | no | Password of `SMB_USER`. It must not contain `%` (Windows' `net use` and cmd scripts treat it specially). |
| `SMB_USER` | `install` | no | Account the clients log in with. |
| `SMB_CLIENTS` | `LAN_SUBNET` | no | Who may connect: addresses or networks (`a.b.c.d/n`), comma-separated (Samba's `hosts allow`). |
| `LAN_SUBNET` | none | yes, unless `SMB_CLIENTS` is set | Your network in CIDR notation (e.g. `192.0.2.0/24`). |
| `SMB_LOG_LEVEL` | `1` | no | Samba's `log level`. |
| `PUID` | `500` | no | User id of the account and owner of root-owned data directories. |
| `PGID` | `500` | no | Group id for the same. |

### Mounts and ports

| Container path | What goes there |
|---|---|
| `/srv/smb` | A host directory you mount (read-write, so the start script can create `unattend/`; `smbd` never writes to it). |

TCP 445 only (no NetBIOS on 137 to 139). No added capabilities and no `--privileged`: `smbd` starts as root in the container and switches to the account for each client, which Docker's default capabilities allow.

### Settings that differ from Samba's defaults

| Setting | Why |
|---|---|
| `disable netbios = yes`, `smb ports = 445` | Clients connect by address; no name service needed |
| `server min protocol = SMB2_10` | No SMB1; Windows PE of Windows 10 and newer speaks SMB 3.1.1 |
| `map to guest = never`, `restrict anonymous = 2` | Account only (see above) |
| `hosts allow` from `SMB_CLIENTS`/`LAN_SUBNET`, `hosts deny = ALL` | Only the local network |
| `acl allow execute always = yes` | Files unpacked from an ISO have no execute bits; without this Windows refuses to run `setup.exe` from the share ("Access is denied") |
| `follow symlinks = no` | Nothing outside the share is served |
| printing off | Not a print server |

## Example: Windows Setup over the network

1. Put an ISO's contents into `<dir>/ws2025/` (every file; `install.wim` of current Windows ISOs is larger than 4 GB, so read the ISO's UDF file system, for example with 7-Zip or pycdlib) and start the container with `<dir>` at `/srv/smb`.
2. Boot Windows PE with iPXE and wimboot from the same ISO's `bootmgr`, `boot/bcd`, `boot/boot.sdi` and `sources/boot.wim`, and inject two files (wimboot puts every extra file into `X:\Windows\System32`):
   - `winpeshl.ini`, which runs the script instead of Setup's own start screen:
     ```
     [LaunchApps]
     %SYSTEMROOT%\System32\cmd.exe, /k %SYSTEMROOT%\System32\install.cmd
     ```
     (no quotes around the arguments: cmd keeps a closing quote as part of the file name);
   - `install.cmd` (CRLF line ends), which starts the network, connects the share and runs Setup:
     ```
     wpeinit
     wpeutil WaitForNetwork
     net use Z: \\192.0.2.10\install /user:install <password>
     Z:\ws2025\sources\setup.exe /unattend:Z:\unattend\autounattend.xml
     ```
   In iPXE, give each injected file its name with `--name` (under UEFI iPXE names a file after its URL) and after the URL (under BIOS wimboot finds files by that name): `initrd --name install.cmd http://.../install.cmd install.cmd`.
3. Setup reads `install.wim` from the share. With an answer file that partitions disk 0 it asks nothing; installing onto an iSCSI disk works when iPXE attaches it first with `sanhook` (Windows PE and Windows then see it as a local disk) and boots it afterwards with `sanboot`.

Windows PE has no driver for virtio network cards: in QEMU use `e1000e`.

Tested 2026-11-28 with the Windows Server 2025 evaluation ISO in a QEMU x86-64 UEFI virtual machine (e1000e, 4 GB): Windows PE connected the share, Setup installed Windows Server 2025 Standard (Core) unattended onto an iSCSI disk attached with `sanhook`, booted from it with `sanboot`, and reached the logon screen with Remote Desktop open, in about 20 minutes; 6.4 GB written to the thin disk.
