# Build environment for the Raspberry Pi UEFI firmware (EDK2). One image builds
# Pi 3, Pi 4 and Pi 5. Pi 3 and Pi 4 come from the pftf/RPi4 repository (its EDK2
# submodules also contain the Pi 3 platform). The Pi 5 platform is not in
# upstream EDK2; it comes from its own repository with its own EDK2 submodules.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq \
  acpica-tools \
  ca-certificates \
  curl \
  device-tree-compiler \
  g++ \
  gcc \
  gcc-aarch64-linux-gnu \
  git \
  libssl-dev \
  make \
  python3 \
  uuid-dev \
 && rm -rf /var/lib/apt/lists/*

# Pinned source: this commit of pftf/RPi4 fixes the commits of its edk2,
# edk2-platforms and edk2-non-osi submodules. Bump deliberately, then rebuild and
# boot-test; set in build.env as PFTF_REF.
ARG PFTF_REPO=https://github.com/pftf/RPi4.git
ARG PFTF_REF=3db317e8428bc43211ba5dbc0cad01143a565ef7

RUN git init -q /build && cd /build && \
    git remote add origin "$PFTF_REPO" && \
    git fetch -q --depth 1 origin "$PFTF_REF" && \
    git checkout -q FETCH_HEAD && \
    ( git submodule update --init --recursive --depth 1 || \
      git submodule update --init --recursive ) && \
    du -sh /build
# Shallow submodules (--depth 1) keep the image several GB smaller. The fallback
# to full history covers a submodule server that refuses to serve a single commit.

RUN make -C /build/edk2/BaseTools

# Pi 5: the EDK2 port by the worproject (archived), as maintained in the
# NumberOneGit fork, which also covers the newer D0 boards, the CM5 and the
# Pi 500. This commit fixes the commits of its edk2, edk2-platforms,
# edk2-non-osi and arm-trusted-firmware submodules. Set in build.env as
# RPI5_UEFI_REF.
ARG RPI5_UEFI_REPO=https://github.com/NumberOneGit/rpi5-uefi.git
ARG RPI5_UEFI_REF=ad501cf3aeb7060b1ce0324b9d8972a4daf19b38

RUN git init -q /build5 && cd /build5 && \
    git remote add origin "$RPI5_UEFI_REPO" && \
    git fetch -q --depth 1 origin "$RPI5_UEFI_REF" && \
    git checkout -q FETCH_HEAD && \
    ( git submodule update --init --recursive --depth 1 || \
      git submodule update --init --recursive ) && \
    du -sh /build5

RUN make -C /build5/edk2/BaseTools

# Pi 5: Trusted Firmware-A (BL31, the first stage of the firmware image), pinned
# separately from the port: its submodule (000fe22, 2025-07-11) lacks upstream's
# CVE-2025-10263 workaround for the Pi 5. This upstream tag replaces
# the submodule's checkout; the build fails unless the tag is the expected
# commit. Set in build.env as RPI5_TFA_TAG and RPI5_TFA_COMMIT; an empty
# RPI5_TFA_TAG keeps the port's own submodule.
ARG RPI5_TFA_REPO=https://github.com/ARM-software/arm-trusted-firmware.git
ARG RPI5_TFA_TAG=lts-v2.14.15
ARG RPI5_TFA_COMMIT=28b7463297f5563318b3656f0a003e82183510a2
RUN if [ -n "$RPI5_TFA_TAG" ]; then \
      rm -rf /build5/arm-trusted-firmware && \
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$RPI5_TFA_TAG" \
        "$RPI5_TFA_REPO" /build5/arm-trusted-firmware && \
      got=$(git -C /build5/arm-trusted-firmware rev-parse HEAD) && \
      if [ "$got" != "$RPI5_TFA_COMMIT" ]; then \
        echo "ERROR: TF-A $RPI5_TFA_TAG is $got, expected RPI5_TFA_COMMIT=$RPI5_TFA_COMMIT" >&2; exit 1; \
      fi && \
      echo "Trusted Firmware-A $RPI5_TFA_TAG ($got)"; \
    else \
      echo "Trusted Firmware-A from the rpi5-uefi submodule: $(git -C /build5/arm-trusted-firmware rev-parse HEAD)"; \
    fi

# iPXE built as a UEFI driver for the onboard Ethernet the EDK2 platforms have no
# driver for:
#  - Pi 3: the USB Ethernet chip (LAN9514 on the 3B, LAN7515 on the 3B+). iPXE
#    reaches it through the firmware's own USB stack (USB_HCD_USBIO, the same
#    setting as iPXE's "rpi" configuration). patches/rpi3 puts the result into
#    the firmware image.
#  - Pi 5: the Ethernet controller in the RP1 chip. patches/ipxe adds the driver,
#    patches/rpi5 puts the result into the firmware image.
# Set in build.env as UEFI_IPXE_REF.
# patches/ipxe/*.patch are applied to the iPXE sources first; one that no longer
# applies fails the build.
# EFI_DOWNGRADE_UX: the driver only drives the network chip and offers no boot
# option of its own. Without it, it adds "UEFI PXEv4 (MAC:...)", which runs iPXE
# inside the firmware, beside the firmware's own "UEFI PXEv4 ... 2": after iPXE
# handed back, the second one started iPXE and the menu again. The firmware's PXE
# client finds the link up thanks to patches/ipxe/0003.
ARG UEFI_IPXE_REF=b847e5f0734f6130c6ee1a4cacdcff508e7aaa3e
COPY patches/ipxe/ /patches-ipxe/
RUN git init -q /ipxe && cd /ipxe && \
    git remote add origin https://github.com/ipxe/ipxe.git && \
    git fetch -q --depth 1 origin "$UEFI_IPXE_REF" && \
    git checkout -q FETCH_HEAD && \
    for p in /patches-ipxe/*.patch; do \
      [ -f "$p" ] || continue; \
      git apply --check "$p" && git apply "$p" && echo "applied $(basename "$p")" || exit 1; \
    done && \
    cd src && mkdir -p config/local && \
    printf '%s\n' '#undef USB_EFI' '#define USB_HCD_USBIO' > config/local/usb.h && \
    printf '%s\n' '#define EFI_DOWNGRADE_UX' > config/local/general.h && \
    make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-gnu- \
      bin-arm64-efi/smsc95xx--lan78xx.efidrv bin-arm64-efi/rp1gem.efidrv && \
    cp bin-arm64-efi/smsc95xx--lan78xx.efidrv /build/ipxe-usbnic.efi && \
    cp bin-arm64-efi/rp1gem.efidrv /build5/ipxe-rp1gem.efi && \
    rm -rf bin-arm64-efi && \
    test -s /build/ipxe-usbnic.efi && test -s /build5/ipxe-rp1gem.efi

# Pi 5: sources of the upstream Linux device trees (devicetree-rebasing, pinned
# in build.env; the same in rpi-uboot-build, so both firmwares serve the
# same trees). build.sh builds them with the RP1's UART0 added, using the
# shared sources in dts/ at the repository root, passed as the named build
# context "dts": docker build --build-context dts=<repo>/dts ...
ARG RPI_DT_TAG
ARG RPI_DT_COMMIT
COPY --from=dts fetch-rpi-dts.sh /fetch-rpi-dts.sh
RUN sh /fetch-rpi-dts.sh "$RPI_DT_TAG" "$RPI_DT_COMMIT" /rpi-dts
COPY --from=dts . /dts/

# Source patches, applied by build.sh (see patches/README.md)
COPY patches/ /patches/
COPY build.sh /build.sh

ENTRYPOINT ["/bin/bash", "/build.sh"]
