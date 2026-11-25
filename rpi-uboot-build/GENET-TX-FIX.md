# U-Boot BCM2711 GENET TX Fix — RPi 4

## Symptom

U-Boot on Raspberry Pi 4 (PXE-booted via firmware) sends `BOOTP broadcast 1`
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
| **Upstream fix** | **None as of May 2026** — bug is unreported and unfixed upstream |

The commit immediately preceding it, [`57805f2`](https://github.com/u-boot/u-boot/commit/57805f2270c4a47cbc221e0920c58654f7748f0b)
(*"net: bcmgenet: Don't set ID_MODE_DIS when not using RGMII"*, May 2020), had
correctly handled non-RGMII modes. Commit `34873f4` then added `rgmii-rxid` to
the *same* `setbits` branch instead of a new `clrbits` branch — inverting the
semantics for that mode.

> **Confirmation**: EDK2's `BcmGenetDxe` (which works correctly) **clears**
> `ID_MODE_DIS` for `rgmii-rxid`:
> [edk2-platforms — BcmGenetDxe.c](https://github.com/tianocore/edk2-platforms/blob/master/Silicon/Broadcom/Bcm283x/Drivers/Net/BcmGenetDxe/BcmGenetDxe.c)

### Why only PXE-booted U-Boot is affected

The RPi 4 firmware PXE-boots U-Boot by downloading `u-boot.bin` over its own
GENET driver — completing ~32 TFTP transactions before handing off to U-Boot.
When U-Boot's `tx_ring_init()` starts, `TDMA_CONS_INDEX` is already at 32. The
original U-Boot code reads CONS and aligns PROD to it (`priv->tx_index =
readl(TDMA_CONS_INDEX)`), which is correct — `TDMA_CONS_INDEX` is **read-only**
on GENET v5/v6 (hardware-controlled). This is not a bug; the comment
*"cannot init TDMA_CONS_INDEX to 0"* was accurate.

## When is this a problem?

| Scenario | Affected? | Reason |
|---|---|---|
| **PXE boot → U-Boot → DHCP** (this repo's use case) | **Yes** | Firmware supplies its own DTB with `phy-mode = "rgmii-rxid"` (since Linux 5.4 / firmware late 2019); U-Boot inherits it |
| **SD card boot with firmware-provided DTB** (`arm64` mode, no explicit `device_tree=`) | **Yes** | Same DTB is appended to U-Boot by the firmware at boot time |
| **SD card boot with U-Boot's built-in DTB** (built without `EFI_HAVE_OFW_PCIE`) | **Depends** | If the built-in DTB uses `rgmii-rxid`, broken; if `rgmii`, unaffected |
| **Older firmware (pre-2020) or custom DTB with `rgmii`** | **No** | `interface != RGMII_RXID` — the buggy branch is never taken |
| **Pi 3 / Pi 3B+** | **No** | GENET not present; uses `smsc95xx` USB Ethernet |
| **Pi 5** | **Not tested** | BCM2712 has GENET v6; likely same bug if DTB uses `rgmii-rxid` |
| **SD card U-Boot, no DHCP needed** | **No** | Network never initialized; bug never fires |
| **1000BASE-T (1 Gbps)** | **Worst case** | Timing margin is smallest at 1 Gbps; 100 Mbps *may* work by accident |

### Summary

The bug fires when **all** of the following are true:
1. U-Boot on a **BCM2711 (Pi 4)** board uses the **GENET Ethernet driver** (`bcmgenet.c`)
2. The active device tree specifies **`phy-mode = "rgmii-rxid"`** for the GENET node
3. U-Boot version is **v2020.10 – v2026.10** (i.e. contains commit `34873f4` without a fix)
4. U-Boot actually **attempts network I/O** (e.g. `dhcp`, `tftpboot`, `ping`)

The most reliable trigger is: Pi 4 + current RPi firmware + any U-Boot built
from upstream after Sep 2020 + any command that uses the network.

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

Applied in `build.sh` as a Python source patch before compilation:

```python
content = content.replace(
    '\tif (phy_dev->interface == PHY_INTERFACE_MODE_RGMII ||\n'
    '\t    phy_dev->interface == PHY_INTERFACE_MODE_RGMII_RXID)\n'
    '\t\tsetbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);',
    '\tif (phy_dev->interface == PHY_INTERFACE_MODE_RGMII)\n'
    '\t\tsetbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);\n'
    '\telse\n'
    '\t\tclrbits_32(priv->mac_reg + EXT_RGMII_OOB_CTRL, ID_MODE_DIS);'
)
```

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
