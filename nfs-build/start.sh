#!/bin/sh
# Entry point of the nfs image. Serves two exports from the host directory
# mounted at /srv/nfs:
#   /rw  read-write: one root per machine (updatable and disposable roots,
#        LibreELEC's storage)
#   /ro  read-only: shared roots and the clean copies nfs-root resets from
# A layered root (nfs-root create --layered) appears under /rw too: the clean
# root from /ro plus the machine's changes, kept in /srv/nfs/layers.
# Clients mount <server>:/rw/<name> or :/ro/<name>, with NFSv4.2 or NFSv3.
# LAN_SUBNET (or NFS_CLIENTS) must be set: who may mount.
set -eu

DATA=/srv/nfs
PUID=${PUID:-500}
PGID=${PGID:-500}

# The data directories, owned by the host user (Docker creates a missing
# bind-mount source as root). Also while the service is off, so roots can be
# put in place before it is on.
for d in "$DATA" "$DATA/rw" "$DATA/ro" "$DATA/layers"; do
  mkdir -p "$d"
  if [ "$(stat -c %u "$d")" = 0 ]; then chown "$PUID:$PGID" "$d"; fi
done

if [ "${NFS_ENABLED:-0}" != 1 ]; then
  echo "[nfs] NFS_ENABLED=${NFS_ENABLED:-0}: not started"
  exec sleep infinity
fi

# Who may mount: NFS_CLIENTS (addresses, networks, host names; comma-separated),
# else the LAN subnet.
clients=${NFS_CLIENTS:-${LAN_SUBNET:?set LAN_SUBNET (or NFS_CLIENTS): the network allowed to mount}}

mkdir -p /etc/ganesha /var/lib/nfs/ganesha /run/ganesha /run/dbus /run/rpcbind
cat > /etc/ganesha/ganesha.conf <<EOF
# Written by start.sh at every start; settings come from the container's variables.
NFS_CORE_PARAM {
    Protocols = 3, 4;
    NFS_Port = 2049;
    MNT_Port = 20048;
    NLM_Port = 32803;
    Enable_RQUOTA = false;
    # TCP only. One UDP request (a client's first try at the NFSv3 mount
    # service) makes ganesha 6.5 in a container log "svc_dg_rendezvous: Bad
    # message sa_family is 0xffff" over 100000 times in seconds and fail the
    # request. Linux, the initramfs NFS client and iPXE all use TCP.
    Enable_UDP = false;
    # No lock manager for NFSv3 (it needs statd): NFSv3 clients mount with
    # "nolock", as a kernel NFS root does anyway. NFSv4 has locking built in.
    Enable_NLM = false;
    # NFSv3 clients mount the same paths as NFSv4 clients (/rw/..., /ro/...)
    Mount_Path_Pseudo = true;
}
MDCACHE {
    # No cache of directory contents: the roots are also changed in the data
    # directory, behind the server's back (nfs-root, scripts that unpack an OS,
    # an administrator). With the cache, a root that was deleted and made again
    # was served as the old, empty one for minutes, and iPXE found no kernel.
    Dir_Chunk = 0;
}
NFSV4 {
    # No grace period after a restart: clients reclaim nothing that matters
    # for a root file system, and the server restarts whenever its deployment does.
    Graceless = true;
    # Owners as numbers (uid/gid), as in the root file system itself: without
    # this, groups unknown to this container become "nobody" and system
    # services in the root fail.
    Allow_Numeric_Owners = true;
    Only_Numeric_Owners = true;
}
EXPORT_DEFAULTS {
    SecType = sys;
    # Root on the client is root in the export: a root file system needs it.
    Squash = No_Root_Squash;
    Protocols = 3, 4;
    Transports = TCP;
    Access_Type = None;
    # For the same reason: file attributes are read from the file system at
    # every request, not remembered for 60 seconds.
    Attr_Expiration_Time = 0;
}
EXPORT {
    Export_Id = 1;
    Path = $DATA/rw;
    Pseudo = /rw;
    CLIENT { Clients = $clients; Access_Type = RW; }
    FSAL { Name = VFS; }
}
EXPORT {
    Export_Id = 2;
    Path = $DATA/ro;
    Pseudo = /ro;
    CLIENT { Clients = $clients; Access_Type = RO; }
    FSAL { Name = VFS; }
}
LOG {
    Default_Log_Level = ${NFS_LOG_LEVEL:-EVENT};
}
# Layered roots (nfs-root create --layered): one export each
%include "/etc/ganesha/layers.conf"
EOF

# Layered roots are overlay mounts that live in this container: mount them
# again at every start and write their exports.
nfs-root mount-layers

echo "[nfs] $(cat /nfs-ganesha.version); exports /rw (read-write) and /ro (read-only) for $clients"

# dbus: ganesha's admin interface (it logs errors without it).
rm -f /run/dbus/pid
dbus-daemon --system --fork

# rpcbind first: ganesha registers its NFSv3 services (mount, NFS) with it
# at start. NFSv4 needs only port 2049.
rm -f /run/rpcbind.sock /run/rpcbind/rpcbind.lock
rpcbind -w
i=0
while [ ! -S /run/rpcbind.sock ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

ganesha.nfsd -F -L /dev/stdout -f /etc/ganesha/ganesha.conf &
pid=$!

# ganesha shuts down on SIGTERM. Wait for it (at most 5 s, then KILL), so
# "docker stop" ends within Docker's 10 s instead of killing it.
stop_ganesha() {
  kill "$pid" 2>/dev/null || true
  n=0
  while kill -0 "$pid" 2>/dev/null && [ $n -lt 25 ]; do
    sleep 0.2
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[nfs] ganesha did not end; killing it" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
on_term() {
  trap '' TERM INT
  echo "[nfs] stopping"
  [ -z "${sleeper:-}" ] || kill "$sleeper" 2>/dev/null || true
  stop_ganesha
  exit 0
}
trap on_term TERM INT

# When this container shares another container's network (network_mode:
# service:dnsmasq, as in examples/compose) and that container restarts by
# itself, it gets a new network and this one keeps the old, which then has
# only "lo". Exit then: the restart policy starts it again in the new network.
# The sleep runs in the background and the shell waits for it: a trap runs
# only after the foreground command ends, so a foreground "sleep 10" held off
# "docker stop" for up to 10 s. wait returns at once on TERM.
while kill -0 "$pid" 2>/dev/null; do
  sleep 10 &
  sleeper=$!
  wait "$sleeper" || true
  sleeper=
  if ! tail -n +3 /proc/net/dev | grep -qv '^ *lo:'; then
    echo "[nfs] shared network gone (its container restarted); restarting to rejoin it"
    trap '' TERM INT
    stop_ganesha
    exit 1
  fi
done
wait "$pid"
