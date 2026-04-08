#!/usr/bin/env bash
# test-vm.sh — Install ubuntu-26.04-desktop-bootc with fisherman and boot it in QEMU.
# Usage: sudo ./test-vm.sh [--disk-only]
#
# Pass --disk-only to skip the QEMU boot step (just install to disk).
# The resulting disk image is written to ./bootable.img.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FISHERMAN="${SCRIPT_DIR}/fisherman"
IMAGE="localhost/ubuntu-26.04-desktop-bootc:latest"
DISK_IMG="${SCRIPT_DIR}/bootable.img"
DISK_SIZE="20G"
RECIPE="${SCRIPT_DIR}/recipe.json"
BOOT_LOG="${SCRIPT_DIR}/boot.log"
BOOT_TIMEOUT=300
DISK_ONLY=false
QEMU=$(command -v qemu-system-x86_64 2>/dev/null || echo /home/linuxbrew/.linuxbrew/bin/qemu-system-x86_64)

[[ "${1:-}" == "--disk-only" ]] && DISK_ONLY=true

# ── Pre-flight ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (sudo $0)" >&2
    exit 1
fi
for bin in "$FISHERMAN" podman; do
    if ! command -v "$bin" &>/dev/null && [[ "$bin" != "$FISHERMAN" ]]; then
        echo "ERROR: $bin not found" >&2; exit 1
    fi
    if [[ "$bin" == "$FISHERMAN" ]] && [[ ! -x "$bin" ]]; then
        echo "ERROR: fisherman binary not found at $FISHERMAN" >&2; exit 1
    fi
done
if ! podman image exists "$IMAGE"; then
    echo "ERROR: image $IMAGE not found locally. Build it first with:"
    echo "  sudo podman build -f Containerfile -t $IMAGE ."
    exit 1
fi

# ── Disk setup ────────────────────────────────────────────────────────────────
echo "==> Creating ${DISK_SIZE} sparse disk image at ${DISK_IMG} ..."
if [[ -e "$DISK_IMG" ]]; then
    echo "    (removing existing image)"
    rm -f "$DISK_IMG"
fi
fallocate -l "$DISK_SIZE" "$DISK_IMG"

LOOPDEV=$(losetup --find --show "$DISK_IMG")
echo "    loop device: $LOOPDEV"

cleanup() {
    echo "==> Cleaning up loop device ..."
    losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

# ── Write fisherman recipe ─────────────────────────────────────────────────────
cat > "$RECIPE" <<EOF
{
  "disk":            "$LOOPDEV",
  "filesystem":      "xfs",
  "composeFsBackend": true,
  "unifiedStorage":  false,
  "selinuxDisabled": true,
  "encryption":      {"type": "none"},
  "image":           "$IMAGE",
  "hostname":        "ubuntu-bootc-test",
  "flatpaks":        []
}
EOF
echo "==> Recipe written to $RECIPE"
cat "$RECIPE"

# ── Run fisherman ──────────────────────────────────────────────────────────────
echo ""
echo "==> Running fisherman ..."
"$FISHERMAN" "$RECIPE"
echo "==> fisherman done"

# ── Verify partition layout ────────────────────────────────────────────────────
echo ""
echo "==> Partition layout:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$LOOPDEV" || true

LABEL_COUNT=$(lsblk -o LABEL "$LOOPDEV" | grep -cE 'EFI-SYSTEM|boot|root' || true)
if [[ "$LABEL_COUNT" -ne 3 ]]; then
    echo "FAIL: expected 3 labelled partitions, got $LABEL_COUNT"
    exit 1
fi
echo "OK: 3-partition GPT layout verified"

# ── Check composefs hostname ───────────────────────────────────────────────────
ROOT_MNT=$(mktemp -d)
mount "${LOOPDEV}p3" "$ROOT_MNT"
if [[ -f "$ROOT_MNT/etc/hostname" ]]; then
    echo "OK: hostname = $(cat "$ROOT_MNT/etc/hostname")"
else
    echo "WARN: /etc/hostname not found at $ROOT_MNT/etc/hostname — composefs sysroot may use different layout"
    find "$ROOT_MNT" -name hostname 2>/dev/null | head -5 || true
fi
umount "$ROOT_MNT"
rmdir "$ROOT_MNT"

[[ "$DISK_ONLY" == "true" ]] && echo "==> --disk-only: skipping QEMU boot" && exit 0

# ── Patch BLS entries for serial console ──────────────────────────────────────
echo ""
echo "==> Patching bootloader entries for serial console ..."
patch_entries() {
    local part="$1" label="$2"
    local mnt; mnt=$(mktemp -d)
    mount "$part" "$mnt" || { echo "    Cannot mount $label, skipping"; rmdir "$mnt"; return; }
    local patched=0
    for conf in "$mnt"/loader/entries/*.conf; do
        [[ -f "$conf" ]] || continue
        grep -q "console=ttyS0" "$conf" || { sed -i 's/^options /options console=ttyS0,115200 /' "$conf"; patched=1; }
        grep -q "root=" "$conf"          || { sed -i 's/^options /options root=\/dev\/vda3 /'        "$conf"; patched=1; }
        [[ $patched -eq 1 ]] && echo "    Patched ($label): $(basename "$conf")" && grep "^options" "$conf"
    done
    [[ $patched -eq 0 ]] && echo "    No entries to patch on $label"
    umount "$mnt"; rmdir "$mnt"
}
patch_entries "${LOOPDEV}p1" "EFI"
patch_entries "${LOOPDEV}p2" "boot"

# ── QEMU boot test ────────────────────────────────────────────────────────────
OVMF_CODE=""
for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/OVMF/OVMF_CODE.secboot.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
    [[ -f "$f" ]] && OVMF_CODE="$f" && break
done
OVMF_VARS=""
for f in /usr/share/edk2/ovmf/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
    [[ -f "$f" ]] && OVMF_VARS="$f" && break
done
if [[ -z "$OVMF_CODE" ]]; then
    echo "ERROR: OVMF not found — install ovmf package" >&2; exit 1
fi

# Release the loop device before handing the raw image to QEMU
trap - EXIT
losetup -d "$LOOPDEV"

echo ""
echo "==> Booting in QEMU (timeout ${BOOT_TIMEOUT}s) — serial log: $BOOT_LOG"
echo "    OVMF: $OVMF_CODE"
echo "    Press Ctrl-C to abort (QEMU will keep running with -no-reboot until timeout)"

timeout "$BOOT_TIMEOUT" "$QEMU" \
    -enable-kvm \
    -cpu host \
    -m 2048 \
    -smp 2 \
    -drive "file=${DISK_IMG},format=raw,if=virtio" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,snapshot=on,file=${OVMF_VARS}" \
    -serial "file:${BOOT_LOG}" \
    -nographic \
    -no-reboot &
QEMU_PID=$!

# Stream the log as QEMU writes it, stop as soon as we see a success marker
echo "    (waiting for boot — streaming serial output...)"
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if grep -qE 'login:|Reached target.*(multi-user|graphical|Network Name Lookups)' "$BOOT_LOG" 2>/dev/null; then
        echo "    (boot success detected, stopping QEMU)"
        kill "$QEMU_PID" 2>/dev/null || true
        break
    fi
    sleep 2
done
wait "$QEMU_PID" 2>/dev/null || true
QEMU_EXIT=$?

echo ""
echo "==> Boot log tail (last 30 lines):"
tail -30 "$BOOT_LOG"

# Check for success indicators
BOOT_OK=0
grep -qE 'login:|Reached target.*(multi-user|graphical|Network Name Lookups)' "$BOOT_LOG" && BOOT_OK=1

# Check for critical failures
FAILURES=$(grep -E 'systemd-coredump.*dumped core|\[FAILED\] Failed to start|Kernel panic' "$BOOT_LOG" || true)

echo ""
if [[ $BOOT_OK -eq 0 ]]; then
    echo "FAIL: no boot success indicator found in serial log"
    exit 1
elif [[ -n "$FAILURES" ]]; then
    echo "FAIL: boot reached userspace but critical failures detected:"
    echo "$FAILURES"
    exit 1
else
    echo "PASS: Ubuntu 26.04 desktop bootc image booted successfully!"
fi
