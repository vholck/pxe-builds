# ipxe-build

Builds iPXE for every client of the stack and packages it, with the boot scripts and the `dnsmasq.conf` template, into the `ipxe-build` image. The stack's `tftp-stage` service copies the files into the TFTP root and renders `dnsmasq.conf` with the stack's addresses at every start.

| File | For |
|---|---|
| `ipxe.kpxe` | x86 BIOS PXE (default): iPXE's own network drivers, the card's PXE ROM as fallback |
| `undionly.kpxe` | x86 BIOS PXE through the card's PXE ROM only, for cards whose iPXE driver fails |
| `snponly-x86_64.efi` | x86-64 UEFI |
| `snponly-arm64.efi` | arm64 UEFI, including a Pi under the UEFI firmware |
| `snponly-arm64-rpi.efi` | every Pi under U-Boot (built without CPU idle sleep) |

Boot scripts: [autoexec.ipxe](autoexec.ipxe) (embedded), [tftp/ipxe/boot.ipxe](tftp/ipxe/boot.ipxe) (per-machine script, Matchbox, then the default), [tftp/ipxe/netbootxyz.ipxe](tftp/ipxe/netbootxyz.ipxe). Every difference from upstream iPXE is in the iPXE section of [UPSTREAM.md](../UPSTREAM.md).

## Build settings

Set in [build.env](../build.env); CI reads them when it builds the image. A push that changes one rebuilds the image and pins it in the stack.

| Variable | Default | Purpose |
|---|---|---|
| `IPXE_REF` | pinned commit | iPXE commit to build |
| `IPXE_PRODUCT_NAME` | `iPXE-mod` | User-class the binaries send, which dnsmasq matches to tell this iPXE from ROM/stock iPXE; also the banner name |
| `IPXE_KEYBOARD_MAP` | `us` | Keyboard layout (iPXE's default is `us`). Under UEFI and U-Boot, keys typed over serial reach iPXE through the firmware console like keyboard keys, so the layout applies to them too: with `se`, a `}` typed on a serial terminal arrived as `^`. `us` leaves serial input and automation intact; another layout suits a physical keyboard of that layout but corrupts some symbols typed over serial |
| `IPXE_ON_FAILURE` | `reboot` | What iPXE does when DHCP or the chain fails: `reboot`, or `shell` for debugging |
| `IPXE_IPV6` | `0` | `0`: iPXE configures IPv4 only (`ifconf --configurator dhcp`). `1`: it also configures IPv6 (`dhcp`); on a LAN with no IPv6 router that adds about 4 s to every boot, the time iPXE waits for a router advertisement. IPv6 stays compiled in either way, so a script can still run `ifconf --configurator ipv6` |
| `IPXE_SERIAL_CONSOLE` | `bios` | Which builds write to the serial port themselves (COM1 on x86). Every build also prints through the firmware console, which goes to serial wherever the firmware redirects its console. `bios`: BIOS builds only; UEFI builds rely on the firmware's redirection, as upstream does. `efi`: UEFI builds only, for a site whose BIOS machines redirect their console and whose UEFI machines do not. `all`: every build, for a UEFI PC with a serial cable but no console redirection; firmware that does redirect to the same port then shows every character twice, and the firmware and iPXE both read keys from the one UART. `off`: none; only the firmware console. EFI builds take the port from the firmware's ACPI SPCR table and drive only 16550-type UARTs: the Pis' consoles (PL011, mini UART) are not, so the setting does not change the Pis; an arm64 server with a 16550 console is treated like x86 UEFI |
| `IPXE_TRUST_NETBOOTXYZ` | `1` | `1`: iPXE trusts iPXE's root CA and the netboot.xyz CA ([certs/](certs/), pinned by SHA-256 fingerprint in [build-ipxe.sh](build-ipxe.sh)), the same two netboot.xyz's own iPXE trusts. netboot.xyz signs its menu scripts with that CA and checks the signatures by default; without it every submenu fails with `Could not verify: Permission denied`. iPXE has one trust list for signatures and HTTPS, so the netboot.xyz CA is also trusted for HTTPS. The explicit list also stops a DHCP server or script from replacing the trusted roots at run time. `0`: upstream, iPXE's root CA only. See "netboot.xyz signatures" below |
| `IPXE_TLS_MAX` | `1.3` | Highest TLS version iPXE offers for HTTPS: `1.3` (upstream's default) or `1.2`. Up to iPXE `9261ebe` TLS 1.3 failed with the Flatcar, Alpine, Debian and NixOS download servers; since `b847e5f` all work (tested 2026-11-25). `1.2` is a fallback for a server that still fails |
| `IPXE_DEBUG` | _(empty)_ | iPXE debug subsystems to compile in, e.g. `x509:3,tls:3` (names match `.c` files in the [iPXE source tree](https://github.com/ipxe/ipxe/tree/master/src); the number is verbosity 1-3). See [iPXE debug builds](https://ipxe.org/download#debug_builds) |
| `IPXE_BUILD_TAG` | _(empty)_ | Optional suffix in the version string |
| `BUILD_EXTRA_IPXE_ARTIFACTS` | `0` | `1` also builds `ipxe.pxe`, `ipxe.lkrn`, full-driver and SNP EFI variants |
| `BUILD_OPTIONAL_IPXE_MEDIA` | `0` | `1` also builds `ipxe.iso` and `ipxe.usb` |

## Compiled-in iPXE features

Source patches applied before the build: [patches/](patches/README.md) (an `fdt`-loaded device tree gets the firmware's MAC address, console choice and, under U-Boot, all of its fixups).

Enabled in `config/local/` by [build-ipxe.sh](build-ipxe.sh):

| Define / option | What it enables |
|---|---|
| `DOWNLOAD_PROTO_HTTPS` | HTTPS download support |
| `DOWNLOAD_PROTO_FTP` | FTP download support |
| `DOWNLOAD_PROTO_NFS` | NFS boot support |
| `DOWNLOAD_PROTO_FILE` | `file://` URI scheme — load from local filesystem |
| `IMAGE_TRUST_CMD` | `imgverify` command — required by netboot.xyz image verification |
| `IMAGE_GZIP` | Boot gzip-compressed images |
| `IMAGE_ZLIB` | Boot zlib-compressed images |
| `PING_CMD` | `ping` command for script debugging |
| `NSLOOKUP_CMD` | `nslookup` command for DNS debugging |
| `NTP_CMD` | `ntp` command — sync clock before certificate validation |
| `REBOOT_CMD` | `reboot` command in iPXE scripts |
| `POWEROFF_CMD` | `poweroff` command in iPXE scripts |
| `VLAN_CMD` | VLAN tagging support |
| `DIGEST_CMD` | `digest` command — used alongside `imgverify` by netboot.xyz |
| `CONSOLE_SERIAL` | iPXE's own serial console: BIOS builds only by default (setting `IPXE_SERIAL_CONSOLE`) |
| `#undef OCSP_CHECK` | Disables OCSP certificate revocation checks — avoids boot failures when OCSP servers are unreachable |

## netboot.xyz CA

netboot.xyz signs its menu scripts with its own CA, and this iPXE trusts it (`IPXE_TRUST_NETBOOTXYZ=1`). When netboot.xyz changes its CA, [netbootxyz.ipxe](tftp/ipxe/netbootxyz.ipxe) says so on screen before the menu. To fix it for good: take the CA certificate from any signature file (`curl -s http://boot.netboot.xyz/sigs/menu.ipxe.sig | openssl pkcs7 -inform DER -print_certs`, the block with `subject=... CN=netboot.xyz CA`), check that its SHA-256 fingerprint appears in netboot.xyz's current release binary (for example `netboot.xyz-snponly.efi`), save it as `ipxe-build/certs/ca-netboot-xyz.crt`, set the new fingerprint as `FP_NETBOOT_XYZ` in `ipxe-build/build-ipxe.sh`, and push. The current CA is valid until 2035-11-15.
