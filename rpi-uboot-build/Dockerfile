FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── dependencies ──────────────────────────────────────────────────────────────
RUN apt-get update -qq && apt-get install -y -qq \
  bc \
  bison \
  flex \
  gcc \
  g++ \
  gcc-aarch64-linux-gnu \
  git \
  libgnutls28-dev \
  libssl-dev \
  make \
  python3 \
  python3-pyelftools \
  curl \
 && rm -rf /var/lib/apt/lists/*

# ── clone U-Boot ──────────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch v2026.10 https://github.com/u-boot/u-boot.git /build/u-boot

# ── upstream Linux device trees ───────────────────────────────────────────────
# Sources of the trees served as rpi/upstream/ (devicetree-rebasing, pinned in
# build.env; the same in rpi-uefi-build). The script comes from the named
# build context "dts" (dts/ at the repository root).
ARG RPI_DT_TAG
ARG RPI_DT_COMMIT
COPY --from=dts fetch-rpi-dts.sh /fetch-rpi-dts.sh
RUN sh /fetch-rpi-dts.sh "$RPI_DT_TAG" "$RPI_DT_COMMIT" /rpi-dts

# Source patches, applied by build.sh (see patches/README.md)
COPY patches/ /patches/
# Shared device tree sources (dts/ at the repository root), passed as the named
# build context "dts": docker build --build-context dts=<repo>/dts ...
COPY --from=dts . /dts/
COPY build.sh /build.sh
RUN chmod +x /build.sh
