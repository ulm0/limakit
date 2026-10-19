#!/bin/sh
# Build linuxkit/kernel:<version>-limakit (arm64) from LinuxKit's kernel packaging + kernel/limakit.config
# (a complete option list over allnoconfig; LinuxKit's own config is not used).
#
#   kernel/build.sh [KERNEL_VERSION]        e.g. kernel/build.sh 6.18.57
#
# A version whose series LinuxKit doesn't package yet (e.g. 7.2.11) borrows the newest series' packaging
# (Dockerfile, build-args); olddefconfig gives new options their defaults. Review kernel/config-aarch64 after that.
# Needs docker. DOCKER_HOST should point at a daemon with >=6 CPUs/8GiB; the build takes ~25 min.
set -eu

KERNEL_VERSION=${1:-6.18.57}
LINUXKIT_REF=${LINUXKIT_REF:-f3906d1f6650f79d74adf3cba42b04ca9e21ea7d} # linuxkit/linuxkit master, 2026-10-15
LINUXKIT=$(cd "$(dirname "${LINUXKIT:-bin/linuxkit}")" && pwd)/$(basename "${LINUXKIT:-bin/linuxkit}")
SERIES=$(echo "$KERNEL_VERSION" | cut -d. -f1-2).x
DIR=$(cd "$(dirname "$0")" && pwd)
SRC=$DIR/.build/linuxkit

# 1. LinuxKit's kernel packaging at a pinned commit
if [ ! -d "$SRC/.git" ]; then
	git clone -q https://github.com/linuxkit/linuxkit.git "$SRC"
fi
git -C "$SRC" fetch -q --depth 1 origin "$LINUXKIT_REF"
git -C "$SRC" checkout -q --force "$LINUXKIT_REF"
K=$SRC/kernel

# 2. series dir; for a series LinuxKit doesn't have, copy the newest one
if [ ! -d "$K/$SERIES" ]; then
	BASE=$(cd "$K" && printf '%s\n' [0-9]*.x | grep -v -- -rt | sort -V | tail -n 1)
	echo "LinuxKit has no $SERIES; starting from $BASE"
	cp -R "$K/$BASE" "$K/$SERIES"
	rm -rf "$K/$SERIES/patches" # patches are series-specific
fi
sed -i.bak -e "s/^KERNEL_VERSION=.*/KERNEL_VERSION=$KERNEL_VERSION/" -e "s/^KERNEL_SERIES=.*/KERNEL_SERIES=$SERIES/" "$K/$SERIES/build-args"
rm -f "$K/$SERIES/build-args.bak"

# 3. allnoconfig + limakit.config, normalized with olddefconfig (LinuxKit's build rejects a config that isn't),
#    in LinuxKit's own builder image: the config records the compiler and pahole versions
BUILD_IMAGE=$(sed -n 's/^BUILD_IMAGE=//p' "$K/$SERIES/build-args")
# BTF (Cilium's CONFIG_DEBUG_INFO_BTF) needs pahole, and python3 for resolve_btfids' libbpf headers; neither is
# in the builder's package mirror: take them from Alpine
PAHOLE='v=v$(cut -d. -f1,2 /etc/alpine-release) && apk add -q --repository https://dl-cdn.alpinelinux.org/alpine/$v/main --repository https://dl-cdn.alpinelinux.org/alpine/$v/community pahole python3'
grep -q pahole "$K/common/Dockerfile" ||
	awk -v run="RUN $PAHOLE" '{print} /^    zlib-dev$/ && !done {print run; done=1}' "$K/common/Dockerfile" >"$K/common/Dockerfile.new" &&
	mv "$K/common/Dockerfile.new" "$K/common/Dockerfile"
docker run --rm --platform linux/arm64 -v "$DIR:/k" "$BUILD_IMAGE" sh -euc "
	apk add -q bash build-base bc bison flex perl linux-headers openssl-dev elfutils-dev curl xz >/dev/null
	$PAHOLE >/dev/null
	cd /tmp && curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-$KERNEL_VERSION.tar.xz | tar xJ
	cd linux-$KERNEL_VERSION && make ARCH=arm64 allnoconfig >/dev/null
	grep '^CONFIG_' /k/limakit.config | while IFS== read -r o v; do scripts/config --set-val \"\${o#CONFIG_}\" \"\$v\"; done
	make ARCH=arm64 olddefconfig >/dev/null
	# a select/depends chain that isn't met silently drops an option: fail instead
	# (=n also holds when the symbol is absent: its menu is off)
	grep '^CONFIG_' /k/limakit.config | while read -r l; do
		case \"\$l\" in
		*=n) ! grep -q \"^\${l%=n}=\" .config ;;
		*) grep -qx \"\$l\" .config ;;
		esac || { echo \"not applied: \$l\"; exit 1; }
	done
	cp .config /k/config-aarch64"
cp "$DIR/config-aarch64" "$K/$SERIES/config-aarch64"

# 4. build with LinuxKit's own kernel packaging (same as kernel/Makefile buildplainkernel-%)
(cd "$K" && "$LINUXKIT" pkg build . --docker --force --force-dirty --platforms linux/arm64 \
	--build-yml ./common/build-kernel.yml --hash limakit --tag "$KERNEL_VERSION-{{.Hash}}" \
	--build-arg-file "$SERIES/build-args" --progress plain)
echo "built linuxkit/kernel:$KERNEL_VERSION-limakit"
