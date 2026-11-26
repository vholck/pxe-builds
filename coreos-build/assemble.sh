#!/bin/bash
# Puts together the TFTP tree of the coreos-stage image.
#
#   assemble.sh <store-dir> <out-dir>
#
# 1. Finds the last $KEEP (default 6) Fedora CoreOS stable releases.
# 2. For each, takes the extra initrd (or the ".none" marker that says the
#    release needs none) from <store-dir>; builds it with the coreos-build image
#    ($BUILD_IMAGE, default coreos-build) when missing. CI fills and saves
#    <store-dir> from the GitHub release "coreos-extra-initrds", so each release
#    is built only once.
# 3. Writes <out-dir>/tftp: the fixed files from tftp/ next to this script,
#    the extra initrds under coreos/initrd/, the newest release in
#    ipxe/coreos/fedora-coreos-stable.ipxe, and build-info/coreos/.
# 4. Prints "content=<hash>" of the tree (the image tag; same content, same tag).
set -euo pipefail

STORE=${1:?store dir}
OUT=${2:?out dir}
KEEP=${KEEP:-6}
BUILD_IMAGE=${BUILD_IMAGE:-coreos-build}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$STORE"
STORE=$(cd "$STORE" && pwd)

# Newest last in releases.json; keep releases that have an aarch64 build.
# Parsed with the build image's python3, so this script needs only docker
# (a Fedora CoreOS or Flatcar host has no python).
mapfile -t RELEASES < <(curl -fsSL --retry 3 https://builds.coreos.fedoraproject.org/prod/streams/stable/releases.json |
  docker run --rm -i --entrypoint python3 "$BUILD_IMAGE" -c '
import json, sys
rel = [r["version"] for r in json.load(sys.stdin)["releases"]
       if any(i.get("architecture") == "aarch64" for i in r.get("oci-images", []))]
print("\n".join(rel[-int(sys.argv[1]):]))' "$KEEP")
[ "${#RELEASES[@]}" -gt 0 ] || { echo "[assemble] no releases found" >&2; exit 1; }
NEWEST=${RELEASES[${#RELEASES[@]}-1]}
echo "[assemble] stable releases: ${RELEASES[*]}"

for v in "${RELEASES[@]}"; do
  n=fedora-coreos-$v-aarch64
  if [ -f "$STORE/$n.cpio" ] || [ -f "$STORE/$n.none" ]; then
    echo "[assemble] $v: from the store"
    continue
  fi
  echo "[assemble] $v: building"
  # as the calling user, so the files in the store are ours
  docker run --rm --user "$(id -u):$(id -g)" -v "$STORE:/out" "$BUILD_IMAGE" fedora-coreos "$v" /out
done

T=$OUT/tftp
rm -rf "$T"
mkdir -p "$T/coreos/initrd" "$T/ipxe/coreos" "$T/build-info/coreos"
cp -r "$HERE/tftp/." "$T/"
: > "$T/build-info/coreos/releases"
for v in "${RELEASES[@]}"; do
  n=fedora-coreos-$v-aarch64
  if [ -f "$STORE/$n.cpio" ]; then
    cp "$STORE/$n.cpio" "$T/coreos/initrd/"
    echo "$v extra-initrd" >> "$T/build-info/coreos/releases"
  else
    echo "$v none-needed" >> "$T/build-info/coreos/releases"
  fi
done

cat > "$T/ipxe/coreos/fedora-coreos-stable.ipxe" <<EOF
#!ipxe
# Newest Fedora CoreOS stable release in this image (written by
# coreos-build/assemble.sh). Used by ipxe/fcos.ipxe when no
# fcos_version is set.
set fcos_version $NEWEST
EOF

(cd "$T" && find . -type f ! -path ./build-info/coreos/files.sha256 | LC_ALL=C sort | xargs sha256sum) > "$T/build-info/coreos/files.sha256"
CONTENT=$(sha256sum "$T/build-info/coreos/files.sha256" | cut -c1-16)
echo "[assemble] newest: $NEWEST; content $CONTENT"
echo "content=$CONTENT"
echo "newest=$NEWEST"
