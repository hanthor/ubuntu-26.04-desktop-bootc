FROM scratch AS ctx

COPY shared/ /shared

# Ubuntu 26.04 LTS "Resolute Raccoon" — ships GNOME 50 and kernel 7.0
FROM docker.io/library/ubuntu:26.04 AS base

FROM base AS builder

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt-get update -y && \
    apt-get install -y git curl make build-essential go-md2man libzstd-dev pkgconf libostree-dev ostree

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
WORKDIR /home/build
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    sh -c ". ${RUSTUP_HOME}/env ; /ctx/shared/build.sh"

FROM base AS system
COPY --from=builder /output /

ENV DEBIAN_FRONTEND=noninteractive

# Base system utilities (no kernel here — let ubuntu-desktop pull linux-generic)
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt-get update -y && \
    apt-get install -y \
        btrfs-progs \
        curl \
        dbus \
        dosfstools \
        dracut \
        e2fsprogs \
        fdisk \
        flatpak \
        libostree-dev \
        linux-firmware \
        plymouth \
        plymouth-themes \
        rsync \
        skopeo \
        systemd \
        systemd-boot \
        systemd-boot-efi \
        xfsprogs && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/*

# Pre-configure Flathub as a system remote.
# /var/lib/flatpak is mutable at runtime (not part of the image), so we cannot
# call `flatpak remote-add` here.  Instead, drop the .flatpakrepo file into
# /etc/flatpak/remotes.d/ — flatpak auto-discovers and registers it on first use.
RUN mkdir -p /etc/flatpak/remotes.d && \
    curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo \
        https://dl.flathub.org/repo/flathub.flatpakrepo

# Stub out kernel/grub/kdump post-install hooks that fail in a container.
# We generate the initramfs ourselves with dracut in a later step.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs && \
    chmod +x /usr/sbin/update-initramfs && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/mkinitramfs && \
    chmod +x /usr/sbin/mkinitramfs && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-grub && \
    chmod +x /usr/sbin/update-grub && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/grub-mkconfig && \
    chmod +x /usr/sbin/grub-mkconfig && \
    mkdir -p /etc/kernel/postinst.d && \
    printf '#!/bin/sh\nexit 0\n' > /etc/kernel/postinst.d/kdump-tools && \
    chmod +x /etc/kernel/postinst.d/kdump-tools

# Minimal GNOME 50 desktop + kernel 7.0. No LibreOffice — apps go in as flatpaks.
# Hooks are stubbed above so the kernel post-install won't crash crun.
# DEBIAN_FRONTEND set inline (--isolation=chroot doesn't inherit ENV).
# --force-confold avoids interactive conffile prompts for our stubbed hooks.
RUN --mount=type=tmpfs,dst=/root \
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::="--force-confold" update -y && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::="--force-confold" \
        install -y --install-recommends ubuntu-desktop-minimal linux-generic && \
    KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1 | xargs basename) && \
    cp "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz" && \
    rm -rf /boot/* && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/*

# ZFS root support — tools, kernel module, dracut integration, and event daemon.
# zfs-dracut installs /usr/lib/dracut/modules.d/90zfs which the initramfs.sh step uses.
# linux-modules-zfs-generic provides the ZFS .ko for the generic kernel we install above.
# Enable the ZFS systemd units so an installed ZFS-root system boots correctly:
#   - zfs-import-scan.service  — scans for pools (correct for generic hostonly=no initramfs
#                                that cannot embed a machine-specific /etc/zfs/zpool.cache)
#   - zfs-mount.service        — mounts additional datasets (var, etc.) after initramfs
#   - zfs-zed.service          — ZFS Event Daemon (scrub, trim, events)
# NOTE: zfs-import-cache.service is NOT enabled here because the installed system's
# /etc/zfs/zpool.cache is written by zfs-install.sh post-install, and the prebuilt
# generic initramfs (hostonly=no) cannot include it. scan is the reliable first-boot path.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    apt-get update -y && \
    apt-get install -y \
        gnome-initial-setup \
        linux-modules-zfs-generic \
        openssh-server \
        sssd \
        sudo-rs \
        zfs-dracut \
        zfs-zed \
        zfsutils-linux && \
    # ubuntu-desktop-minimal installs both gnome-terminal and ptyxis; keep only ptyxis.
    apt-get remove -y gnome-terminal && \
    systemctl enable --root / \
        zfs-import-scan.service \
        zfs-mount.service \
        zfs-zed.service && \
    apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Build the bootc-compatible initramfs with dracut
# zfs-dracut must be installed before this step so the 'zfs' dracut module is available.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/initramfs.sh

# Set up the ostree/bootc filesystem layout
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    echo "HOME=/var/home" | tee -a "/etc/default/useradd" && \
    /ctx/shared/bootc-rootfs.sh

LABEL containers.bootc 1

# Clear /run and /tmp content left behind by package post-install scripts.
# These are runtime-only directories and must be empty in the image.
# /run/secrets is a bind-mount injected by Podman during build — skip it.
RUN find /run -mindepth 1 -maxdepth 1 ! -name 'secrets' -exec rm -rf {} + ; \
    rm -rf /tmp/*

RUN bootc container lint
