# Bug report draft: dracut-ng leaves out rp1_pci, Raspberry Pi 5 network boot fails

Not posted yet. For [dracut-ng](https://github.com/dracut-ng/dracut-ng/issues), with a short note to [fedora-coreos-tracker](https://github.com/coreos/fedora-coreos-tracker/issues) pointing to it. Facts checked 2026-11-21.

---

**Title:** kernel-modules: include drivers/misc/rp1 on arm (Raspberry Pi 5 Ethernet needs rp1_pci)

**Summary.** On a Raspberry Pi 5 the on-board Ethernet MAC (Cadence GEM, `macb`) sits behind the RP1 south bridge, a PCIe device. Linux reaches the RP1's peripherals through `rp1_pci` (`drivers/misc/rp1/`, `CONFIG_MISC_RP1`). An initramfs built with the generic `kernel-modules` dracut module contains `clk-rp1`, `pinctrl-rp1`, `macb` and `macb_pci`, but not `rp1_pci`, so the Ethernet never appears in the initramfs. Every network root (`rd.neednet`, NFS, iSCSI, live PXE images that fetch their root file system) fails on the Pi 5.

**Where.** `modules.d/70kernel-modules/module-setup.sh`, the arm/aarch64 branch of `installkernel()`: the list of driver directories includes `=drivers/clk`, `=drivers/pinctrl`, `=drivers/mfd`, `=drivers/soc`, `=drivers/phy` and others, but not `=drivers/misc` or `=drivers/misc/rp1`. (The other RP1 drivers are found through `drivers/clk` and `drivers/pinctrl`.)

**Seen with.** Fedora CoreOS stable 45.20261030.3.1 (kernel 7.2.11-300.fc45.aarch64), live PXE: `rp1_pci.ko` is listed in `modules.order` of the initramfs but the file is missing; `nm-wait-online-initrd` times out, no root file system. Fedora's kernel builds it as a module (`CONFIG_MISC_RP1=m`, `COMMON_CLK_RP1=m`, `PINCTRL_RP1=m`, `MACB=m`, `MACB_PCI=m` in `kernel-aarch64-fedora.config`, f45 and rawhide). The Fedora 44 Raspberry Pi 5 Minimal image (kernel 6.19.8) has the same gap in its initramfs; it goes unnoticed there because a disk boot loads the module later from the root file system.

**Proof that the module is all that is missing.** An extra initrd holding `rp1_pci.ko.xz` from the same kernel package plus module lists regenerated with `depmod -b` over the initramfs's module tree, with `rd.driver.pre=rp1_pci`: the live system gets its address over the RP1 Ethernet and boots to a login, on the Pi 5 under U-Boot and under UEFI firmware.

**Proposed fix.** Add `"=drivers/misc/rp1"` (narrow) to the arm list in `installkernel()`. The same kind of change as recent single-driver additions (for example "include xhci-pci-prom21", 2026-07-23). `drivers/misc` as a whole would pull in many unrelated modules.

**Workaround.** The extra initrd above (script: `coreos-build/build-extra-initrd.sh` in this repository), or `rd.driver.pre=rp1_pci` with an initramfs rebuilt with `--add-drivers rp1_pci` where the initramfs can be rebuilt.

---

Note for fedora-coreos-tracker: "Raspberry Pi 5: live PXE has no network because the initramfs lacks rp1_pci (dracut-ng issue #…); workaround: extra initrd with the module."
