#!/bin/sh
# Entry point of the smb image. Serves the host directory mounted at /srv/smb
# as the read-only SMB share "install" on port 445:
#   /srv/smb/<name>/      contents of an installation ISO (Windows: setup.exe,
#                         sources/install.wim, ...)
#   /srv/smb/unattend/    answer files (autounattend.xml) for Windows Setup
# Clients connect as \\<server>\install with SMB_USER and SMB_PASSWORD.
# Windows refuses guest access to SMB2/3 shares by default (and Windows 11
# 24H2 and Server 2025 require signing, which a guest session cannot do), so
# the share has a user and password, not guest access. The share is
# read-only; the password keeps out nobody who can read the boot server's
# HTTP files, it only satisfies Windows.
# LAN_SUBNET (or SMB_CLIENTS) must be set: who may connect.
set -eu

DATA=/srv/smb
PUID=${PUID:-500}
PGID=${PGID:-500}

# The data directories, owned by the host user (Docker creates a missing
# bind-mount source as root). Also while the service is off, so media can be
# put in place before it is on.
for d in "$DATA" "$DATA/unattend"; do
  mkdir -p "$d"
  if [ "$(stat -c %u "$d")" = 0 ]; then chown "$PUID:$PGID" "$d"; fi
done

if [ "${SMB_ENABLED:-0}" != 1 ]; then
  echo "[smb] SMB_ENABLED=${SMB_ENABLED:-0}: not started"
  exec sleep infinity
fi

clients=${SMB_CLIENTS:-${LAN_SUBNET:?set LAN_SUBNET (or SMB_CLIENTS): the network allowed to connect}}
user=${SMB_USER:-install}
: "${SMB_PASSWORD:?set SMB_PASSWORD: Windows does not connect to a share without a password}"

# hosts allow: a.b.c.d/n becomes a.b.c.d/netmask (the form smb.conf(5) documents)
allow=""
for c in $(echo "$clients" | tr ',' ' '); do
  case "$c" in
    */*.*) ;;                                   # already network/netmask
    */*) n=${c#*/}; m=""; i=0
         while [ $i -lt 4 ]; do
           b=$(( n >= 8 ? 8 : (n > 0 ? n : 0) )); n=$(( n - b ))
           m="$m${m:+.}$(( 256 - (1 << (8 - b)) ))"; i=$((i + 1))
         done
         c="${c%/*}/$m" ;;
  esac
  allow="$allow $c"
done

# The account the clients log in with: the host user's uid, so smbd reads the
# files as their owner. Made again at every start; the password database
# lives only in the container.
if ! id "$user" >/dev/null 2>&1; then
  groupadd -o -g "$PGID" "$user" 2>/dev/null || true
  useradd -M -o -u "$PUID" -g "$PGID" -d /nonexistent -s /usr/sbin/nologin "$user"
fi

mkdir -p /etc/samba /run/samba /var/lib/samba/private /var/cache/samba /var/log/samba
cat > /etc/samba/smb.conf <<EOF
# Written by start.sh at every start; settings come from the container's variables.
[global]
   server role = standalone server
   server string = install media
   workgroup = WORKGROUP
   # SMB over TCP 445 only: no NetBIOS name service (nmbd), no port 139
   disable netbios = yes
   smb ports = 445
   # Windows PE of Windows 10 and newer speaks SMB 3.1.1; no SMB1
   server min protocol = SMB2_10
   security = user
   map to guest = never
   restrict anonymous = 2
   passdb backend = tdbsam:/var/lib/samba/private/passdb.tdb
   # Signing when the client asks for it (Windows 11 24H2 and Server 2025
   # require it); no encryption required (it costs speed on a read-only share)
   server signing = default
   hosts allow =$allow 127.0.0.1
   hosts deny = ALL
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log level = ${SMB_LOG_LEVEL:-1}
   # Large sequential reads (install.wim): sendfile and asynchronous reads
   use sendfile = yes
   aio read size = 1

[install]
   path = $DATA
   read only = yes
   browseable = yes
   valid users = $user
   follow symlinks = no
   # The files keep the modes they were unpacked with (no execute bits);
   # Windows refuses to run setup.exe from the share without this
   acl allow execute always = yes
EOF

printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s -a "$user" >/dev/null
testparm -s --suppress-prompt >/dev/null

printf '[smb] %s; share \\\\<this server>\\install = %s (read-only), user %s, for%s\n' "$(cat /samba.version)" "$DATA" "$user" "$allow"

# smbd in the foreground, log to stdout; it forks one process per client.
rm -f /run/samba/smbd.pid
smbd --foreground --no-process-group --debug-stdout &
pid=$!

# smbd ends its clients and itself on SIGTERM.
stop_smbd() {
  kill "$pid" 2>/dev/null || true
  n=0
  while kill -0 "$pid" 2>/dev/null && [ $n -lt 25 ]; do
    sleep 0.2
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[smb] smbd did not end; killing it" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
on_term() {
  trap '' TERM INT
  echo "[smb] stopping"
  [ -z "${sleeper:-}" ] || kill "$sleeper" 2>/dev/null || true
  stop_smbd
  exit 0
}
trap on_term TERM INT

# Same watch as the nfs and iscsi images: when the container whose network
# this one shares (network_mode: service:dnsmasq) restarts by itself, only
# "lo" is left here. Exit then; the restart policy starts it in the new one.
while kill -0 "$pid" 2>/dev/null; do
  sleep 10 &
  sleeper=$!
  wait "$sleeper" || true
  sleeper=
  if ! tail -n +3 /proc/net/dev | grep -qv '^ *lo:'; then
    echo "[smb] shared network gone (its container restarted); restarting to rejoin it"
    trap '' TERM INT
    stop_smbd
    exit 1
  fi
done
wait "$pid"
