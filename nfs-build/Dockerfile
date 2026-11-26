# NFS server (NFS_ENABLED=1) for root file systems of diskless machines.
# User-space nfs-ganesha, so the host needs no kernel NFS server or module.
# Built by .github/workflows/build-nfs.yml; by hand:
#   docker build -t local/pxe-nfs nfs-build
FROM debian:trixie-slim

# nfs-ganesha + its VFS back end (exports a local directory); rpcbind for
# NFSv3; netbase for /etc/services (without it the RPC library cannot find
# rpcbind and NFSv3 is not registered); dbus for ganesha's admin interface;
# openssh-client for nfs-root (new SSH host keys for a copied root).
# Ganesha from trixie-backports, not trixie's 6.5: 6.5 answers the NFSv4.1
# operation GET_DIR_DELEGATION with OP_ILLEGAL, which Linux 6.19 and newer
# (they ask for directory delegations by default) turn into "Remote I/O
# error" on every directory lookup; Ubuntu 26.04 could not boot from an
# NFSv4 root. Fixed upstream in V7.0 (commit 98eb77c).
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' \
      > /etc/apt/sources.list.d/backports.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      -t trixie-backports nfs-ganesha nfs-ganesha-vfs \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      rpcbind netbase dbus openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W -f='${Package} ${Version}\n' nfs-ganesha > /nfs-ganesha.version

COPY start.sh /start.sh
COPY nfs-root /usr/local/bin/nfs-root
RUN chmod 755 /usr/local/bin/nfs-root

ENTRYPOINT ["/bin/sh", "/start.sh"]
