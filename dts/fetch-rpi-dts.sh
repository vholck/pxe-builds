#!/bin/sh
# Fetches the Linux device tree sources the Pi trees are built from:
# devicetree-rebasing (the device tree files of the Linux tree, one tag per
# Linux release), only the directories build-rpi-upstream.sh reads. Fails
# unless the tag points to the expected commit. Used by the Dockerfiles of
# rpi-uboot-build and rpi-uefi-build with RPI_DT_TAG and RPI_DT_COMMIT from the
# build.env at the repository root. See README.md.
#
# Usage: fetch-rpi-dts.sh <tag> <commit> <dir>
set -eu

tag=${1:?tag (RPI_DT_TAG) missing} commit=${2:?commit (RPI_DT_COMMIT) missing} dir=${3:?target dir missing}
url=https://git.kernel.org/pub/scm/linux/kernel/git/devicetree/devicetree-rebasing.git

git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" --sparse "$url" "$dir"
git -C "$dir" sparse-checkout set include src/arm64/broadcom src/arm/broadcom
got=$(git -C "$dir" rev-parse HEAD)
if [ "$got" != "$commit" ]; then
  echo "[fetch-rpi-dts] ERROR: $tag is $got, expected RPI_DT_COMMIT=$commit" >&2
  exit 1
fi
test -f "$dir/src/arm64/broadcom/bcm2712-rpi-5-b.dts"
echo "[fetch-rpi-dts] devicetree-rebasing $tag ($got)"
