FROM alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
# What Lima's (non-plain) boot scripts and a user session need: sshd, the guest agent's deps,
# sshfs/virtiofs mounts and the docker CLI (dockerd itself is the separate `docker` service).
RUN apk add --no-cache openssh-server openssh-sftp-server bash zsh sudo shadow shadow-uidmap util-linux blkid agetty \
      docker-cli docker-cli-buildx docker-cli-compose iptables ip6tables \
      sshfs fuse3 rsync socat iproute2 curl ca-certificates tzdata xauth python3 \
      e2fsprogs e2fsprogs-extra xfsprogs xfsprogs-extra btrfs-progs \
 && rm -f /etc/alpine-release /etc/motd \
 && mkdir -p /etc/conf.d /etc/init.d
# python3: provision mode ansible; e2fsprogs/xfsprogs/btrfs-progs: additionalDisks format/fsType;
# socat: ssh over vsock; agetty: login prompt on the VZ display; shadow-uidmap: rootless engines
# ^ no /etc/alpine-release: Lima's alpine-specific boot scripts assume a running OpenRC
# /etc/conf.d + /etc/init.d: 25-guestagent-base.sh writes the agent's (shimmed) OpenRC files there.
# Lima's guest agent installer only knows OpenRC or systemd; these shims make it take the OpenRC path.
COPY shims/openrc-run shims/rc-update shims/rc-service /sbin/
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
