#!/usr/bin/env bash
# test-image.sh — structural tests for the ubuntu-26.04-desktop-bootc image.
# Run inside the container via:  podman run --rm -v ./shared:/shared:ro <image> bash /shared/test-image.sh
# Every check prints PASS/FAIL; exits 1 if any check fails.

set -uo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $desc"
        (( PASS++ ))
    else
        echo "  FAIL  $desc"
        (( FAIL++ ))
    fi
}

section() { echo ""; echo "── $* ──────────────────────────────────────────────────────"; }

# ── bootc filesystem layout ──────────────────────────────────────────────────
section "bootc filesystem layout"
check "/home  is a symlink"           test -L /home
check "/home  → var/home"             test "$(readlink /home)"       = "var/home"
check "/root  is a symlink"           test -L /root
check "/root  → var/roothome"         test "$(readlink /root)"       = "var/roothome"
check "/mnt   is a symlink"           test -L /mnt
check "/mnt   → var/mnt"              test "$(readlink /mnt)"        = "var/mnt"
check "/srv   is a symlink"           test -L /srv
check "/srv   → var/srv"              test "$(readlink /srv)"        = "var/srv"
check "/opt   is a symlink"           test -L /opt
check "/opt   → var/opt"              test "$(readlink /opt)"        = "var/opt"
check "/ostree is a symlink"          test -L /ostree
check "/ostree → sysroot/ostree"      test "$(readlink /ostree)"     = "sysroot/ostree"
check "/usr/local is a symlink"       test -L /usr/local
check "/usr/local → ../var/usrlocal"  test "$(readlink /usr/local)"  = "../var/usrlocal"
check "/sysroot dir exists"           test -d /sysroot

# ── kernel + initramfs ───────────────────────────────────────────────────────
section "kernel + initramfs"
KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)
if [[ -z "$KVER" ]]; then
    echo "  FAIL  cannot detect kernel version (no dirs under /usr/lib/modules)"
    (( FAIL++ ))
else
    echo "        kernel: $KVER"
    check "vmlinuz at /usr/lib/modules/$KVER/vmlinuz"        test -f "/usr/lib/modules/${KVER}/vmlinuz"
    check "initramfs.img at /usr/lib/modules/$KVER/"         test -f "/usr/lib/modules/${KVER}/initramfs.img"
    check "initramfs.img is non-empty"                       test -s "/usr/lib/modules/${KVER}/initramfs.img"
fi

# ── composefs / bootc config ─────────────────────────────────────────────────
section "composefs / bootc config"
check "prepare-root.conf exists"              test -f /usr/lib/ostree/prepare-root.conf
check "composefs enabled = yes"               grep -q "enabled = yes"    /usr/lib/ostree/prepare-root.conf
check "sysroot readonly = true"               grep -q "readonly = true"  /usr/lib/ostree/prepare-root.conf

# ── tmpfiles.d ───────────────────────────────────────────────────────────────
section "tmpfiles.d"
check "bootc-base-dirs.conf exists"           test -f /usr/lib/tmpfiles.d/bootc-base-dirs.conf
check "var/home entry"                        grep -q "var/home"    /usr/lib/tmpfiles.d/bootc-base-dirs.conf
check "var/roothome entry"                    grep -q "var/roothome" /usr/lib/tmpfiles.d/bootc-base-dirs.conf
check "var/usrlocal entry"                    grep -q "var/usrlocal" /usr/lib/tmpfiles.d/bootc-base-dirs.conf

# ── useradd defaults ─────────────────────────────────────────────────────────
section "useradd defaults"
check "HOME=/var/home in /etc/default/useradd" grep -q "HOME=/var/home" /etc/default/useradd

# ── Flatpak ──────────────────────────────────────────────────────────────────
section "Flatpak"
check "Flathub .flatpakrepo present"          test -f /etc/flatpak/remotes.d/flathub.flatpakrepo

# ── ZFS systemd units ────────────────────────────────────────────────────────
section "ZFS systemd units"
check "zfs-import-scan.service enabled"       systemctl is-enabled --root / zfs-import-scan.service
check "zfs-mount.service enabled"             systemctl is-enabled --root / zfs-mount.service
check "zfs-zed.service enabled"               systemctl is-enabled --root / zfs-zed.service

# ── sssd ────────────────────────────────────────────────────────────────────
section "sssd"
check "sssd package installed"                dpkg -s sssd

# ── security ─────────────────────────────────────────────────────────────────
section "security"
check "root password locked (!/*)"            grep -q "^root:[!*]" /etc/shadow
check "/run is empty (no post-install debris)" test -z "$(ls -A /run 2>/dev/null)"
check "/tmp is empty (no post-install debris)" test -z "$(ls -A /tmp 2>/dev/null)"

# ── result ───────────────────────────────────────────────────────────────────
echo ""
if (( FAIL > 0 )); then
    echo "RESULT: ${PASS} passed, ${FAIL} FAILED ✗"
    exit 1
else
    echo "RESULT: ${PASS} passed, 0 failed ✓"
fi
