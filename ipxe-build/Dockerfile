# Stage 1 compiles iPXE (in CI). Stage 2 is the small image that runs on the boot
# host and only copies the prebuilt files into place.

FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates openssl perl mtools liblzma-dev \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    genisoimage isolinux syslinux-common cpio \
    && rm -rf /var/lib/apt/lists/*

# Build settings. CI passes the values from build.env
# (see .github/workflows/build-ipxe.yml); the defaults allow a plain `docker build`.
ARG IPXE_REF=b847e5f0734f6130c6ee1a4cacdcff508e7aaa3e
ARG IPXE_PRODUCT_NAME=iPXE-mod
ARG IPXE_KEYBOARD_MAP=us
ARG IPXE_ON_FAILURE=reboot
ARG IPXE_IPV6=0
ARG IPXE_SERIAL_CONSOLE=bios
ARG IPXE_TRUST_NETBOOTXYZ=1
ARG IPXE_TLS_MAX=1.3
ARG IPXE_DEBUG=
ARG IPXE_BUILD_TAG=
ARG BUILD_EXTRA_IPXE_ARTIFACTS=0
ARG BUILD_OPTIONAL_IPXE_MEDIA=0

COPY build-ipxe.sh autoexec.ipxe /build/
COPY certs/ /build/certs/
COPY patches/ /build/patches/
RUN sh /build/build-ipxe.sh

FROM alpine:3.24

COPY --from=build /artifacts/ /assets/tftp/
COPY tftp/ /assets/tftp/
COPY dnsmasq.conf /assets/dnsmasq.conf
COPY stage.sh /stage.sh

ENTRYPOINT ["/bin/sh", "/stage.sh"]
