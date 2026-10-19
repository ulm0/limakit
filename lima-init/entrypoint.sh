#!/bin/bash
# Stand-in for cloud-init/lima-init on LinuxKit: read the cidata ISO, create the user, apply the user-data
# fields cloud-init would (keys, mounts, timezone, CA certs, DNS, bootcmd), start sshd, run Lima's boot.sh.
# dockerd is the separate docker service; directories both need are shared via binds in limakit.yml.
set -eux
# Lima's hostagent tails this for `limactl start` progress and points users at it on failure
exec > >(tee -a /var/log/cloud-init-output.log) 2>&1

export LIMA_CIDATA_MNT=/mnt/lima-cidata

# The container has a private /dev (the host's is 0660 root, which locks out the ssh user); copy in only
# what is needed (device rules in limakit.yml): disks, fuse (sshfs), vsock (guest agent, ssh over vsock),
# kvm (nestedVirtualization), net/tun (rootless engines).
for d in /hostdev/vd* /hostdev/fuse /hostdev/vsock /hostdev/kvm /hostdev/btrfs-control; do
	[ -e "$d" ] && [ ! -e "/dev/${d##*/}" ] && cp -a "$d" /dev/ || true
done
[ -e /hostdev/net/tun ] && mkdir -p /dev/net && cp -a /hostdev/net/tun /dev/net/
chmod 666 /dev/fuse
# no udev: pre-create partition nodes (virtio-blk: 16 minors per disk) so partitions Lima's
# 05-lima-disks.sh creates later are usable here, and give it /dev/disk/by-label to detect formatted disks
for d in /dev/vd?; do
	maj=$((0x$(stat -c %t "$d"))) min=$((0x$(stat -c %T "$d")))
	for p in 1 2 3 4; do [ -e "$d$p" ] || mknod "$d$p" b "$maj" $((min + p)); done
done
mkdir -p /dev/disk/by-label
for d in /dev/vd*; do
	l=$(blkid -o value -s LABEL "$d" || true)
	[ -n "$l" ] && ln -sf "../../${d##*/}" "/dev/disk/by-label/$l" || true
done

install -d -m 700 "$LIMA_CIDATA_MNT"
mountpoint -q "$LIMA_CIDATA_MNT" || mount -o ro,mode=0700,dmode=0700,overriderockperm,exec,uid=0 /dev/disk/by-label/cidata "$LIMA_CIDATA_MNT"
UD=$LIMA_CIDATA_MNT/user-data

# shellcheck disable=SC2163 # lines are KEY=value
while read -r line; do [ -n "$line" ] && export "$line"; done <"$LIMA_CIDATA_MNT/lima.env"
yq() { "$LIMA_CIDATA_MNT/lima-guestagent" yq "$@"; } # cidata ships yq inside the guest agent

# Lima formats additionalDisks with label lima-<name> and checks /dev/disk/by-label/lima-<name> next boot;
# ext4 (16 bytes) and xfs (12) truncate long labels, so Lima would re-format such a disk on every boot.
# Link the full name to the truncated label.
for i in $(seq 0 $((${LIMA_CIDATA_DISKS:-0} - 1))); do
	full=lima-$(eval echo "\$LIMA_CIDATA_DISK_${i}_NAME")
	for short in "${full:0:16}" "${full:0:12}"; do
		if [ ! -e "/dev/disk/by-label/$full" ] && [ -e "/dev/disk/by-label/$short" ]; then
			ln -s "$(readlink "/dev/disk/by-label/$short")" "/dev/disk/by-label/$full"
		fi
	done
done

hostname "$(awk '/^local-hostname:/ {print $2}' "$LIMA_CIDATA_MNT/meta-data")"
tz=$(yq -r '.timezone // ""' "$UD")
if [ -n "$tz" ] && [ -e "/usr/share/zoneinfo/$tz" ]; then
	ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
	echo "$tz" >/etc/timezone
fi

# user
home=${LIMA_CIDATA_HOME:-/home/$LIMA_CIDATA_USER.linux}
shell=${LIMA_CIDATA_SHELL:-/bin/bash}
[ -x "$shell" ] || shell=/bin/bash
id "$LIMA_CIDATA_USER" >/dev/null 2>&1 ||
	useradd -m -d "$home" -u "$LIMA_CIDATA_UID" -c "${LIMA_CIDATA_COMMENT:-}" -s "$shell" "$LIMA_CIDATA_USER"
if [ "${LIMA_CIDATA_PASSWORDLESS_SUDO:-1}" = 1 ]; then
	usermod -p '*' "$LIMA_CIDATA_USER" # unlock for pubkey auth
	echo "$LIMA_CIDATA_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-lima-users
else
	echo "$LIMA_CIDATA_USER ALL=(ALL) ALL" >/etc/sudoers.d/90-lima-users
	# boot.sh sets a random password once and leaves it in ~/password; re-apply it on every boot
	if [ -f "$home/password" ]; then echo "$LIMA_CIDATA_USER:$(cat "$home/password")" | chpasswd; else usermod -p '*' "$LIMA_CIDATA_USER"; fi
fi
# docker.sock is root:999 (dockerd --group=999 in limakit.yml)
getent group 999 >/dev/null || groupadd -g 999 docker
groupadd -f kvm
usermod -aG "$(getent group 999 | cut -d: -f1),kvm" "$LIMA_CIDATA_USER"
[ -e /dev/kvm ] && chgrp kvm /dev/kvm && chmod 660 /dev/kvm
gid=$(id -g "$LIMA_CIDATA_USER")

install -d -m 700 "$home/.ssh"
yq -r '.users[0]."ssh-authorized-keys"[]' "$UD" >"$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"
# ssh sessions: Lima's env/propagateProxyEnv (etc_environment) and XDG_RUNTIME_DIR (no pam_systemd here)
install -d -m 700 -o "$LIMA_CIDATA_UID" -g "$gid" "/run/user/$LIMA_CIDATA_UID"
{
	sed -e '/^#/d' -e '/^$/d' "$LIMA_CIDATA_MNT/etc_environment"
	echo "XDG_RUNTIME_DIR=/run/user/$LIMA_CIDATA_UID"
} >"$home/.ssh/environment"
chown -R "$LIMA_CIDATA_UID:$gid" "$home/.ssh"

# CA certs (caCerts in lima.yaml); the bundle is shared with dockerd (/run/lima-ca, see limakit.yml)
if [ "$(yq -r '.ca_certs.remove_defaults // false' "$UD")" = true ]; then
	: >/etc/ca-certificates.conf
	rm -rf /usr/share/ca-certificates/*
fi
mkdir -p /usr/local/share/ca-certificates # /usr/local is on the data disk: drop certs from earlier boots
rm -f /usr/local/share/ca-certificates/lima-*.crt
n=$(yq '.ca_certs.trusted | length' "$UD")
for i in $(seq 0 $((n - 1))); do yq -r ".ca_certs.trusted[$i]" "$UD" >"/usr/local/share/ca-certificates/lima-$i.crt"; done
update-ca-certificates
cp /etc/ssl/certs/ca-certificates.crt /run/lima-ca/ca-certificates.crt

# DNS (Lima's resolv_conf / dns:). /etc/resolv.conf is bound from the LinuxKit host, so dockerd sees it too;
# rewrite in place (the bind pins the inode). The dhcpcd service doesn't touch it (nohook resolv.conf).
ns=$(yq -r '.resolv_conf.nameservers[]?' "$UD")
if [ -n "$ns" ]; then
	printf 'nameserver %s\n' $ns >/etc/resolv.conf
fi

# cloud-init would write these from user-data "mounts:"; boot.Linux/05-lima-mounts.sh then mounts the virtiofs ones.
yq -r '.mounts[]? | @tsv' "$UD" >>/etc/fstab
awk '$1 !~ /^#/ && NF >= 3 {print $2}' /etc/fstab | while read -r m; do mkdir -p "$m"; done
# dockerd only sees mounts under the shared roots (see the docker service in limakit.yml)
for i in $(seq 0 $((${LIMA_CIDATA_MOUNTS:-0} - 1))); do
	m=$(eval echo "\$LIMA_CIDATA_MOUNTS_${i}_MOUNTPOINT")
	case "$m" in /Users/* | /Volumes/* | /mnt/* | /home/* | /tmp/*) ;; *) echo "WARNING: mount $m is outside /Users, /Volumes, /mnt, /home, /tmp; docker will not see it" ;; esac
done
# Rosetta binfmt registration (vz rosetta.binfmt) and the guest agent's eBPF port ticker
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || echo "WARNING: no binfmt_misc"
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing || echo "WARNING: no tracefs"
# Lima's 05-rosetta-volume.sh registers Rosetta with bash's echo, which bash 5.3 issues as two writes: the
# entry, then a lone newline the kernel rejects (EINVAL), aborting the script before rosettad and the CDI spec.
# Register it here with one write (busybox echo); the script then finds the entry and carries on.
if [ "${LIMA_CIDATA_ROSETTA_ENABLED:-}" = true ] && [ "${LIMA_CIDATA_ROSETTA_BINFMT:-}" = true ] &&
	[ ! -e /proc/sys/fs/binfmt_misc/rosetta ]; then
	mountpoint -q /mnt/lima-rosetta || mount /mnt/lima-rosetta # the F flag opens the interpreter now
	r=$(sed -n 's/^[[:space:]]*rosetta_binfmt="\(.*\)"$/\1/p' "$LIMA_CIDATA_MNT/boot.Linux/05-rosetta-volume.sh")
	[ -n "$r" ] && busybox echo "$r" >/proc/sys/fs/binfmt_misc/register
fi

# sshd; host keys persist on the data disk (/var/lib/lima-ssh) so they don't change every boot
for t in rsa ecdsa ed25519; do
	[ -f "/etc/ssh/keys/ssh_host_${t}_key" ] || ssh-keygen -q -N '' -t "$t" -f "/etc/ssh/keys/ssh_host_${t}_key"
done
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/lima.conf <<'CONF'
HostKey /etc/ssh/keys/ssh_host_ed25519_key
HostKey /etc/ssh/keys/ssh_host_ecdsa_key
HostKey /etc/ssh/keys/ssh_host_rsa_key
AllowTcpForwarding yes
PasswordAuthentication no
PermitUserEnvironment yes
X11Forwarding yes
CONF
grep -q '^Include' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
/usr/sbin/sshd # daemonizes
# ssh.overVsock: the hostagent probes vsock port 22 once it sees the VM running
[ -e /dev/vsock ] && socat VSOCK-LISTEN:22,reuseaddr,fork TCP:127.0.0.1:22 &

ln -sf /run/dockersock/docker.sock /var/run/docker.sock # docker CLI default path; dockerd is the docker service

# cloud-init bootcmd (Lima's own snippets and `provision: mode: boot` scripts), then Lima's boot scripts
for i in $(seq 0 $(($(yq '.bootcmd | length' "$UD") - 1))); do
	yq -r ".bootcmd[$i]" "$UD" | sh || echo "WARNING: bootcmd[$i] failed"
done
"$LIMA_CIDATA_MNT/boot.sh" || true
echo "Cloud-init v. limakit finished at $(date)"

# PID 1 must handle TERM (bare `sleep` ignores it); unmount Lima's fuse/virtiofs mounts on the way down
trap 'umount -a -t fuse.sshfs,virtiofs || true; exit 0' TERM
sleep infinity &
wait
