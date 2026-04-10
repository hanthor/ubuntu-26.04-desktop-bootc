# ubuntu-26.04-desktop-bootc

A [bootc](https://github.com/bootc-dev/bootc)-compatible container image for **Ubuntu 26.04 LTS "Resolute Raccoon"** — GNOME 50 desktop, kernel 7.0, ZFS support, and Plymouth boot splash.

The image is designed to be installed from the companion live ISO ([tuna-os/ubuntu-26.04-iso](https://github.com/tuna-os/ubuntu-26.04-iso)) via the tuna-installer, with **ZFS root** or btrfs as the target filesystem.

## What's inside

| Component | Details |
|-----------|---------|
| Base OS | Ubuntu 26.04 LTS "Resolute Raccoon" |
| Desktop | GNOME 50 (`ubuntu-desktop-minimal`) |
| Kernel | Linux 7.0 (`linux-generic`) |
| Init | systemd |
| Bootloader | systemd-boot |
| Initramfs | dracut (bootc module, zstd-compressed, `hostonly=no`) |
| Sysroot | composefs (read-only, overlaid at runtime) |
| ZFS | OpenZFS 2.x (`zfsutils-linux`, `zfs-dracut`, kernel module) |
| Plymouth | `spinner` theme (boot splash) |
| Flatpak | Flathub remote pre-configured via `/etc/flatpak/remotes.d/` |
| First-run | `gnome-initial-setup` (Ubuntu edition) |
| Remote access | `openssh-server` |
| Privilege | `sudo` |
| bootc | Built from source (Rust/cargo) |

## Requirements

- [Podman](https://podman.io/) ≥ 4.5
- [just](https://just.systems/)
- Linux host, x86_64
- At least 30 GB free disk space (build + layer cache)

## Build

```bash
just build
```

This produces `localhost/ubuntu-26.04-desktop-bootc:latest`.

The build is multi-stage and takes 20–40 minutes on first run (Rust compilation). Subsequent builds are fast thanks to layer caching.

## Create a bootable raw disk image

```bash
just disk-image          # creates bootable.img (20 GB) via bootc install to-disk
```

Flash to USB or boot in QEMU:

```bash
# Flash
sudo dd if=bootable.img of=/dev/sdX bs=4M status=progress conv=fsync

# QEMU (UEFI — Secure Boot not required)
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive format=raw,file=bootable.img
```

## OTA updates on a running system

```bash
sudo bootc upgrade
```

## Re-chunk for efficient OCI distribution

```bash
just rechunk
```

Produces a maximally layer-deduplicated image suitable for GHCR distribution.

## CI / Publishing

GitHub Actions builds and pushes `ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest` on every push to `main`. Weekly rebuilds pick up upstream Ubuntu package updates.

## Project layout

```
Containerfile
│  Multi-stage build:
│    ctx      — build context (shared scripts)
│    base     — ubuntu:26.04 base
│    builder  — Rust toolchain + bootc source compile
│    system   — installs GNOME 50, kernel 7.0, ZFS, Plymouth, Flatpak
│
shared/
  build.sh         — compiles bootc from source (cargo install)
  initramfs.sh     — builds dracut initramfs with bootc + ZFS modules
  bootc-rootfs.sh  — sets up the bootc/composefs filesystem layout
                     (wipes /var, creates ostree symlinks)
Justfile           — build / disk-image / rechunk helpers
recipe.json        — fisherman recipe for tuna-installer disk install
```
