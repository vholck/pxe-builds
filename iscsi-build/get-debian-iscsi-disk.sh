#!/bin/sh
# Prepare Debian as a base disk for the iscsi image: an x86-64 system (UEFI
# and BIOS) that boots from an iSCSI disk. Run on the Docker host (needs only
# Docker). <data dir> is the parent of the iscsi/ directory mounted at
# /srv/iscsi; the disk is written to <data dir>/iscsi/base/<name>.raw.
#
#   sh get-debian-iscsi-disk.sh <data dir> <ssh public key file> [name]
#   sh get-debian-iscsi-disk.sh /srv/pxe ~/.ssh/id_ed25519.pub
#
# It takes Debian 13's cloud image for any machine (debian-13-generic-amd64,
# from cloud.debian.org; checked against the SHA512SUMS published next to it)
# and writes <data dir>/iscsi/base/<name>.raw (default name: debian), a sparse
# disk of DISK_SIZE (default 4G; the root partition and file system fill it).
# In the disk:
#   - open-iscsi in the initramfs, which takes over the connection iPXE made
#     (iPXE leaves it in a firmware table, the iBFT: ISCSI_AUTO=true, modules
#     iscsi_ibft and iscsi_tcp) and all drivers (MODULES=most)
#   - the initramfs does no DHCP of its own: the address is the one iPXE got
#     and left in the iBFT (set by open-iscsi), not a second lease taken
#     without client identity (IP=off in /etc/initramfs-tools/conf.d)
#   - systemd-networkd keeps that address (KeepConfiguration) and renews it
#     by DHCP with the MAC address as client identity, as iPXE asked for it;
#     the boot waits for one network link, not all
#   - cloud-init off: there is no cloud to ask
#   - SSH with your key for root; host keys are made at the first boot, so
#     every copy gets its own; an empty machine ID (made at the first boot)
#   - no fixed hostname: at each boot the initramfs names the machine after
#     its disk (the part of the iSCSI target name after the last ':', e.g.
#     debian-02-00-00-00-00-01), so every copy has its own name without a
#     change in the disk. A name set in the machine (hostnamectl
#     set-hostname) wins. libnss-myhostname makes the name resolve
# ROOT_PASSWORD_HASH (optional, from "openssl passwd -6") gives root a
# password for the console; SSH stays key-only.
# The disk itself is not served. Make a machine's own disk from it with
#   docker exec <iscsi container> iscsi-disk copy <name> <machine>
# and boot it with the host script examples/iscsi-disk.ipxe.
# --privileged and /dev: the image is loop-mounted to change it.
set -eu

DATA=${1:?usage: get-debian-iscsi-disk.sh <pxe data dir> <ssh public key file> [name]}
KEY=${2:?usage: get-debian-iscsi-disk.sh <pxe data dir> <ssh public key file> [name]}
NAME=${3:-debian}
SIZE=${DISK_SIZE:-4G}

[ -d "$DATA" ] || { echo "no directory $DATA" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no file $KEY" >&2; exit 1; }
printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' \
  || { echo "invalid name '$NAME' (lower-case letters, digits, . and -)" >&2; exit 1; }
DATA=$(cd "$DATA" && pwd)
KEY=$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")
[ -e "$DATA/iscsi/base/$NAME.raw" ] && { echo "$DATA/iscsi/base/$NAME.raw exists; delete it first or give another name" >&2; exit 1; }

docker run --rm -i --privileged -v /dev:/dev -v "$DATA:/data" -v "$KEY:/key.pub:ro" \
  -e NAME="$NAME" -e SIZE="$SIZE" -e OWNER="$(id -u):$(id -g)" \
  -e ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}" \
  debian:trixie-slim sh -eu <<'EOF'
export DEBIAN_FRONTEND=noninteractive
dir=/data/iscsi/base
out=$dir/$NAME.raw
tmp=$out.partial
URL=https://cloud.debian.org/images/cloud/trixie/latest
IMG=debian-13-generic-amd64.qcow2
mkdir -p "$dir"
chown "$OWNER" /data/iscsi "$dir"

apt-get -q update >/dev/null
apt-get -q -y --no-install-recommends install curl ca-certificates qemu-utils fdisk e2fsprogs >/dev/null

cd /tmp
echo "[get-debian-iscsi-disk] downloading $IMG"
curl -fsSL --retry 3 -O "$URL/SHA512SUMS" -O "$URL/$IMG"
grep -q " $IMG\$" SHA512SUMS || { echo "$IMG not in SHA512SUMS" >&2; exit 1; }
grep " $IMG\$" SHA512SUMS | sha512sum -c -

loop=
cleanup() {
  umount /mnt/dev /mnt/sys /mnt/proc /mnt 2>/dev/null || true
  [ -z "$loop" ] || losetup -d "$loop" || true
  rm -f "$tmp"
}
trap cleanup EXIT

qemu-img convert -O raw "$IMG" "$tmp"
rm -f "$IMG"
qemu-img resize -q -f raw "$tmp" "$SIZE"
# Partition 1 (the root) is the last on the disk: grow it to the end. sfdisk
# also moves the backup GPT to the new end.
echo ', +' | sfdisk -q --no-reread -N 1 "$tmp"
loop=$(losetup -fP --show "$tmp")
i=0
while [ ! -b "${loop}p1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
e2fsck -fy "${loop}p1" >/dev/null 2>&1 || [ $? -le 1 ]
resize2fs "${loop}p1" >/dev/null 2>&1

mount "${loop}p1" /mnt
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount --bind /dev /mnt/dev
# DNS for apt in the chroot; the image's own resolv.conf (a link) comes back
mv /mnt/etc/resolv.conf /mnt/etc/resolv.conf.get-debian-iscsi-disk
cat /etc/resolv.conf > /mnt/etc/resolv.conf

chroot /mnt /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
  ROOT_PASSWORD_HASH="$ROOT_PASSWORD_HASH" NAME="$NAME" sh -eu <<'CHROOT'
apt-get -q update >/dev/null
apt-get -q -y -o Dpkg::Use-Pty=0 --no-install-recommends install open-iscsi libnss-myhostname >/dev/null

# The initramfs logs in to the disk from the iBFT that iPXE left
echo "ISCSI_AUTO=true" > /etc/iscsi/iscsi.initramfs
for m in iscsi_ibft iscsi_tcp; do
  grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
done
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
# The network card keeps the address from the iBFT. open-iscsi sets it
# ("iscsistart -N") and then runs initramfs-tools' configure_networking,
# which without ip= takes a second lease by DHCP (klibc's ipconfig, no client
# identity) and puts it in place of iPXE's; on a DHCP server that tells
# clients apart by client identity that is another address, which nothing
# renews (networkd renews iPXE's). open-iscsi reads conf.d again just before
# configure_networking, so this holds whatever the kernel command line says.
cat > /etc/initramfs-tools/conf.d/iscsi-ibft-address <<'CONF'
# Written by get-debian-iscsi-disk.sh: no DHCP in the initramfs; the address
# is the one iPXE left in the iBFT (open-iscsi sets it with iscsistart -N).
IP=off
CONF

# No cloud: cloud-init would wait for a data source and configured the
# network; systemd-networkd does that now.
touch /etc/cloud/cloud-init.disabled
cat > /etc/systemd/network/50-wired.network <<'NET'
# Written by get-debian-iscsi-disk.sh. Every wired network card by DHCP.
# KeepConfiguration: the root disk is reached over this network; the address
# the initramfs set is kept (never dropped, also not at shutdown).
# ClientIdentifier=mac: the same client ID as iPXE, so the DHCP server gives
# the address the initramfs already has (networkd's default DUID-based ID gets
# a second lease and a second address).
[Match]
Name=en* eth*

[Network]
DHCP=yes
KeepConfiguration=yes

[DHCPv4]
ClientIdentifier=mac
NET
# The boot waits for one network link to be up, not for every card
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf <<'NET'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any
NET
systemctl enable systemd-networkd.service >/dev/null 2>&1

# Each copy gets its own identity at its first boot: no SSH host keys (Debian's
# sshd-keygen.service makes missing ones before sshd starts), an initiator
# name made by open-iscsi, an empty machine ID.
# sshd-keygen.service runs only on systemd's "first boot" (machine ID missing
# or "uninitialized"); an empty machine ID is not one, and without keys ssh
# fails. The drop-in lets it run at every boot (ssh-keygen -A makes only
# missing keys). Not "uninitialized": that would also start
# systemd-firstboot (installed, with --prompt-*), which can ask on the console.
[ -f /usr/lib/systemd/system/sshd-keygen.service ] || { echo "no sshd-keygen.service in this image" >&2; exit 1; }
mkdir -p /etc/systemd/system/sshd-keygen.service.d
cat > /etc/systemd/system/sshd-keygen.service.d/every-boot.conf <<'KEYGEN'
# Written by get-debian-iscsi-disk.sh: make missing host keys at every boot,
# not only on systemd's first boot (the empty condition resets all of them).
[Unit]
ConditionFirstBoot=
ConditionPathIsReadWrite=/etc/ssh
KEYGEN
rm -f /etc/ssh/ssh_host_*
echo "GenerateName=yes" > /etc/iscsi/initiatorname.iscsi
if [ -f /etc/machine-id ]; then : > /etc/machine-id; fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ -n "$ROOT_PASSWORD_HASH" ]; then usermod -p "$ROOT_PASSWORD_HASH" root; fi

# No fixed hostname: every copy would have the base's. The initramfs sets the
# kernel's hostname from the name of the disk the machine booted from (iPXE
# leaves the target name in the iBFT); systemd keeps a hostname that is set
# when /etc/hostname does not give one. Plain sh only: the initramfs may have
# klibc's tools and no busybox.
rm -f /etc/hostname
cat > /etc/initramfs-tools/scripts/local-bottom/iscsi-hostname <<'HOOK'
#!/bin/sh
# Written by get-debian-iscsi-disk.sh: hostname from the iSCSI disk's name.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

# A hostname set in the machine wins
[ -s "${rootmnt}/etc/hostname" ] && exit 0
for f in /sys/firmware/ibft/target*/target-name; do
  [ -r "$f" ] || continue
  read -r name < "$f" || continue
  name=${name##*:}
  case "$name" in
    ''|*[!a-z0-9.-]*) continue ;;
  esac
  echo "$name" > /proc/sys/kernel/hostname 2>/dev/null || true
  break
done
exit 0
HOOK
chmod 755 /etc/initramfs-tools/scripts/local-bottom/iscsi-hostname

update-initramfs -u 2>&1 | tail -1
apt-get clean
CHROOT

cat /key.pub > /mnt/root/.ssh/authorized_keys
chmod 600 /mnt/root/.ssh/authorized_keys
rm -f /mnt/etc/resolv.conf
mv /mnt/etc/resolv.conf.get-debian-iscsi-disk /mnt/etc/resolv.conf
# Blocks freed by the changes become holes in the image file again
fstrim /mnt || true
umount /mnt/dev /mnt/sys /mnt/proc /mnt
losetup -d "$loop"
loop=
chown "$OWNER" "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "[get-debian-iscsi-disk] $out: $(du -h --apparent-size "$out" | cut -f1), $(du -h "$out" | cut -f1) used"
EOF
echo "next: docker exec <iscsi container> iscsi-disk copy $NAME <machine>, e.g. $NAME-<mac with hyphens>"
