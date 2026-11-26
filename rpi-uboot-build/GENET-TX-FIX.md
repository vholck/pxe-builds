# U-Boot BCM2711 GENET TX Fix — RPi 4

## Symptom

On the tested Raspberry Pi 4, U-Boot netbooted by the Pi firmware sends `BOOTP broadcast 1`
but receives no DHCP response. `tcpdump` on the LAN shows zero packets from the
Pi 4's MAC address. The UMAC MIB TX counter at `0xfd580ca8`
increments (proving the MAC controller transmits), but frames never reach the
wire.

## Investigation

1. **Symptom isolation** — `tcpdump` on the LAN switch showed zero packets from
   the Pi 4's MAC address. U-Boot was calling `dhcp` and reporting no response,
   but the problem wasn't higher-layer (DHCP server, network config) — nothing
   at all was arriving on the wire.

2. **MAC vs PHY** — The UMAC MIB TX packet counter at `0xfd580ca8` was
   incrementing with each BOOTP attempt. The MAC controller was *transmitting*;
   the frames were being lost between the MAC output and the PHY. This pointed
   to an RGMII clock/timing misconfiguration at the MAC–PHY boundary.

3. **Cross-referencing EDK2** — EDK2's `BcmGenetDxe` drives the same GENET
   hardware and works correctly. Comparing its `EXT_RGMII_OOB_CTRL` handling
   showed it **clears** `ID_MODE_DIS` for `rgmii-rxid`, while U-Boot **sets**
   it — the exact opposite.

4. **Commit archaeology** — `git log drivers/net/bcmgenet.c` identified commit
   [`34873f4`](https://github.com/u-boot/u-boot/commit/34873f46bacb039a1f7f8d8147664150bfec2a2d)
   (*"bcmgenet: Add support for rgmii-rxid"*, Sep 8 2020) as the introduction
   point. It added `rgmii-rxid` to the same `setbits` branch as plain `rgmii`
   instead of creating a new `clrbits` branch — inverting the timing semantics.

5. **Register confirmation** — Reading `EXT_RGMII_OOB_CTRL` live via U-Boot
   `md` showed `0x00f10050` (bit 16 = `ID_MODE_DIS` = 1, broken). After
   applying the fix and rebuilding, the value was `0x00f00050` (bit 16 = 0),
   and DHCP completed immediately.

## Root Cause

### `ID_MODE_DIS` bug in `bcmgenet_adjust_link()`

In `drivers/net/bcmgenet.c`, the function `bcmgenet_adjust_link()` sets
`ID_MODE_DIS` (bit 16 of `EXT_RGMII_OOB_CTRL`, MMIO `0xfd58008c`) for **both**
`PHY_INTERFACE_MODE_RGMII` and `PHY_INTERFACE_MODE_RGMII_RXID`:

```c
/* BUGGY upstream code */
if (phy_dev->interface == PHY_INTERFACE_MODE_RGMII ||
    phy_dev->interface == PHY_INTERFACE_MODE_RGMII_RXID)
    setbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);
```

| Interface    | `ID_MODE_DIS` meaning | Correct value |
|---|---|---|
| `rgmii`      | Disable internal RX delay — correct, PHY provides delay externally | **1** (set) |
| `rgmii-rxid` | MAC provides internal RX delay — `ID_MODE_DIS=1` disables it       | **0** (clear) |

The RPi 4 device tree declares `phy-mode = "rgmii-rxid"`. With `ID_MODE_DIS=1`,
the RGMII TX clock alignment at 1 Gbps is wrong. The BCM54213PE PHY receives
mis-timed RGMII data and silently drops all frames.

### Bug provenance

| | |
|---|---|
| **File** | `drivers/net/bcmgenet.c` |
| **Function** | `bcmgenet_adjust_link()` |
| **Buggy lines** | ~457–459 (varies slightly by version; search for `RGMII_RXID)\n\t\tsetbits_32`) |
| **Introduced by** | commit [`34873f4`](https://github.com/u-boot/u-boot/commit/34873f46bacb039a1f7f8d8147664150bfec2a2d) — *"bcmgenet: Add support for rgmii-rxid"*, Sep 8 2020 (Jason Wessel / Matthias Brugger) |
| **First affected release** | v2020.10-rc5 |
| **Last verified affected** | v2026.10 (the affected lines are unchanged there; the file has not been touched for this bug since 2020) |
| **Upstream fix** | None in master (checked 2026-11-25). A related patch for the same case (U-Boot after a firmware netboot) resets the PHY instead; see UPSTREAM-TRACKING.md |

The commit immediately preceding it, [`57805f2`](https://github.com/u-boot/u-boot/commit/57805f2270c4a47cbc221e0920c58654f7748f0b)
(*"net: bcmgenet: Don't set ID_MODE_DIS when not using RGMII"*, May 2020), had
correctly handled non-RGMII modes. Commit `34873f4` then added `rgmii-rxid` to
the *same* `setbits` branch instead of a new `clrbits` branch — inverting the
semantics for that mode.

> **Confirmation**: EDK2's `BcmGenetDxe` (which works correctly) **clears**
> `ID_MODE_DIS` for `rgmii-rxid`:
> [edk2-platforms — BcmGenetDxe.c](https://github.com/tianocore/edk2-platforms/blob/master/Silicon/Broadcom/Bcm283x/Drivers/Net/BcmGenetDxe/BcmGenetDxe.c)

### Scope: what was tested

The failure was seen and the fix verified on one Pi 4 board, with U-Boot
netbooted by the Pi firmware, at 1 Gbit/s. Not tested: U-Boot started from an
SD card, and 100 Mbit/s links. Another report of the same case (U-Boot after a
firmware netboot, Pi 4B) describes an unstable network with DHCP retries and
TFTP timeouts rather than a dead one, and a stable network when the same files
start from an SD card. So the state the firmware leaves the PHY in plays a part;
the register value above is still wrong for `rgmii-rxid` either way, and Linux
clears it.

## When can it apply?

The wrong register value is set when **all** of these are true:

1. U-Boot on a **BCM2711 (Pi 4, Pi 400, CM4)** uses the **GENET** driver (`bcmgenet.c`).
2. The active device tree says **`phy-mode = "rgmii-rxid"`**, as the Raspberry Pi firmware's tree does.
3. The U-Boot version contains commit `34873f4` (v2020.10 and later) without a fix.
4. U-Boot uses the network (`dhcp`, `tftpboot`, `ping`, ...).

Not affected: the Pi 3 (USB Ethernet, `smsc95xx`/`lan78xx`) and the Pi 5
(its Ethernet is the Cadence MAC in the RP1 chip, not GENET). Whether the
wrong value breaks the link in every setup is not known; it did on the tested
board after a firmware netboot.

## Fix

Change `bcmgenet_adjust_link()` to only set `ID_MODE_DIS` for plain `rgmii`,
and explicitly **clear** it for `rgmii-rxid`:

```c
/* Fixed code */
if (phy_dev->interface == PHY_INTERFACE_MODE_RGMII)
    setbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);
else
    clrbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);
```

`build.sh` applies it before compilation as
[patches/0001-bcmgenet-clear-ID_MODE_DIS-for-rgmii-rxid.patch](patches/0001-bcmgenet-clear-ID_MODE_DIS-for-rgmii-rxid.patch).

## Verification

After applying the fix and rebuilding:

```
BOOTP broadcast 1
DHCP client bound to address 192.168.1.71 (44 ms)
TFTP from server 192.168.1.202; our IP address is 192.168.1.71
Filename 'snponly-arm64-rpi.efi'.
Loading: ##################################################  324.5 KiB
Bytes transferred = 332288 (51200 hex)
```

Full PXE chain: firmware → U-Boot → DHCP → TFTP → iPXE → netboot.xyz.

## Register Map (BCM2711 GENET v5, base `0xfd580000`)

| Register | Offset | ARM address | Value (broken) | Value (fixed) |
|---|---|---|---|---|
| `EXT_RGMII_OOB_CTRL` | `0x008c` | `0xfd58008c` | `0x00f10050` (ID_MODE_DIS=1) | `0x00f00050` (ID_MODE_DIS=0) |
| `UMAC_CMD` | `0x0808` | `0xfd580808` | `0x00000008` (1Gbps, TX/RX_EN=0 after halt) | same |
| MIB TX packets | `0x0ca8` | `0xfd580ca8` | increments but no wire traffic | increments + wire traffic |

## References

- U-Boot `bcmgenet.c` upstream:
  <https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c>
- BCM2711 peripherals datasheet (GENET / RGMII_OOB_CTRL):
  <https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf>
- EDK2 `BcmGenetDxe` (reference correct rgmii-rxid handling):
  <https://github.com/tianocore/edk2-platforms/blob/master/Silicon/Broadcom/Bcm283x/Drivers/Net/BcmGenetDxe/BcmGenetDxe.c>
- Linux `bcmgenet.c` (same ID_MODE_DIS logic, correct for reference):
  <https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/broadcom/genet/bcmgenet.c>
