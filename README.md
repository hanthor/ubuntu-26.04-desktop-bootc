# ubuntu-26.04-desktop-bootc

A bootc-compatible container image for **Ubuntu 26.04 LTS "Resolute Raccoon"** with the full GNOME 50 desktop environment and kernel 7.0.

Based on the approach from [bootcrew/mono](https://github.com/bootcrew/mono), this image builds [bootc](https://github.com/bootc-dev/bootc) from source and wires it into an Ubuntu 26.04 base with a complete desktop stack.

## What's inside

| Component | Version |
|-----------|---------|
| Base OS   | Ubuntu 26.04 LTS (Resolute Raccoon) |
| Desktop   | GNOME 50 (via `ubuntu-desktop`) |
| Kernel    | Linux 7.0 (via `linux-image-generic`) |
| Init      | systemd |
| Bootloader | systemd-boot |
| Initramfs | dracut (bootc module, zstd compressed) |
| Filesystem | composefs (sysroot read-only) |

## Requirements

- [Podman](https://podman.io/) or Docker
- [just](https://just.systems/)
- A Linux host with at least 30 GB free disk space for the build

## Build

```bash
just build
```

This produces a local image tagged `ubuntu-26.04-desktop-bootc:latest`.

## Create a bootable disk image

```bash
# Creates bootable.img (20 GB raw disk) in the current directory
just disk-image
```

You can then write it to a USB drive or boot it in a VM:

```bash
# Write to a USB drive (replace /dev/sdX)
sudo dd if=bootable.img of=/dev/sdX bs=4M status=progress conv=fsync

# Boot in QEMU (UEFI)
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=bootable.img
```

## Update a running system

On a booted system, pull and apply an updated image:

```bash
sudo bootc upgrade
```

## Re-chunk for efficient OCI distribution

```bash
just rechunk
```

## CI / Publishing

GitHub Actions builds multi-arch images (`amd64` + `arm64`) and pushes to GHCR on every push to `main`. Weekly scheduled rebuilds pick up upstream package updates.

To enable image signing, add a `SIGNING_SECRET` repository secret containing your cosign private key.

## Project layout

```
Containerfile       — multi-stage build definition
Justfile            — local build / disk-image helpers
shared/
  build.sh          — compiles bootc from source
  initramfs.sh      — generates dracut initramfs with bootc module
  bootc-rootfs.sh   — sets up the ostree/composefs filesystem layout
.github/workflows/
  build.yaml        — CI: build, rechunk, publish, sign
```
