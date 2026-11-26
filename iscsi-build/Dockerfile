# iSCSI target (ISCSI_ENABLED=1): one network disk per machine. User-space
# tgt, so the host needs no kernel iSCSI target (LIO) or module, and the
# container is not privileged.
# Built by .github/workflows/build-iscsi.yml; by hand:
#   docker build -t local/pxe-iscsi iscsi-build
FROM debian:trixie-slim

# tgt: the iSCSI target (tgtd) and its admin tool (tgtadm); qemu-utils for
# qemu-img (empty disks; converting other image formats by hand).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tgt qemu-utils \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W -f='${Package} ${Version}\n' tgt > /tgt.version

COPY start.sh /start.sh
COPY iscsi-disk /usr/local/bin/iscsi-disk
RUN chmod 755 /usr/local/bin/iscsi-disk

ENTRYPOINT ["/bin/sh", "/start.sh"]
