export DOCKER_HOST ?= $(shell docker context inspect --format "{{.Endpoints.docker.Host}}")
LK := bin/linuxkit
LINUXKIT_VERSION := v1.8.2
all: out/limakit-efi.img

$(LK):
	mkdir -p bin
	curl -fsSL -o $@ https://github.com/linuxkit/linuxkit/releases/download/$(LINUXKIT_VERSION)/linuxkit-$$(uname -s | tr A-Z a-z)-$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
	chmod +x $@

lima-image: $(wildcard lima-init/* lima-init/shims/*)
	docker build -t limakit/lima:dev lima-init
	touch $@

# linuxkit pulls from the docker cache first, so the local image is picked up
out/limakit-efi.img: limakit.yml lima-image | $(LK)
	mkdir -p out && $(LK) build --docker --format raw-efi --arch arm64 --size 2048M --dir out --name limakit limakit.yml
	mv out/limakit-efi.raw $@ 2>/dev/null || mv out/limakit-efi.img $@ 2>/dev/null || true

# Custom kernel (kernel/limakit.config on top of LinuxKit's); ~25 min, wants >=6 CPUs/8GiB.
# KERNEL_CONTEXT: docker context to build on; the image is then copied to the current context.
KERNEL_VERSION ?= 6.12.59
KERNEL_CONTEXT ?= $(shell docker context show)
.PHONY: kernel
kernel: | $(LK)
	DOCKER_HOST=$$(docker context inspect --format '{{.Endpoints.docker.Host}}' $(KERNEL_CONTEXT)) kernel/build.sh $(KERNEL_VERSION)
	[ "$(KERNEL_CONTEXT)" = "$$(docker context show)" ] || docker --context $(KERNEL_CONTEXT) save linuxkit/kernel:$(KERNEL_VERSION)-limakit | docker load

# Local testing with Lima. `run` recreates the instance from out/limakit-efi.img
# every time (the image is copied at create); docker data survives on the limakit-docker disk.
INSTANCE := limakit
.PHONY: run shell stop clean
run: out/limakit-efi.img
	-limactl delete -f $(INSTANCE)
	limactl disk list 2>/dev/null | grep -q '^limakit-docker ' || limactl disk create limakit-docker --size 50GiB
	limactl create --name $(INSTANCE) --tty=false lima.yaml
	limactl start $(INSTANCE) --tty=false
	@echo "try: make shell   (or: docker -H ssh://lima-$(INSTANCE) ps, with ~/.lima/$(INSTANCE)/ssh.config in ~/.ssh/config)"

shell:
	limactl shell $(INSTANCE)

stop:
	limactl stop -f $(INSTANCE)

clean: stop
	-limactl delete -f $(INSTANCE)
	rm -rf out lima-image
