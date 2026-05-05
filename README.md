# ubuntu-26.04-desktop-bootc

Ubuntu 26.04 LTS "Resolute Raccoon" **desktop** bootc image — GNOME 50,
kernel 7.0, ZFS support, Plymouth, and Flatpak/Flathub.

Derives from the minimal bootc base. Designed to be installed from the
companion live ISO ([tuna-os/ubuntu-26.04-iso](https://github.com/tuna-os/ubuntu-26.04-iso))
via fisherman, with ZFS or btrfs as the target filesystem.

```
ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest
```

## Image hierarchy

```
docker.io/library/ubuntu:26.04
└── ghcr.io/hanthor/ubuntu-26.04-bootc
    ├── ghcr.io/hanthor/ubuntu-26.04-server-bootc
    └── ghcr.io/hanthor/ubuntu-26.04-desktop-bootc   ← you are here
```

| Image | Description |
|-------|-------------|
| [ubuntu-26.04-bootc](https://github.com/hanthor/ubuntu-26.04-bootc) | Minimal base — kernel, bootc, dracut, ssh, podman |
| [ubuntu-26.04-server-bootc](https://github.com/hanthor/ubuntu-26.04-server-bootc) | Server layer — cloud-init, netplan, ufw, snapd, chrony |
| **[ubuntu-26.04-desktop-bootc](https://github.com/hanthor/ubuntu-26.04-desktop-bootc)** | This image — GNOME 50 desktop layer |

## What this adds over the base

| Component | Package |
|-----------|---------|
| Desktop | `ubuntu-desktop-minimal` (GNOME 50) |
| Splash | `plymouth` + `plymouth-themes` |
| Apps | `flatpak` + Flathub remote (`/etc/flatpak/remotes.d/`) |
| ZFS root | `zfsutils-linux`, `zfs-dracut`, `linux-modules-zfs-generic`, `zfs-zed` |
| First-run OOBE | `gnome-initial-setup` |
| Initramfs | Rebuilt with `bootc + plymouth + zfs` dracut modules |

Everything from [ubuntu-26.04-bootc](https://github.com/hanthor/ubuntu-26.04-bootc)
is also present: kernel 7.0, systemd-boot, openssh-server, podman, skopeo, sssd, sudo.

## Building locally

```bash
just build
```

## Create a bootable disk image (for testing)

```bash
just generate-bootable-image   # creates base_dir/bootable.raw (20 GB)
just test-boot                 # headless QEMU smoke test
just boot-vm                   # interactive QEMU with GTK display
```

## OTA updates on an installed system

```bash
sudo bootc upgrade
```

## Related projects

| Repo | Role |
|------|------|
| [tuna-os/ubuntu-26.04-iso](https://github.com/tuna-os/ubuntu-26.04-iso) | Live ISO that installs this image |
| [tuna-os/fisherman](https://github.com/tuna-os/fisherman) | Installer backend; handles ZFS partitioning |
| [ubuntu-26.04-bootc](https://github.com/hanthor/ubuntu-26.04-bootc) | Minimal base this image derives from |
| [ubuntu-26.04-server-bootc](https://github.com/hanthor/ubuntu-26.04-server-bootc) | Server sibling image |

## Known issues

- [#2](https://github.com/hanthor/ubuntu-26.04-desktop-bootc/issues/2) — composefs verity regression on kernel 7.0 (`f77f281b6118`)
- [#3](https://github.com/hanthor/ubuntu-26.04-desktop-bootc/issues/3) — `sysroot.mount` / `systemd-gpt-auto-generator` quirk on Ubuntu 26.04

## Project layout

```
Containerfile          FROM ubuntu-26.04-bootc + GNOME + ZFS + plymouth
Justfile               build / generate-bootable-image / test-boot / boot-vm
shared/
  initramfs.sh         dracut with bootc + plymouth + zfs modules
  bootc-rootfs.sh      ostree symlink forest (wipes /var — see AGENTS.md)
  test-image.sh        structure tests run in CI
recipe.json            fisherman recipe (ZFS or btrfs install)
```
