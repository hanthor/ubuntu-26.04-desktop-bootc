# AGENTS.md — ubuntu-26.04-desktop-bootc

Guidance for AI agents and automated tooling working on this repository.

## What this repo is

A **bootc container image** for Ubuntu 26.04 LTS "Resolute Raccoon" with GNOME 50,
kernel 7.0, ZFS root support, and Plymouth. It is the *payload image* consumed by
the companion live ISO ([tuna-os/ubuntu-26.04-iso](https://github.com/tuna-os/ubuntu-26.04-iso)).
The installed system is maintained via OTA updates through `bootc upgrade`.

## Repository map

```
Containerfile        Multi-stage OCI build (ctx → base → builder → system)
Justfile             Local helpers: build, disk-image, rechunk
shared/
  build.sh           Compiles bootc from upstream source (bootc-dev/bootc, pinned tag)
  initramfs.sh       Builds dracut initramfs (bootc + ZFS modules, hostonly=no)
  bootc-rootfs.sh    Sets up bootc filesystem layout; WIPES /var — see below
recipe.json          fisherman recipe for tuna-installer (ZFS or btrfs)
.github/workflows/   CI: build + push to ghcr.io/hanthor/ubuntu-26.04-desktop-bootc
```

## Build stages

```
ctx      COPY shared/ scripts into the build context
base     ubuntu:26.04 — APT base
builder  Installs Rust toolchain, compiles bootc from source
system   Installs GNOME 50, kernel 7.0, ZFS, Plymouth, Flatpak,
         gnome-initial-setup, openssh-server, sudo; builds initramfs;
         runs bootc-rootfs.sh; runs `bootc container lint`
```

Build locally:

```bash
just build
# or directly:
sudo podman build -f Containerfile -t ubuntu-26.04-desktop-bootc:latest .
```

Output: `localhost/ubuntu-26.04-desktop-bootc:latest`

## Critical constraint: bootc-rootfs.sh wipes /var

`shared/bootc-rootfs.sh` runs near the end of the build. It does:

```bash
rm -rf /var
mkdir -p /var
```

and then creates the bootc/ostree symlink forest:

```
/home  → var/home   (relative symlink)
/root  → var/roothome
/mnt   → var/mnt
/usr/local → ../var/usrlocal
```

**Consequences for this repo:**
- Any file written to `/var/...` before this step is destroyed.
- `/var/lib/dpkg` and `/var/lib/apt` are gone after this step — `apt-get` does NOT
  work in the live ISO session (the ISO Containerfile works around this by restoring
  them from a separate `ubuntu:26.04` stage).
- `/root` is a relative symlink `var/roothome`. `mkdir -p /root/.config` works
  in a running system (symlink resolves) but NOT during a container build layer —
  use `mkdir -p /var/roothome/.config` instead.
- `/mnt` is a relative symlink `var/mnt`. Do not bind-mount to `/mnt` in Containerfile
  `RUN --mount` directives — use `/tmp/...` as the mount target.

## Filesystem layout after install

The installed system uses **composefs** as the sysroot backend:

- `/usr` — read-only composefs overlay
- `/etc` — mutable (bootc managed)  
- `/var` — fully mutable (user data, flatpaks, logs)
- `/home` → `/var/home` — user home directories
- Flatpak remotes are pre-configured in `/etc/flatpak/remotes.d/flathub.flatpakrepo`
  but the actual flatpak data lives in `/var/lib/flatpak` (written at runtime).

## ZFS support

ZFS is supported as the root filesystem via a dedicated fisherman branch
(`feature/zfs-root` on `tuna-os/fisherman`). The image itself includes:

- `zfsutils-linux` — ZFS userspace tools
- `linux-modules-zfs-generic` — ZFS kernel module for linux-generic
- `zfs-dracut` — dracut module for ZFS root import at boot
- `zfs-zed` — ZFS Event Daemon (enabled via systemctl)

**bootc + ZFS incompatibility:** `bootc install to-filesystem` with a ZFS target
fails because the underlying `ostree admin init-fs --modern` calls `statfs()` and
rejects ZFS with "Unknown filesystem: zfs". The workaround is `--composefs-backend`
which takes a different code path that bypasses the ostree filesystem check entirely.
This flag is forced by fisherman's `feature/zfs-root` branch.

## initramfs details

The initramfs is built by `shared/initramfs.sh` using dracut with:
- `--no-hostonly` (generic initramfs, works on any machine)
- `--add "bootc zfs"` modules
- `zstd` compression
- Kernel version auto-detected from `/usr/lib/modules/`

The resulting initramfs lands at `/usr/lib/modules/<kver>/initramfs.img`.

The live ISO **replaces** this initramfs with a `dmsquash-live` one during the ISO
Containerfile build — the base image's initramfs is only used on the *installed* system.

## Plymouth

- Packages: `plymouth` + `plymouth-themes` (system layer)
- Theme: `spinner` (configured in live ISO's `configure-live.sh`)
- Kernel cmdline: `quiet splash` (added in the ISO's `build-iso.sh`)
- dracut integration: `--add plymouth` in the ISO Containerfile's dracut command

Plymouth is in the base image but theme/cmdline configuration is applied by the
ISO build, not here.

## gnome-initial-setup

`gnome-initial-setup` (Ubuntu's modified fork) is installed in the base image
so first-boot OOBE works on the installed system. The live ISO suppresses it in
`configure-live.sh` by:
- Masking `gnome-initial-setup.service`
- Writing `Hidden=true` into the autostart desktop entries
- Dropping `~liveuser/.config/gnome-initial-setup-done`

**Do not add OOBE suppression to this repo.** Suppression is live-ISO-only.

## How to add packages

Add to the appropriate `apt-get install` layer in `Containerfile`:

- **Base utilities** (no kernel dep): the first `RUN apt-get install` block (~line 28)
- **Desktop + kernel** (`ubuntu-desktop-minimal`): the `linux-generic` install block (~line 81)
- **ZFS + system tools**: the second `RUN apt-get install` block (~line 101)

Always add `apt-get clean -y && rm -rf /var/lib/apt/lists/*` at the end of each
layer to keep image size down.

## Relationship to other repos

| Repo | Role |
|------|------|
| `tuna-os/ubuntu-26.04-iso` | Builds live ISO from this image; handles live session setup |
| `tuna-os/fisherman` (`feature/zfs-root`) | Installer backend; consumes this image; handles ZFS partitioning |
| `bootcrew/mono` | Reference for bootc-on-Ubuntu approach; `ubuntu-bootc` is upstream inspiration |

**bootc version:** Built from `bootc-dev/bootc` upstream at the pinned release tag in `shared/build.sh`.
The `hanthor/bootc` fork (previously used for ZFS block-device fixes) is no longer needed — those
fixes landed in upstream bootc as of the v1.1.x series.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `apt-get: command not found` in live session | bootc-rootfs.sh wiped `/var/lib/dpkg` | ISO Containerfile restores dpkg db from `ubuntu:26.04` stage |
| `mkdir: /root/.config: not a directory` during build | `/root` → `var/roothome` symlink | Use `mkdir -p /var/roothome/.config` |
| `No space left on device` during ISO build | `/tmp` tmpfs too small | Build ISO with `output_dir=/var/tmp/ubuntu-iso-output` |
| `bootc install to-filesystem` fails on ZFS | ostree `statfs()` rejects ZFS | Use `--composefs-backend` flag (fisherman forces this) |
| `/mnt/...` bind mount fails in Containerfile | `/mnt` → `var/mnt` dangling symlink | Use `/tmp/...` as mount target |
