#!/bin/sh
# Prepare Raspberry Pi OS Lite (64-bit, trixie) as a base disk for the iscsi
# image: a Raspberry Pi 5 (kernel_2712) whose root is an iSCSI disk. Run on
# the Docker host (needs only Docker; on a non-arm64 host the package step
# runs under QEMU, registered for the duration of the script).
#
#   sh get-raspios-iscsi-disk.sh <data dir> <ssh public key file> [name]
#
# Writes <data dir>/iscsi/base/<name>.raw (default name raspios, DISK_SIZE
# default 8G) and the boot files <data dir>/matchbox/assets/raspios-iscsi/
# <name>/{kernel_2712.img,initramfs_2712}, which Matchbox serves to iPXE.
#
# Why not sanboot as on x86: a Pi under U-Boot has no ACPI. iPXE's EFI SAN
# boot describes the disk in an ACPI table (iBFT) through
# EFI_ACPI_TABLE_PROTOCOL, which U-Boot does not offer ("Could not describe
# SAN devices"), and Raspberry Pi's kernel has no ACPI and so no iscsi_ibft.
# Instead the profile loads kernel and initramfs over HTTP and names the disk
# on the kernel command line; open-iscsi's initramfs script logs in with
# iscsistart (iscsi_initiator=, iscsi_target_ip=, iscsi_target_name=).
#
# In the disk:
#   - open-iscsi in the initramfs (MODULES=most, iscsi_tcp); the initiator
#     name comes from the kernel command line (the base has GenerateName=yes,
#     which gives the initramfs none)
#   - the address: iPXE's lease, passed by the profile as a fixed ip= (the
#     same form as the NFS profiles); NOT IP=off here, which would override
#     ip=. systemd-networkd keeps it and renews it with the MAC address as
#     client identity; NetworkManager only for Wi-Fi; systemd-network-generator
#     off (it would give every port the ip= address)
#   - partition table identifier DISK_ID (fixed, not the image's), so the
#     profile can say root=PARTUUID=<DISK_ID>-02 and an SD card flashed from
#     the stock image never matches
#   - kernel packages held: the Pi loads the kernel served by Matchbox, not
#     the one on the disk; a kernel update inside the disk would leave the
#     served kernel without its modules. Update by rebuilding the base.
#   - no hostname: the boot profile gives one (systemd.hostname=)
#   - SSH with your key for root, host keys made at the first boot, empty
#     machine ID, first-boot dialog and resizing off, swap in zram only
set -eu

DATA=${1:?usage: get-raspios-iscsi-disk.sh <pxe data dir> <ssh public key file> [name]}
KEY=${2:?usage: get-raspios-iscsi-disk.sh <pxe data dir> <ssh public key file> [name]}
NAME=${3:-raspios}
SIZE=${DISK_SIZE:-8G}
DISK_ID=${DISK_ID:-0x15c51005}
URL=${RASPIOS_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}

[ -d "$DATA" ] || { echo "no directory $DATA" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no file $KEY" >&2; exit 1; }
printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' \
  || { echo "invalid name '$NAME'" >&2; exit 1; }
DATA=$(cd "$DATA" && pwd)
KEY=$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")
[ -e "$DATA/iscsi/base/$NAME.raw" ] && { echo "$DATA/iscsi/base/$NAME.raw exists" >&2; exit 1; }

emu=0
if [ "$(uname -m)" != aarch64 ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  docker run --rm --privileged tonistiigi/binfmt --install arm64 >/dev/null
  emu=1
fi
trap '[ "$emu" = 0 ] || docker run --rm --privileged tonistiigi/binfmt --uninstall qemu-aarch64 >/dev/null 2>&1 || true' EXIT

docker run --rm -i --privileged -v /dev:/dev -v "$DATA:/data" -v "$KEY:/key.pub:ro" \
  -e NAME="$NAME" -e SIZE="$SIZE" -e DISK_ID="$DISK_ID" -e URL="$URL" \
  -e OWNER="$(id -u):$(id -g)" -e ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}" \
  debian:trixie-slim sh -eu <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get -q update >/dev/null
apt-get -q -y --no-install-recommends install curl ca-certificates xz-utils qemu-utils fdisk e2fsprogs openssh-client >/dev/null
dir=/data/iscsi/base; out=$dir/$NAME.raw; tmp=$out.partial
assets=/data/matchbox/assets/raspios-iscsi/$NAME
mkdir -p "$dir" "$assets"
cd /tmp

real=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$URL")
curl -fSL --retry 3 -o img.xz "$real"
want=$(curl -fsSL "$real.sha256" | cut -d' ' -f1)
[ "$want" = "$(sha256sum img.xz | cut -d' ' -f1)" ] || { echo "SHA-256 mismatch" >&2; exit 1; }
xz -dc img.xz > "$tmp"; rm img.xz

loop=
cleanup() {
  umount /mnt/boot/firmware /mnt/run /mnt/dev /mnt/sys /mnt/proc /mnt 2>/dev/null || true
  [ -z "$loop" ] || losetup -d "$loop" || true
  rm -f "$tmp"
}
trap cleanup EXIT

# Grow to SIZE, root (partition 2, the last) to the end; new disk identifier
old=$(sfdisk --disk-id "$tmp" | sed 's/^0x//')
qemu-img resize -q -f raw "$tmp" "$SIZE"
echo ', +' | sfdisk -q --no-reread -N 2 "$tmp"
sfdisk -q --disk-id "$tmp" "$DISK_ID"
new=$(printf '%08x' "$DISK_ID")
loop=$(losetup -fP --show "$tmp")
i=0; while [ ! -b "${loop}p2" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
e2fsck -fy "${loop}p2" >/dev/null 2>&1 || [ $? -le 1 ]
resize2fs "${loop}p2" >/dev/null 2>&1

r=/mnt
mount "${loop}p2" $r
mount "${loop}p1" $r/boot/firmware
sed -i "s/PARTUUID=$old-/PARTUUID=$new-/" $r/etc/fstab $r/boot/firmware/cmdline.txt
echo "$real" > $r/boot/firmware/SOURCE

# SSH with the given key, no first-boot dialog, swap in zram, the network
mkdir -p $r/root/.ssh; chmod 700 $r/root/.ssh
cat /key.pub > $r/root/.ssh/authorized_keys; chmod 600 $r/root/.ssh/authorized_keys
ln -sf /usr/lib/systemd/system/ssh.service $r/etc/systemd/system/multi-user.target.wants/ssh.service
# Host keys: none in the base, so every copy makes its own at its first boot.
# Raspberry Pi OS does not make missing keys by itself (ssh.service failed
# with none, 2026-11-28); ssh-keygen -A makes only the missing ones.
rm -f $r/etc/ssh/ssh_host_*
mkdir -p $r/etc/systemd/system/ssh.service.d
# ExecStartPre= first: the unit's own "sshd -t" would run before ssh-keygen and
# fail without keys.
printf '[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\nExecStartPre=/usr/sbin/sshd -t\n' \
  > $r/etc/systemd/system/ssh.service.d/hostkeys.conf
[ -z "$ROOT_PASSWORD_HASH" ] || sed -i "s|^root:[^:]*:|root:$ROOT_PASSWORD_HASH:|" $r/etc/shadow
ln -sf /dev/null $r/etc/systemd/system/userconfig.service
ln -sf /dev/null $r/etc/systemd/system/systemd-growfs-root.service
mkdir -p $r/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/getty@.service $r/etc/systemd/system/getty.target.wants/getty@tty1.service
[ ! -d $r/etc/cloud ] || touch $r/etc/cloud/cloud-init.disabled
: > $r/etc/machine-id
rm -f $r/etc/hostname
mkdir -p $r/etc/rpi/swap.conf.d
printf '[Main]\nMechanism=zram\n' > $r/etc/rpi/swap.conf.d/50-iscsi-root.conf
sed -i 's/^MODULES=.*/MODULES=most/' $r/etc/initramfs-tools/initramfs.conf
grep -qx iscsi_tcp $r/etc/initramfs-tools/modules || echo iscsi_tcp >> $r/etc/initramfs-tools/modules

mkdir -p $r/etc/systemd/network $r/etc/NetworkManager/conf.d
cat > $r/etc/systemd/network/50-iscsi-root.network <<'NET'
# Written by get-raspios-iscsi-disk.sh. The root disk is reached over this
# network: the address the initramfs set from ip= (iPXE's lease) is kept and
# its lease renewed with the MAC address as client identity, as iPXE asked.
[Match]
Name=e*

[Network]
DHCP=ipv4
KeepConfiguration=yes

[DHCPv4]
ClientIdentifier=mac
NET
printf '[keyfile]\nunmanaged-devices=type:ethernet\n' > $r/etc/NetworkManager/conf.d/50-iscsi-root.conf
ln -sf /dev/null $r/etc/systemd/system/systemd-network-generator.service
mkdir -p $r/etc/systemd/system/systemd-networkd-wait-online.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any\n' \
  > $r/etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf

mount -t proc proc $r/proc; mount -t sysfs sys $r/sys; mount --bind /dev $r/dev; mount -t tmpfs tmpfs $r/run
rm -f $r/etc/resolv.conf; cat /etc/resolv.conf > $r/etc/resolv.conf
mkdir -p $r/run/systemd/resolve; cat /etc/resolv.conf > $r/run/systemd/resolve/stub-resolv.conf
printf '#!/bin/sh\nexit 101\n' > $r/usr/sbin/policy-rc.d; chmod 755 $r/usr/sbin/policy-rc.d
chroot $r /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive sh -eu <<'CHROOT'
apt-get -q update >/dev/null
apt-get -q -y --no-install-recommends install open-iscsi libnss-myhostname systemd-resolved >/dev/null
echo "GenerateName=yes" > /etc/iscsi/initiatorname.iscsi
# The hostname comes from the kernel command line (systemd.hostname=, set by
# the boot profile): the base has none, so every copy gets its own name.
systemctl enable systemd-networkd.service systemd-resolved.service >/dev/null 2>&1
# The kernel the Pi runs is the copy served over HTTP; an update inside the
# disk would leave it without matching modules. Update by rebuilding the base.
apt-mark hold linux-image-rpi-2712 linux-image-rpi-v8 >/dev/null
update-initramfs -u -k all 2>&1 | tail -2
apt-get clean
CHROOT
rm -f $r/usr/sbin/policy-rc.d $r/etc/resolv.conf
ln -s ../run/systemd/resolve/stub-resolv.conf $r/etc/resolv.conf

# The boot files iPXE loads (raspi-firmware's initramfs hook copied the new
# initramfs to /boot/firmware/initramfs_2712 above).
for f in kernel_2712.img initramfs_2712; do
  [ -s $r/boot/firmware/$f ] || { echo "no $f on the boot partition" >&2; exit 1; }
done
# The initramfs must hold iscsistart (lsinitramfs in the chroot; under
# emulation it prints "unmkinitramfs: cpio failed" for the second archive,
# after the listing this check needs).
chroot $r lsinitramfs /boot/firmware/initramfs_2712 | grep -q 'usr/sbin/iscsistart$' \
  || { echo "initramfs_2712 has no iscsistart" >&2; exit 1; }
cp $r/boot/firmware/kernel_2712.img $r/boot/firmware/initramfs_2712 "$assets/"

umount $r/run $r/dev $r/sys $r/proc
fstrim $r || true
umount $r/boot/firmware $r
losetup -d "$loop"; loop=
chown "$OWNER" "$(dirname "$assets")"; chown -R "$OWNER" "$assets"; chown "$OWNER" "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "[get-raspios-iscsi-disk] $out, boot files in $assets, root=PARTUUID=$new-02"
EOF
echo "next: docker exec <iscsi container> iscsi-disk copy $NAME $NAME-<mac with hyphens>"
