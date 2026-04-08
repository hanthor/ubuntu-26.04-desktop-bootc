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
        dosfstools \
        dracut \
        e2fsprogs \
        fdisk \
        libostree-dev \
        linux-firmware \
        skopeo \
        systemd \
        systemd-boot \
        systemd-boot-efi \
        xfsprogs && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/*

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

# Build the bootc-compatible initramfs with dracut
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/initramfs.sh

# Set up the ostree/bootc filesystem layout
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    echo "HOME=/var/home" | tee -a "/etc/default/useradd" && \
    /ctx/shared/bootc-rootfs.sh

LABEL containers.bootc 1

RUN bootc container lint
