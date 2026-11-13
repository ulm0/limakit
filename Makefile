export DOCKER_HOST ?= $(shell docker context inspect --format "{{.Endpoints.docker.Host}}")
LK := bin/linuxkit
LINUXKIT_VERSION := v1.8.2
# images limakit.yml uses; local builds tag these names, otherwise linuxkit pulls them from GHCR (CI pushes them)
REGISTRY := ghcr.io/ulm0/limakit
# the kernel limakit.yml pins (github.com/ulm0/lk-kernel)
KERNEL_IMAGE := $(shell sed -n 's|^  image: \(ghcr.io/ulm0/lk-kernel:.*\)$$|\1|p' limakit.yml)
LIMA_IMAGE := $(REGISTRY)/lima:latest
all: out/limakit-squashfs.img

$(LK):
	mkdir -p bin
	curl -fsSL -o $@ https://github.com/linuxkit/linuxkit/releases/download/$(LINUXKIT_VERSION)/linuxkit-$$(uname -s | tr A-Z a-z)-$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
	chmod +x $@

lima-image: $(wildcard lima-init/* lima-init/shims/*)
	docker build -t $(LIMA_IMAGE) lima-init
	touch $@

# kernel+squashfs: Lima boots out/limakit-kernel directly with the squashfs as root disk (lima.yaml),
# so the root filesystem stays on disk instead of unpacking into RAM. linuxkit takes images from the
# docker cache first (local builds win), then pulls from GHCR.
# linuxkit v1.8.2 resolves ghcr.io names against Docker Hub when pulling, so docker pulls the kernel first
out/limakit-squashfs.img: limakit.yml lima-image | $(LK)
	docker image inspect $(KERNEL_IMAGE) >/dev/null 2>&1 || docker pull -q $(KERNEL_IMAGE)
	mkdir -p out && $(LK) build --docker --decompress-kernel --format kernel+squashfs --arch arm64 --dir out --name limakit limakit.yml

# Local testing with Lima. `run` recreates the instance from out/limakit-squashfs.img
# every time (the image is copied at create), so docker data and /home start empty.
INSTANCE := limakit
.PHONY: run shell stop clean
run: out/limakit-squashfs.img
	-limactl delete -f $(INSTANCE)
	limactl create --name $(INSTANCE) --tty=false lima.yaml \
		--set '.images[0].location = "$(CURDIR)/out/limakit-squashfs.img" | .images[0].kernel.location = "$(CURDIR)/out/limakit-kernel"'
	limactl start $(INSTANCE) --tty=false
	@echo "try: make shell   (or: docker -H ssh://lima-$(INSTANCE) ps, with ~/.lima/$(INSTANCE)/ssh.config in ~/.ssh/config)"

shell:
	limactl shell $(INSTANCE)

stop:
	limactl stop -f $(INSTANCE)

clean: stop
	-limactl delete -f $(INSTANCE)
	rm -rf out lima-image
