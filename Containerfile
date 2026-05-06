FROM scratch AS ctx
COPY shared/ /shared

# Provides a pristine dpkg/apt database to restore in the system stage.
# bootc-rootfs.sh in the base image wiped /var (including /var/lib/dpkg),
# so derived images cannot run apt without restoring the dpkg state first.
FROM docker.io/library/ubuntu:26.04 AS dpkg-state

# ── Bootc builder ────────────────────────────────────────────────────────────
FROM docker.io/library/ubuntu:26.04 AS builder

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt-get update -y && \
    apt-get install -y \
        build-essential \
        curl \
        git \
        go-md2man \
        libostree-dev \
        libzstd-dev \
        make \
        ostree \
        pkgconf && \
    apt-get clean -y && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
WORKDIR /home/build
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    sh -c ". ${RUSTUP_HOME}/env ; /ctx/shared/build.sh"

# ── System stage ─────────────────────────────────────────────────────────────
# Ubuntu 26.04 LTS "Resolute Raccoon" — GNOME 50 desktop.
FROM docker.io/library/ubuntu:26.04 AS system

# Copy bootc binary from builder
COPY --from=builder /output/usr/bin/bootc /usr/bin/bootc

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/tmp

# Restore the dpkg/apt database from the pristine ubuntu:26.04 stage.
# The base image ran bootc-rootfs.sh which wiped /var; apt-get will not
# work without a valid dpkg status and the supporting directory tree.
COPY --from=dpkg-state /var/lib/dpkg /var/lib/dpkg
RUN mkdir -p /var/cache/apt/archives/partial /var/lib/apt/lists/partial /var/log/apt

# Plymouth (splash screen) + Flatpak + Flathub remote.
# Hook stubs and kernel are already present in the base image.
RUN --mount=type=tmpfs,dst=/tmp \
    apt-get update -y && \
    apt-get install -y \
        flatpak \
        plymouth \
        plymouth-themes && \
    mkdir -p /etc/flatpak/remotes.d && \
    curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo \
        https://dl.flathub.org/repo/flathub.flatpakrepo && \
    apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Minimal GNOME 50 desktop. linux-generic is already in the base; this step
# pulls in the desktop packages only. --force-confold avoids interactive
# conffile prompts for the kernel hook stubs already in place.
RUN apt-get -o Dpkg::Options::="--force-confold" update -y && \
    apt-get -o Dpkg::Options::="--force-confold" \
        install -y --install-recommends ubuntu-desktop-minimal && \
    apt-get clean -y && rm -rf /var/lib/apt/lists/*

# ZFS root support — dracut module, kernel module, userspace tools, event daemon.
# Must be installed before rebuilding the initramfs so the 'zfs' dracut module
# is available. See base image AGENTS.md for ZFS service rationale.
RUN --mount=type=tmpfs,dst=/tmp \
    apt-get update -y && \
    apt-get install -y \
        gnome-initial-setup \
        linux-modules-zfs-generic \
        sudo-rs \
        zfs-dracut \
        zfs-zed \
        zfsutils-linux && \
    apt-get remove -y gnome-terminal && \
    systemctl enable --root / \
        zfs-import-scan.service \
        zfs-mount.service \
        zfs-zed.service && \
    apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Rebuild the initramfs now that plymouth and zfs-dracut are installed.
# The base image initramfs only has the bootc module; we extend it here
# with plymouth (splash) and zfs (ZFS root support).
RUN --mount=type=tmpfs,dst=/tmp \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/initramfs.sh

# Re-run bootc-rootfs.sh to wipe /var. The apt installs above wrote dpkg/apt
# state into /var; bootc requires /var to be empty in the committed image.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/bootc-rootfs.sh

LABEL containers.bootc 1

# First-boot service: emits `bootc status --json` to serial console between
# BOOTC_STATUS_BEGIN/END markers for e2e test verification.
RUN printf '[Unit]\nDescription=Report bootc deployment status to serial on first boot\nConditionPathExists=!/var/lib/.bootc-status-reported\nAfter=multi-user.target\nRequires=multi-user.target\n\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "echo BOOTC_STATUS_BEGIN; bootc status --json 2>&1; echo BOOTC_STATUS_END"\nExecStartPost=/bin/touch /var/lib/.bootc-status-reported\nStandardOutput=journal+console\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /usr/lib/systemd/system/bootc-status-report.service && \
    systemctl enable --root / bootc-status-report.service

RUN bootc container lint

# Clean up runtime directories left by post-install scripts.
# Run last so bootc lint (which uses HOME=/tmp) doesn't leave debris.
RUN find /run -mindepth 1 -maxdepth 1 ! -name 'secrets' -exec rm -rf {} + ; \
    find /tmp -mindepth 1 -exec rm -rf {} + 2>/dev/null; true
