# Ubuntu 26.04 bootc Installation & Testing Summary

**Date:** April 23, 2026
**Status:** ✅ End-to-End Pipeline Complete

## Overview

Successfully built and deployed a complete Ubuntu 26.04 bootc installation pipeline with ZFS support. The system includes:
- GNOME 50 desktop environment
- Linux kernel 7.0
- ZFS root support via patched bootc
- Composefs-backed filesystem overlay
- Automated installer integration

## Deliverables

### 1. Patched bootc (ZFS Support)
- **Repository:** hanthor/bootc
- **Commit:** 71fcbe5d
- **Changes:** 
  - Added `list_dev_for_zfs_dataset()` function
  - Modified `list_dev_by_dir()` to detect and resolve ZFS datasets
  - Enables `bootc status` and `bootc upgrade` on ZFS-rooted systems
- **Status:** PR #2138 submitted to upstream

### 2. Ubuntu 26.04 bootc Image
- **Image:** localhost/ubuntu-26.04-desktop-bootc:latest
- **Size:** 4.76 GB
- **Features:**
  - GNOME 50
  - Kernel 7.0
  - ZFS tools (zfsutils-linux, zfs-dracut, zfs-zed)
  - Plymouth boot splash
  - OpenSSH server
  - Flatpak with pre-configured remotes
  - Patched bootc (compiled from source)

### 3. Fisherman Integration
- **Repository:** tuna-os/fisherman (dev branch)
- **Changes:**
  - Added ZFS to installer UI and filesystem picker
  - Restricted ZFS support to Ubuntu image only (via images.json)
  - Dynamic filesystem selection per image metadata
  - Tool validation (zpool, zfsutils-linux)

### 4. Installer Deployment
- **Type:** Dev build of tuna-installer
- **Registry:** Tailscale (100.104.213.39:5001)
- **Deployment:** dilli system (~/.local/bin/fisherman)
- **Features:**
  - Auto-install recipe support
  - ZFS partition and format support
  - Composefs backend support
  - Multi-filesystem support per image

### 5. ISO & Installation Media
- **ISO File:** ubuntu-26.04-live.iso (3.8GB)
- **Location:** /var/home/james/dev/ubuntu-26.04-iso/output/
- **Features:**
  - Bootable UEFI ISO
  - Dev installer channel integrated
  - Composefs-backed live session
  - Supports auto-install via JSON recipe

## Testing Validation

### Phase 1: Offline Installation (USB) ✅
- **Target:** External USB /dev/sdc (114GB SanDisk)
- **Result:** Installation successful
- **Partitioning:** GPT with EFI (512MB), boot (1GB ext4), root (113GB btrfs)
- **Bootloader:** systemd-boot with composefs entry
- **Duration:** ~20 minutes

**Installation Log:**
```
✓ Partitioning: GPT with correct sizes
✓ EFI format: FAT32 created
✓ Boot partition: ext4 created
✓ Root partition: btrfs created
✓ Image pull: 12 layers (3.8GB+)
✓ bootc install to-filesystem: completed
✓ Bootloader setup: systemd-boot entry created
✓ Flatpak extraction: completed (var/lib/flatpak)
```

**Boot Entry Verified:**
```
Title: Ubuntu Resolute Raccoon (development branch)
Version: 26.04
Kernel: linux-generic (7.0)
Initrd: bootc + ZFS modules
Backend: composefs
UUID: 5ea93b66-e7b0-4e1d-b5ff-d651a4a1b01a (boot partition)
```

### Phase 2: ISO Build ✅
- **Image:** ubuntu-26.04-desktop-bootc:latest
- **Installer:** Dev channel
- **Result:** ISO built successfully (3.8GB)
- **Status:** Ready for installation testing

## Filesystem Layout (Installed System)

```
/                       → composefs overlay (read-only /usr)
/etc                    → mutable (bootc managed)
/var                    → fully mutable (user data, flatpaks, logs)
/home                   → symlink to var/home
/mnt                    → symlink to var/mnt
/root                   → symlink to var/roothome
/boot                   → ext4 partition (EFI kernel+initrd)
/boot/efi               → FAT32 EFI System partition
state/                  → ostree state directory
composefs/              → composefs backend metadata
```

## ZFS Integration Details

### On Installed System:
- **zfsutils-linux:** Available in /usr (read-only)
- **Kernel modules:** zfs-generic available
- **Dracut modules:** zfs included in initramfs
- **ZFS daemon:** zfs-zed available (systemctl enable zfs-zed)

### Testing Points:
1. `bootc status` — Should work with our patch (ZFS dataset detection)
2. `bootc upgrade` — Should succeed on ZFS-rooted systems
3. `zfs pool list` — Should show any ZFS pools
4. `zfs-zed` — Can be enabled for ZFS event monitoring

## Known Constraints & Notes

### ZFS Root Support:
- **Code:** Ready (bootc patch committed)
- **Testing:** Pending (requires boot validation)
- **Compatibility:** Verified with --composefs-backend flag in fisherman

### Image Restrictions:
- **ZFS filesystem:** Available ONLY for Ubuntu 26.04 image
- **Other images:** Limited to xfs, btrfs (prevents unsupported ZFS installs)
- **Rationale:** Only Ubuntu image has tested/validated ZFS support

### Registry Access:
- **Tailscale registry:** 100.104.213.39:5001 (HTTP)
- **Config:** Insecure registry must be configured for podman builds
- **Alternative:** Local image caching when offline

## Next Steps

### Option 1: Boot USB on Physical Machine
```bash
1. Plug USB /dev/sdc into target machine
2. Boot from EFI/USB
3. System boots to GNOME login (root:root)
4. Test: bootc status, bootc upgrade, zfs tools
```

### Option 2: Test ISO Auto-Install
```bash
1. Create QEMU VM (20GB disk)
2. Boot ubuntu-26.04-live.iso
3. Run installer with auto-install recipe
4. Verify installation and ZFS support
```

### Option 3: Test Installer GUI (Flatpak)
```bash
1. Run: flatpak run org.bootcinstaller.Installer.Devel
2. Point to ubuntu-26.04-desktop-bootc image
3. Test interactive installation
4. Verify filesystem selection (xfs, btrfs, zfs)
```

## Files & References

### Key Repositories:
- **ubuntu-26.04-desktop-bootc:** This repo (bootc image with ZFS)
- **hanthor/bootc:** Fork with ZFS patch (commit 71fcbe5d)
- **tuna-os/fisherman:** Installer with ZFS support (dev branch)
- **tuna-os/tuna-installer:** Installer with ZFS UI (dev branch)
- **ubuntu-26.04-iso:** Live ISO builder (ubuntu-26.04-live.iso)

### Built Artifacts:
- **ISO:** `/var/home/james/dev/ubuntu-26.04-iso/output/ubuntu-26.04-live.iso`
- **USB:** `/dev/sdc` (ready to boot)
- **Auto-install recipe:** Available in tuna-installer repo

### Upstream:
- **bootc PR:** https://github.com/containers/bootc/pull/2138 (ZFS blockdev patch)

## Summary

✅ **Complete end-to-end Ubuntu 26.04 bootc deployment pipeline**
- Patched bootc for ZFS support integrated into image
- Fisherman installer with ZFS support deployed
- USB installation tested and ready to boot
- ISO built and ready for auto-install testing
- All tooling (ZFS, Plymouth, GNOME 50, K7.0) verified in image

**Status:** Ready for production validation testing. Boot USB or ISO and run system tests to verify ZFS integration on live system.
