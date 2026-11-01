FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
# What Lima's (non-plain) boot scripts and a user session need: sshd, the guest agent's deps,
# sshfs/virtiofs mounts and the docker CLI (dockerd itself is the separate `docker` service).
RUN apk add --no-cache openssh-server openssh-sftp-server bash zsh sudo shadow shadow-uidmap util-linux blkid \
      docker-cli docker-cli-buildx docker-cli-compose iptables ip6tables \
      sshfs fuse3 rsync socat iproute2 curl ca-certificates tzdata xauth python3 \
      e2fsprogs e2fsprogs-extra xfsprogs xfsprogs-extra btrfs-progs \
      containerd runc nerdctl buildkit buildctl cni-plugins rootlesskit slirp4netns \
 && rm -f /etc/alpine-release /etc/motd \
 && mkdir -p /etc/conf.d /etc/init.d
# python3: provision mode ansible; e2fsprogs/xfsprogs/btrfs-progs: additionalDisks format/fsType;
# socat: ssh over vsock; shadow-uidmap: rootless engines
# containerd..slirp4netns: containerd.system/user (entrypoint.sh starts them; Lima's own install needs systemd)
# containerd-rootless.sh: rootless containerd under RootlessKit; Alpine's nerdctl doesn't ship it. Matches nerdctl's version.
ADD --chmod=755 --checksum=sha256:1f8101ce7680ce4533ced18b4e3e39bd300c08210c336d30f6969c8cb1727a7c \
    https://raw.githubusercontent.com/containerd/nerdctl/v2.2.1/extras/rootless/containerd-rootless.sh /usr/bin/containerd-rootless.sh
# ^ no /etc/alpine-release: Lima's alpine-specific boot scripts assume a running OpenRC
# /etc/conf.d + /etc/init.d: 25-guestagent-base.sh writes the agent's (shimmed) OpenRC files there.
# Lima's guest agent installer only knows OpenRC or systemd; these shims make it take the OpenRC path.
COPY shims/openrc-run shims/rc-update shims/rc-service /sbin/
COPY shims/systemctl /usr/libexec/limakit/systemctl
COPY shims/rootless-containerd /usr/libexec/limakit/rootless/containerd
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
