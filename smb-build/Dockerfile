# SMB file server (SMB_ENABLED=1) for installation media: a read-only share
# from which Windows Setup, started over the network in Windows PE, reads
# its files (the contents of a Windows ISO).
# Built by .github/workflows/build-smb.yml; by hand:
#   docker build -t local/pxe-smb smb-build
FROM debian:trixie-slim

# samba: smbd only (no nmbd, no winbind, no AD DC); smbpasswd comes with
# samba-common-bin, a dependency. --no-install-recommends keeps out the
# printing and AD extras.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      samba \
 && rm -rf /var/lib/apt/lists/* /etc/samba/smb.conf \
 && dpkg-query -W -f='${Package} ${Version}\n' samba > /samba.version

COPY start.sh /start.sh

ENTRYPOINT ["/bin/sh", "/start.sh"]
