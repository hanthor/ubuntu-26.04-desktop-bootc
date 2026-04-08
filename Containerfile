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

# Full Ubuntu desktop (GNOME 50). ubuntu-desktop pulls linux-generic → linux-image-generic
# (kernel 7.0) and writes vmlinuz to /boot, which we copy before the tmpfs vanishes.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt-get update -y && \
    apt-get install -y ubuntu-desktop && \
    cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz" && \
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
