#!/bin/sh
# Entry point of the iscsi image. Serves network disks from the host directory
# mounted at /srv/iscsi:
#   base/<name>.raw   installed systems that machine disks are copied from
#                     (not served)
#   disks/<name>.raw  one disk per machine, served as the iSCSI target
#                     <ISCSI_IQN>:<name>, the disk at LUN 1
# iPXE boots one with sanboot iscsi:<server>:::1:<ISCSI_IQN>:<name>.
# Disks are made, reset and deleted with iscsi-disk (docker exec <iscsi
# container> iscsi-disk). LAN_SUBNET (or ISCSI_CLIENTS) must be set.
set -eu

DATA=/srv/iscsi
PUID=${PUID:-500}
PGID=${PGID:-500}

# The data directories, owned by the host user (Docker creates a missing
# bind-mount source as root). Also while the service is off, so disks can be
# put in place before it is on.
for d in "$DATA" "$DATA/base" "$DATA/disks"; do
  mkdir -p "$d"
  if [ "$(stat -c %u "$d")" = 0 ]; then chown "$PUID:$PGID" "$d"; fi
done

if [ "${ISCSI_ENABLED:-0}" != 1 ]; then
  echo "[iscsi] ISCSI_ENABLED=${ISCSI_ENABLED:-0}: not started"
  exec sleep infinity
fi

echo "[iscsi] $(cat /tgt.version); disks from $DATA/disks for ${ISCSI_CLIENTS:-${LAN_SUBNET:?set LAN_SUBNET (or ISCSI_CLIENTS): the network allowed to connect}}"

# tgtd in the foreground (log to stderr), on port 3260 of every address of
# the container's network.
mkdir -p /run/tgtd
rm -f /run/tgtd/socket.*
tgtd -f &
pid=$!

# Stop as upstream's tgtd.service does (ExecStop): system offline, every
# target offline, targets deleted with --force (closes the open sessions),
# then "delete --mode system", which ends tgtd once no target is left.
# tgtd ignores SIGTERM (its handler is empty, usr/tgtd.c), so a plain kill
# never ends it and "docker stop" waited 10 s and killed it.
# KILL only as a last resort, after 5 s.
stop_tgtd() {
  tgtadm --op update --mode sys --name State -v offline 2>/dev/null || true
  tids=$(tgtadm --lld iscsi --op show --mode target 2>/dev/null \
    | awk '$1 == "Target" { sub(":", "", $2); print $2 }') || true
  for tid in $tids; do
    tgtadm --lld iscsi --op update --mode target --tid "$tid" -n state -v offline 2>/dev/null || true
  done
  for tid in $tids; do
    tgtadm --lld iscsi --op delete --force --mode target --tid "$tid" 2>/dev/null || true
  done
  tgtadm --op delete --mode system 2>/dev/null || true
  n=0
  while kill -0 "$pid" 2>/dev/null && [ $n -lt 25 ]; do
    sleep 0.2
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[iscsi] tgtd did not end; killing it" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
on_term() {
  trap '' TERM INT
  echo "[iscsi] stopping: closing sessions, ending tgtd"
  [ -z "${sleeper:-}" ] || kill "$sleeper" 2>/dev/null || true
  stop_tgtd
  exit 0
}
trap on_term TERM INT

i=0
until tgtadm --lld iscsi --op show --mode sys >/dev/null 2>&1; do
  i=$((i + 1))
  if [ $i -ge 50 ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "[iscsi] tgtd did not start" >&2
    exit 1
  fi
  sleep 0.2
done

# Targets live only in tgtd: publish every disk again at each start.
iscsi-disk publish-all || echo "[iscsi] some disks were not published (see above)" >&2

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
    echo "[iscsi] shared network gone (its container restarted); restarting to rejoin it"
    trap '' TERM INT
    stop_tgtd
    exit 1
  fi
done
wait "$pid"
