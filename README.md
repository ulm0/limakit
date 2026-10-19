# limakit

A [LinuxKit](https://github.com/linuxkit/linuxkit)-built guest image for [Lima](https://lima-vm.io), with Docker as the baseline.
It targets Apple Silicon (`vmType: vz`) and supports Lima's full (non-plain) mode: guest agent, host mounts,
dynamic port forwarding, provisioning scripts and so on.

## Requirements

- macOS on Apple Silicon, Lima ≥ 2.0 (tested with 2.2.1)
- A Docker daemon to build with (any context; the kernel build wants ≥ 6 CPUs / 8 GiB)
- `curl`, `make`. The pinned `linuxkit` CLI (v1.8.2) is downloaded to `bin/` on first use.

## Quick start

The image uses a custom kernel that isn't published anywhere, so build it once first (~25 min):

```sh
make kernel                              # on the current docker context
make kernel KERNEL_CONTEXT=colima-kbuild # or on a bigger one; the image is copied back
```

Then build the image and start it:

```sh
make run      # builds out/limakit-efi.img, (re)creates the `limakit` instance, starts it
make shell    # limactl shell limakit
make stop     # limactl stop -f limakit
make clean    # delete the instance and build outputs (the data disk is kept)
```

Use Docker from the Mac through the forwarded socket:

```sh
export DOCKER_HOST=unix://$HOME/.lima/limakit/sock/docker.sock
docker run --rm -p 8080:80 nginx   # reachable on localhost:8080
```

`make run` recreates the instance on every run, because Lima copies the image when it creates an instance.
Docker data lives on the `limakit-docker` disk, so it survives.

## How it works

LinuxKit's root filesystem is read-only and lives in RAM. Everything runs as containerd services:

| Service | Role |
|---|---|
| `lima` (`lima-init/`) | Alpine container that does cloud-init's job: reads Lima's cidata ISO, creates the user and keys, writes `/etc/fstab`, sets timezone, CA certs and DNS, and runs `bootcmd`. It then starts sshd and runs Lima's own `boot.sh`. `shims/` are a minimal OpenRC stand-in, so Lima installs and starts `lima-guestagent` (and `rosettad`) the OpenRC way. |
| `docker` | `docker:28-dind`, pinned by digest. Socket at `/run/dockersock/docker.sock`. |
| `dhcpcd`, `acpid`, `ntpd`, `rngd`, `trim-after-delete` | LinuxKit packages. `acpid` gets a power-button action, so `limactl stop` shuts down cleanly. |

Lima's mounts (virtiofs or reverse-sshfs) happen in the `lima` service. They propagate into dockerd's
namespace through shared roots (`/Users`, `/Volumes`, `/mnt`, `/home`, `/tmp`) bound `rshared` → `rslave`, so `docker run -v ~/proj:/x` works.

## Things to know

- **The data disk must stay first** under `additionalDisks` in `lima.yaml`. LinuxKit formats it once if it's
  blank (label `limakit-data`, `/dev/vdb`) and mounts it at `/var/lib`, where docker data, the guest `/home`, `/root`, `/usr/local` and
  the ssh host keys live. Add other disks after it; Lima formats those (`format`/`fsType` work). limakit also works around a Lima
  bug that re-formats disks whose names don't fit the filesystem's label limit (ext4: 11 chars, xfs: 7).
- **Docker only sees Lima mounts under `/Users`, `/Volumes`, `/mnt`, `/home` and `/tmp`.** A mount elsewhere works in the
  guest shell, but `docker run -v` sees an empty directory. The boot log warns about such mounts.
- **Memory:** the whole image unpacks into RAM (~1 GiB), so the VM needs ≥ 4 GiB (`memory:` in `lima.yaml`).
- **Provisioning scripts run in the `lima` container**, not on the LinuxKit host. Put persistent state under
  `/var/lib` or the shared roots.

## Lima feature support

Tested on an M4 Mac, macOS 27, Lima 2.2.1:

- **Works:**
  - mounts: virtiofs and reverse-sshfs (ro/rw), all visible to `docker run -v`
  - port forwarding: TCP and UDP, plus the docker socket on the host; `limactl tunnel`
  - provisioning: `system`, `user`, `boot`, `dependency`, `data`, `ansible`, `param`, probes
  - `additionalDisks`, including `fsType: btrfs`; discard/trim reaches the host disk file
  - networking: `networks: vzNAT`, `networks: lima: user-v2` (incl. `lima-<name>.internal`), `dns:`,
    `host.lima.internal` (also from containers)
  - host integration: `caCerts`, timezone, `env:`, `ssh.forwardAgent`, SSH over vsock
  - VM features: Rosetta (binfmt plus the `rosettad` cache via CDI: `--device lima-vm.io/rosetta=cached`),
    `nestedVirtualization`, `audio`
  - lifecycle: `limactl cp`, `limactl stop`
- **Works guest-side, needs a host install to use:**
  - X11 forwarding: the guest sets up `DISPLAY`; drawing needs XQuartz on the Mac.
  - `socket_vmnet` networks: need `socket_vmnet` plus `limactl sudoers` on the host (see Lima's docs).
    Not tested here.
- **Not tested:** `video.display` (a console window on the Mac; not needed for Docker).
- **Not supported:**
  - Lima's built-in containerd (`containerd.system`/`user`, so `nerdctl.lima` too) and templates that need
    systemd (k8s, k0s, podman, faasd). Lima requires `systemctl` for these.
  - Snapshots and TPM, which Lima's vz driver doesn't implement.
  - `mdns` (Lima only supports it via systemd-resolved).

## Kernel

`kernel/limakit.config` lists the options limakit sets on top of LinuxKit's kernel config, each with the
Lima feature that needs it. `kernel/build.sh` does the following:

1. Checks out LinuxKit's kernel packaging at a pinned commit.
2. Applies the options and normalizes the config with `olddefconfig` in LinuxKit's own builder image.
3. Fails if any option didn't take.
4. Builds `linuxkit/kernel:<version>-limakit`.

The resulting full config is kept in `kernel/config-aarch64` for review.

To move to another kernel, build it, then set `kernel.image` in `limakit.yml`:

```sh
make kernel KERNEL_VERSION=6.12.60
```

For a series LinuxKit doesn't package yet (e.g. 7.x), the script starts from LinuxKit's newest series
config. New options get their defaults, so review `kernel/config-aarch64` afterwards.
