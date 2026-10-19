#!/bin/bash
# Feature checks for the limakit image against a throwaway Lima instance (limakit-test) and its own disks.
#   test/run.sh            # needs out/limakit-kernel + out/limakit-squashfs.img (make)
#   KEEP=1 test/run.sh     # leave limakit-test (and its disks) up afterwards
# Two boots: virtiofs + vzNAT + most features, then reverse-sshfs + user-v2. Checks the host can't run
# (no Rosetta, no nested virtualization, no ansible-playbook) are skipped, not failed.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
I=limakit-test
T=$(mktemp -d)
SHARE=/tmp/limakit-test-share # writable mount; under /tmp so the mountPoint can match
FAILS=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
check() { # check "name" cmd...  (passes when cmd exits 0)
	local n=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi
}
g() { limactl shell --workdir / "$I" bash -c "$1" 2>/dev/null; } # run in the guest
cleanup() {
	limactl delete -f "$I" >/dev/null 2>&1
	limactl disk delete $I-extra >/dev/null 2>&1
	rm -rf "$T" "$SHARE"
}
[ "${KEEP:-}" ] || trap cleanup EXIT # KEEP=1: leave the instance up for debugging

# config: lima.yaml with absolute image paths, test disks, plus per-run overrides
config() {
	sed -e "s|https://github.com/[^ ]*/download/|$ROOT/out/|" -e "s|^mountType:.*|mountType: $1|" lima.yaml
	cat <<-EOF
		additionalDisks:
		  - name: $I-extra
		    format: true
		    fsType: btrfs
		mounts:
		  - location: "~"
		  - location: $SHARE
		    mountPoint: /tmp/lima
		    writable: true
		ssh:
		  forwardAgent: true
		param:
		  GREETING: hello-param
		provision:
		  - mode: system
		    script: |
		      #!/bin/sh
		      echo "system \$PARAM_GREETING" > /tmp/lima/prov-system
		  - mode: user
		    script: |
		      #!/bin/sh
		      echo "user \$XDG_RUNTIME_DIR" > /tmp/lima/prov-user
		  - mode: boot
		    script: |
		      #!/bin/sh
		      echo boot > /run/prov-boot
		  - mode: dependency
		    script: |
		      #!/bin/sh
		      echo dependency > /run/prov-dependency
		  - mode: data
		    path: /etc/prov-data
		    content: data-ok
		${ANSIBLE_PROV:-}
		probes:
		  - mode: readiness
		    script: |
		      #!/bin/sh
		      test -S /var/run/docker.sock
	EOF
	shift
	printf '%s\n' "$@"
}
start() { # start <config file>; the extra disk is created on first use
	limactl disk list 2>/dev/null | grep -q "^$I-extra " || limactl disk create $I-extra --size 2GiB >/dev/null
	limactl delete -f "$I" >/dev/null 2>&1
	limactl create --name "$I" --tty=false "$1" >"$T/start.log" 2>&1 && limactl start "$I" --tty=false >>"$T/start.log" 2>&1
}
port_fwd() { # port_fwd <port> <proto>: wait for the forward, return what the guest service answers
	for _ in $(seq 20); do
		if [ "$2" = tcp ]; then curl -fs --max-time 2 "http://127.0.0.1:$1" >/dev/null && return 0
		else [ "$(echo ping | nc -u -w 2 127.0.0.1 "$1")" = pong ] && return 0; fi
		sleep 2
	done
	return 1
}

mkdir -p "$SHARE"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj "/CN=limakit-test-ca" -days 1 -out "$T/ca.pem" 2>/dev/null
extra=(
	"networks: [{vzNAT: true}]"
	"dns: [1.1.1.1]"
	"hostResolver: {enabled: false}"
	"caCerts:" "  certs:" "    - |" "$(sed 's/^/      /' "$T/ca.pem")"
)
sysctl -n kern.hv_support >/dev/null 2>&1 && [ "$(sysctl -n machdep.cpu.brand_string | grep -oE 'M[0-9]+' | tr -d M)" -ge 3 ] 2>/dev/null &&
	extra+=("nestedVirtualization: true") && NESTED=1
[ -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ] &&
	extra+=("vmOpts: {vz: {rosetta: {enabled: true, binfmt: true}}}") && ROSETTA=1
command -v ansible-playbook >/dev/null && {
	printf -- '- hosts: all\n  tasks:\n    - ansible.builtin.copy: {dest: /tmp/lima/ansible, content: "ok\\n"}\n' >"$T/playbook.yml"
	ANSIBLE_PROV="  - {mode: ansible, playbook: $T/playbook.yml}" ANSIBLE=1
}
config virtiofs "${extra[@]}" >"$T/a.yaml"

echo "== boot 1: virtiofs, vzNAT, provisioning, disks, host integration"
if ! start "$T/a.yaml"; then fail "boot (see below)"; tail -n 20 "$T/start.log"; exit 1; fi
pass "boot (non-plain READY)"
check "guest agent running" g 'pgrep lima-guestagent'
check "data on the instance disk (loop0 after the squashfs)" g 'mount | grep -q "^/dev/loop0 on /home "'
check "sysctls applied (LinuxKit's + limakit's)" g '[ "$(cat /proc/sys/kernel/kptr_restrict /proc/sys/net/ipv4/conf/all/rp_filter | tr "\\n" " ")" = "2 2 " ]'
check "guest agent eBPF port ticker" g 'sudo grep -q "eBPF ticker" /var/log/lima-guestagent.log'
check "ssh over vsock" grep -q "listening on the vsock port" ~/.lima/$I/ha.stderr.log
check "virtiofs ~ (ro)" g "mount | grep -q 'on $HOME type virtiofs (ro'"
check "docker -v on ~" g "docker run --rm -v $HOME:/x alpine ls /x/Documents"
g 'docker run --rm -v /tmp/lima:/t alpine sh -c "echo w > /t/from-container"'
check "writable mount: container write reaches host" grep -qx w "$SHARE/from-container"
g 'docker run -d --name tcp -p 18080:80 nginx:alpine; docker run -d --name udp -p 15300:5300/udp alpine sh -c "apk add -q socat && socat UDP-RECVFROM:5300,fork EXEC:\"echo pong\""' >/dev/null
check "TCP port forward" port_fwd 18080 tcp
check "UDP port forward" port_fwd 15300 udp
check "dhcpcd port 68 not forwarded" sh -c "! grep -q 'Forwarding UDP from 0.0.0.0:68' ~/.lima/$I/ha.stderr.log"
check "docker socket on host" env DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock docker ps
echo x >"$T/cp" && check "limactl cp" sh -c "limactl cp '$T/cp' $I:/tmp/cp 2>/dev/null && [ \"\$(limactl shell $I cat /tmp/cp 2>/dev/null)\" = x ]"
check "provision system + param" grep -qx "system hello-param" "$SHARE/prov-system"
check "provision user (XDG_RUNTIME_DIR)" grep -q "^user /run/user/" "$SHARE/prov-user"
check "provision boot/dependency/data" g '[ "$(cat /run/prov-boot /run/prov-dependency /etc/prov-data)" = "$(printf "boot\ndependency\ndata-ok")" ]'
[ "${ANSIBLE:-}" ] && check "provision ansible" grep -qx ok "$SHARE/ansible" || skip "provision ansible (no ansible-playbook)"
check "timezone = host" g "[ \"\$(cat /etc/timezone)\" = \"$(readlink /etc/localtime | sed 's|.*zoneinfo/||')\" ]"
check "dns:" g 'grep -qx "nameserver 1.1.1.1" /etc/resolv.conf'
check "caCerts (guest bundle)" g "grep -q '$(sed -n 2p "$T/ca.pem")' /etc/ssl/certs/ca-certificates.crt"
check "dockerd pulls (CA bundle)" g 'timeout 300 docker pull -q busybox' # a stalled registry download would hang the run
check "dockerd set up ip6tables" g '! sudo grep -q "cannot set up ip6tables" /var/log/docker.log'
check "docker memory/cpu limits" g '[ "$(docker run --rm -m 64m --cpus 0.5 alpine cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max | tr "\n" " ")" = "67108864 50000 100000 " ]'
check "k3s node Ready in docker (k3d)" g 'docker run -d --privileged --name k3s rancher/k3s:v1.37.1-k3s1 server --disable=traefik >/dev/null && for _ in $(seq 60); do docker exec k3s kubectl get nodes 2>/dev/null | grep -q " Ready " && r=0 && break; r=1; sleep 3; done; docker rm -f k3s >/dev/null; exit $r'
check "docker IPv6 network" g 'docker network create --ipv6 v6test && docker run --rm --network v6test alpine ip -6 addr show eth0 | grep -q "inet6 fd"; r=$?; docker network rm v6test; exit $r'

# Kubernetes in docker with k3d, from the host: plain flannel, then Cilium (helm). Needs k3d + kubectl (+ helm).
K3S=rancher/k3s:v1.37.1-k3s1 CILIUM=1.20.3
k3d_up() { # k3d_up <cluster> [k3d args]
	local c=$1; shift
	DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock k3d cluster create "$c" --image "$K3S" --timeout 300s \
		--kubeconfig-update-default=false --kubeconfig-switch-context=false "$@" >>"$T/k3d.log" 2>&1 &&
		DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock k3d kubeconfig get "$c" >"$T/$c.kubeconfig"
}
k3d_down() { DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock k3d cluster delete "$1" >>"$T/k3d.log" 2>&1; }
k8s_smoke() { # k8s_smoke <cluster>: nodes Ready, a pod reachable through a Service by name (CNI + DNS + kube-proxy)
	local k=(kubectl --kubeconfig "$T/$1.kubeconfig")
	"${k[@]}" wait node --all --for=condition=Ready --timeout=300s &&
		"${k[@]}" run web --image=nginx:alpine --port 80 --expose &&
		"${k[@]}" wait pod/web --for=condition=Ready --timeout=300s &&
		"${k[@]}" run probe --image=curlimages/curl --rm -i --restart=Never --pod-running-timeout=300s -- curl -fsS -o /dev/null http://web
}
cilium_up() { # cilium_up <cluster>: bpffs + cgroup2 (shared) in each node, then the chart
	local n
	for n in $(DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock docker ps --filter "name=k3d-$1-(server|agent)" --format '{{.Names}}'); do
		DOCKER_HOST=unix://$HOME/.lima/$I/sock/docker.sock docker exec "$n" sh -c 'mount bpffs /sys/fs/bpf -t bpf && mount --make-shared /sys/fs/bpf && mkdir -p /run/cilium/cgroupv2 && mount -t cgroup2 none /run/cilium/cgroupv2 && mount --make-shared /run/cilium/cgroupv2' || return 1
	done
	helm install cilium cilium --repo https://helm.cilium.io --version "$CILIUM" --namespace kube-system \
		--kubeconfig "$T/$1.kubeconfig" --set operator.replicas=1 --set ipam.mode=kubernetes \
		--set cgroup.autoMount.enabled=false --set cgroup.hostRoot=/run/cilium/cgroupv2 --wait --timeout 10m >>"$T/k3d.log" 2>&1
}
if command -v k3d >/dev/null && command -v kubectl >/dev/null; then
	if k3d_up lk-flannel; then check "k3d + flannel: pod reachable through a Service" k8s_smoke lk-flannel; else fail "k3d + flannel: cluster create"; tail -n 15 "$T/k3d.log"; fi
	k3d_down lk-flannel
	if ! command -v helm >/dev/null; then skip "k3d + Cilium (no helm)"
	elif k3d_up lk-cilium --k3s-arg "--flannel-backend=none@server:*" --k3s-arg "--disable-network-policy@server:*" && cilium_up lk-cilium; then
		check "k3d + Cilium: pod reachable through a Service" k8s_smoke lk-cilium
	else fail "k3d + Cilium: cluster/Cilium install"; tail -n 15 "$T/k3d.log"; fi
	k3d_down lk-cilium
else skip "k3d (no k3d/kubectl on host)"; fi
check "vzNAT: lima0 default route metric 100" g 'ip route | grep -q "default via .* dev lima0 .* metric 100"'
check "ssh agent forwarding" g '[ -S "$SSH_AUTH_SOCK" ]'
check "X11 forwarding (guest side)" sh -c "DISPLAY=:0 ssh -F ~/.lima/$I/ssh.config -o ControlMaster=no -o ControlPath=none -Y lima-$I 'echo \$DISPLAY' 2>/dev/null | grep -q localhost:"
check "btrfs additionalDisk" g 'mount | grep -q "/mnt/lima-'$I'-extra type btrfs"'
check "extra disk visible to docker (/mnt)" g "echo keep | sudo tee /mnt/lima-$I-extra/keep >/dev/null && docker run --rm -v /mnt/lima-$I-extra:/d alpine cat /d/keep"
if [ "${NESTED:-}" ]; then check "nested virtualization (/dev/kvm in a container)" g 'docker run --rm --device /dev/kvm alpine test -c /dev/kvm'; else skip "nested virtualization (needs M3+)"; fi
if [ "${ROSETTA:-}" ]; then
	check "Rosetta: amd64 container" g '[ "$(docker run --rm --platform linux/amd64 alpine uname -m)" = x86_64 ]'
	check "Rosetta: rosettad cache via CDI" g 'docker run --rm --platform linux/amd64 --device lima-vm.io/rosetta=cached alpine test -S /run/rosettad/rosetta.sock'
else skip "Rosetta (not installed on host)"; fi
g 'echo h > ~/persist; sudo sh -c "echo r > /root/persist; echo u > /usr/local/persist"'
key=$(g 'ssh-keygen -lf /etc/ssh/keys/ssh_host_ed25519_key.pub')
s=$(date +%s); limactl stop "$I" >/dev/null 2>&1; took=$(($(date +%s) - s))
if [ "$took" -lt 20 ]; then pass "limactl stop clean (${took}s)"; else fail "limactl stop clean (${took}s, timed out)"; fi
limactl start "$I" --tty=false >/dev/null 2>&1
check "persists across reboot: /home /root /usr/local" g '[ "$(cat ~/persist; sudo cat /root/persist /usr/local/persist)" = "$(printf "h\nr\nu")" ]'
check "persists across reboot: ssh host key" g "[ \"\$(ssh-keygen -lf /etc/ssh/keys/ssh_host_ed25519_key.pub)\" = \"$key\" ]"
check "persists across reboot: extra disk not re-formatted" g "sudo cat /mnt/lima-$I-extra/keep"

echo "== boot 2: reverse-sshfs, user-v2"
config reverse-sshfs "networks: [{lima: user-v2}]" >"$T/b.yaml"
if start "$T/b.yaml"; then
	pass "boot (non-plain READY)"
	check "reverse-sshfs mounts" g 'mount | grep -q "on /tmp/lima type fuse.sshfs"'
	g 'docker run --rm -v /tmp/lima:/t alpine sh -c "echo s > /t/from-sshfs"'
	check "reverse-sshfs: container write reaches host" grep -qx s "$SHARE/from-sshfs"
	check "user-v2 network names" g 'getent hosts lima-'$I'.internal'
	check "host.lima.internal from a container" g 'docker run --rm alpine getent hosts host.lima.internal'
else fail "boot (see below)"; tail -n 20 "$T/start.log"; fi

echo
[ "$FAILS" = 0 ] && echo "all checks passed" || echo "$FAILS check(s) failed"
exit "$FAILS"
