# List available recipes
[group('info')]
default:
    @just --list

# ── Configuration ──────────────────────────────────────────────────────────────
export image_name := env("BUILD_IMAGE_NAME", "ubuntu-26.04-desktop-bootc")
export image_tag  := env("BUILD_IMAGE_TAG",  "latest")
export base_dir   := env("BUILD_BASE_DIR",   ".")
export filesystem := env("BUILD_FILESYSTEM", "xfs")

# VM settings (override with VM_RAM=8192 VM_CPUS=4 just boot-vm)
export vm_ram  := env("VM_RAM",  "4096")
export vm_cpus := env("VM_CPUS", "2")

container_runtime := env(
    "CONTAINER_RUNTIME",
    `command -v podman >/dev/null 2>&1 && echo podman || echo docker`
)

# Use sudo unless we are already root (CI runners run as root)
sudo_cmd := if `id -u` == "0" { "" } else { "sudo" }

# ── Build ──────────────────────────────────────────────────────────────────────

# Build the bootc container image
[group('build')]
build:
    {{sudo_cmd}} {{container_runtime}} build \
        --security-opt label=type:unconfined_t \
        -f Containerfile \
        -t "{{image_name}}:{{image_tag}}" .

# Re-chunk the image for efficient OCI layer distribution
[group('build')]
rechunk:
    #!/usr/bin/env bash
    set -euo pipefail
    CONFIG=$({{sudo_cmd}} {{container_runtime}} inspect "{{image_name}}:{{image_tag}}")
    # Use podman image mount rather than --mount=type=image (better compatibility
    # across podman versions — type=image dest= is not supported on all runners).
    IMGMOUNT=$({{sudo_cmd}} {{container_runtime}} image mount "{{image_name}}:{{image_tag}}")
    {{sudo_cmd}} {{container_runtime}} run --rm \
        -v "${IMGMOUNT}:/chunkah:ro" \
        -e CHUNKAH_CONFIG_STR="$CONFIG" \
        quay.io/coreos/chunkah build \
            --label ostree.bootable=1 \
            --compressed \
            --max-layers 128 \
        | {{sudo_cmd}} {{container_runtime}} load \
        | sort -n \
        | head -n1 \
        | cut -d, -f2 \
        | cut -d: -f3 \
        | xargs -I{} {{sudo_cmd}} {{container_runtime}} tag {} "{{image_name}}:{{image_tag}}"

# Remove generated artifacts (disk image, OVMF vars copy)
[group('build')]
clean:
    rm -f "{{base_dir}}/bootable.raw" "{{base_dir}}/.ovmf-vars.fd"

# ── Development helpers ────────────────────────────────────────────────────────

# Run bootc inside the built container (e.g. `just bootc install to-disk ...`)
[group('dev')]
bootc *ARGS:
    {{sudo_cmd}} {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "{{base_dir}}:/data" \
        --security-opt label=type:unconfined_t \
        "{{image_name}}:{{image_tag}}" bootc {{ARGS}}

# ── Test ───────────────────────────────────────────────────────────────────────

# Run image structure tests inside a throwaway container (fast, no disk needed)
[group('test')]
test-structure:
    {{sudo_cmd}} {{container_runtime}} run --rm --pull=never \
        -v "{{justfile_directory()}}/shared:/shared:ro" \
        --security-opt label=type:unconfined_t \
        "{{image_name}}:{{image_tag}}" \
        bash /shared/test-image.sh

# Run bootc container lint (also runs automatically at the end of `just build`)
[group('test')]
lint:
    {{sudo_cmd}} {{container_runtime}} run --rm --privileged --pull=never \
        --security-opt label=type:unconfined_t \
        "{{image_name}}:{{image_tag}}" \
        bootc container lint

# Create a bootable raw disk image via bootc install to-disk
[group('test')]
generate-bootable-image:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! {{sudo_cmd}} {{container_runtime}} image exists "{{image_name}}:{{image_tag}}"; then
        echo "ERROR: image '{{image_name}}:{{image_tag}}' not found — run 'just build' first." >&2
        exit 1
    fi
    if [ ! -e "{{base_dir}}/bootable.raw" ]; then
        echo "==> Creating 20G disk image at {{base_dir}}/bootable.raw ..."
        fallocate -l 20G "{{base_dir}}/bootable.raw"
    fi
    echo "==> Installing {{image_name}}:{{image_tag}} to disk image ..."
    # Resolve just binary: sudo strips PATH so $(command -v just) returns empty.
    # Try JUST_BIN env (set by CI), then common install locations, then PATH.
    _JUST="${JUST_BIN:-}"
    if [[ -z "$_JUST" ]]; then
        for _p in "$(command -v just 2>/dev/null)"                   /usr/local/bin/just /usr/bin/just                   "${HOME}/.cargo/bin/just" "${HOME}/.local/bin/just"; do
            [[ -x "$_p" ]] && { _JUST="$_p"; break; }
        done
    fi
    [[ -n "$_JUST" ]] || { echo "ERROR: just binary not found"; exit 1; }
    "$_JUST" bootc install to-disk \
        --via-loopback /data/bootable.raw \
        --filesystem "{{filesystem}}" \
        --wipe \
        --composefs-backend \
        --bootloader systemd \
        --karg systemd.firstboot=no \
        --karg quiet \
        --karg splash \
        --karg console=tty0 \
        --karg "console=ttyS0,115200" \
        --karg systemd.debug_shell=ttyS1
    echo "==> Done: {{base_dir}}/bootable.raw"
    sync

    # Patch BLS entry with explicit root=UUID=... so systemd-gpt-auto-generator
    # doesn't need to guess (works around systemd 259+ GPT-auto quirks in CI).
    echo "==> Patching BLS entry with explicit root= ..."
    LOOP2=$(losetup -f --show --partscan "{{base_dir}}/bootable.raw" 2>/dev/null)
    if [[ -n "$LOOP2" ]]; then
        ROOT_UUID=$(blkid -s UUID -o value "${LOOP2}p3" 2>/dev/null || true)
        ROOT_TYPE=$(blkid -s TYPE  -o value "${LOOP2}p3" 2>/dev/null || true)
        if [[ -n "$ROOT_UUID" && -n "$ROOT_TYPE" ]]; then
            EFIMNT=$(mktemp -d)
            mount "${LOOP2}p2" "$EFIMNT" 2>/dev/null && {
                for conf in "$EFIMNT"/loader/entries/*.conf; do
                    [[ -f "$conf" ]] || continue
                    # Only patch if root= not already present
                    if ! grep -q "^options.*root=" "$conf"; then
                        sed -i "s|^options |options root=UUID=${ROOT_UUID} rootfstype=${ROOT_TYPE} |" "$conf"
                        echo "    Patched: root=UUID=${ROOT_UUID} rootfstype=${ROOT_TYPE}"
                        cat "$conf" | grep "^options"
                    fi
                done
                sync
                umount "$EFIMNT" 2>/dev/null
            }
            rmdir "$EFIMNT" 2>/dev/null || true
        fi
        losetup -d "$LOOP2" 2>/dev/null
    fi



# Boot the disk image interactively in QEMU (GTK display + serial debug, SSH on :2222)
[group('test')]
boot-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK=$(realpath "{{base_dir}}/bootable.raw")
    if [ ! -e "$DISK" ]; then
        echo "ERROR: $DISK not found — run 'just generate-bootable-image' first." >&2
        exit 1
    fi

    OVMF_CODE=""
    for f in \
            /usr/share/edk2/ovmf/OVMF_CODE.fd \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/OVMF/OVMF_CODE_4M.fd \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd \
            /usr/share/qemu/OVMF_CODE.fd; do
        [[ -f "$f" ]] && OVMF_CODE="$f" && break
    done
    [[ -n "$OVMF_CODE" ]] || { echo "ERROR: OVMF not found — install ovmf (Ubuntu) or edk2-ovmf (Fedora)." >&2; exit 1; }

    # OVMF_VARS must be writable — keep a local copy so UEFI state persists across reboots
    OVMF_VARS="{{base_dir}}/.ovmf-vars.fd"
    if [ ! -e "$OVMF_VARS" ]; then
        for f in \
                /usr/share/edk2/ovmf/OVMF_VARS.fd \
                /usr/share/OVMF/OVMF_VARS.fd \
                /usr/share/OVMF/OVMF_VARS_4M.fd \
                /usr/share/edk2/x64/OVMF_VARS.4m.fd \
                /usr/share/qemu/OVMF_VARS.fd; do
            [[ -f "$f" ]] && cp "$f" "$OVMF_VARS" && break
        done
    fi

    echo "==> Booting $DISK ({{vm_ram}}M RAM, {{vm_cpus}} CPUs)"
    echo "    Firmware: $OVMF_CODE"
    echo "    SSH forward: ssh -p 2222 root@127.0.0.1"
    echo "    Debug shell on ttyS1 — Ctrl-A C for QEMU monitor"
    echo ""
    QEMU=$(command -v qemu-system-x86_64 /usr/libexec/qemu-kvm /usr/bin/qemu-kvm 2>/dev/null | head -1)
    [[ -n "$QEMU" ]] || { echo "ERROR: qemu not found"; exit 1; }
    "$QEMU" \
        -enable-kvm \
        -m "{{vm_ram}}" \
        -cpu host \
        -smp "{{vm_cpus}}" \
        -drive "file=${DISK},format=raw,if=virtio" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -device virtio-vga \
        -display gtk \
        -device virtio-keyboard \
        -device virtio-mouse \
        -device virtio-net-pci,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22" \
        -chardev "stdio,id=char0,mux=on,signal=off" \
        -serial chardev:char0 \
        -serial chardev:char0 \
        -mon chardev=char0

# Headless boot smoke test — used in CI and locally to verify a disk install boots
[group('test')]
test-boot:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK=$(realpath "{{base_dir}}/bootable.raw")
    if [ ! -e "$DISK" ]; then
        echo "ERROR: $DISK not found — run 'just generate-bootable-image' first." >&2
        exit 1
    fi

    OVMF_CODE=""
    QEMU=$(command -v qemu-system-x86_64 /usr/libexec/qemu-kvm /usr/bin/qemu-kvm 2>/dev/null | head -1)
    [[ -n "$QEMU" ]] || { echo "ERROR: qemu not found." >&2; exit 1; }
    for f in \
            /usr/share/OVMF/OVMF_CODE_4M.fd \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd \
            /usr/share/qemu/OVMF_CODE.fd; do
        [[ -f "$f" ]] && OVMF_CODE="$f" && break
    done
    [[ -n "$OVMF_CODE" ]] || { echo "ERROR: OVMF not found." >&2; exit 1; }



    SERIAL_LOG=$(mktemp /tmp/ubuntu-bootc-XXXX.log)
    TIMEOUT=240
    echo "=== Boot smoke test ==="
    echo "    Disk:    $DISK"
    echo "    OVMF:    $OVMF_CODE"
    echo "    Log:     $SERIAL_LOG"
    echo "    Timeout: ${TIMEOUT}s"
    echo ""

    $QEMU \
        -enable-kvm \
        -m 2048 \
        -cpu host \
        -smp 2 \
        -display none \
        -drive "file=${DISK},format=raw,if=virtio" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -nic none \
        -serial "file:${SERIAL_LOG}" \
        -no-reboot &
    QEMU_PID=$!

    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
        if [[ -f "$SERIAL_LOG" ]] && \
           grep -qE "login:|Reached target.*(multi-user|graphical|Network)" "$SERIAL_LOG" 2>/dev/null; then
            kill "$QEMU_PID" 2>/dev/null || true
            wait "$QEMU_PID" 2>/dev/null || true
            echo ""
            echo "=== PASSED: boot success after ${ELAPSED}s ==="
            # Surface any critical failures even on a successful boot
            CRIT=$(grep -E "\[FAILED\] Failed to start|Kernel panic|dumped core" "$SERIAL_LOG" || true)
            if [[ -n "$CRIT" ]]; then
                echo ""
                echo "WARNING: critical errors in serial log:"
                echo "$CRIT"
            fi
            exit 0
        fi
        sleep 2; (( ELAPSED += 2 ))
        printf "."
    done

    echo ""
    echo "=== FAILED: timeout after ${TIMEOUT}s ==="
    echo "--- last 60 lines of serial ---"
    tail -60 "$SERIAL_LOG" 2>/dev/null | strings || echo "(empty)"
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1

# Requires: bcvk + qemu-kvm + virtiofsd  (see: https://github.com/bootc-dev/bcvk)
# Instant ephemeral boot from the container image — no disk image, no persistent state
[group('test')]
boot-fast: _ensure-bcvk
    #!/usr/bin/env bash
    set -euo pipefail
    if ! {{sudo_cmd}} {{container_runtime}} image exists "{{image_name}}:{{image_tag}}"; then
        echo "ERROR: image '{{image_name}}:{{image_tag}}' not found — run 'just build' first." >&2
        exit 1
    fi
    echo "==> Booting {{image_name}}:{{image_tag}} via bcvk (ephemeral, {{vm_ram}}M, {{vm_cpus}} CPUs)"
    echo "    No disk image needed — boots directly from the container via virtiofs"
    echo ""
    {{sudo_cmd}} bcvk ephemeral run-ssh \
        --memory "{{vm_ram}}M" \
        --vcpus "{{vm_cpus}}" \
        "localhost/{{image_name}}:{{image_tag}}"

# Full end-to-end: build → structure tests → disk image → boot VM
[group('test')]
show-me-the-future:
    #!/usr/bin/env bash
    set -euo pipefail
    _t0=$SECONDS
    _elapsed() { local s=$(( SECONDS - _t0 )); printf '%dm%02ds' $(( s/60 )) $(( s%60 )); }

    echo ""; echo "╔══════════════════════════════════════════╗"
    echo     "║       ubuntu-26.04-desktop-bootc         ║"
    echo     "║   build  →  test  →  disk  →  boot       ║"
    echo     "╚══════════════════════════════════════════╝"; echo ""

    _step() {
        echo "▶ $1 ..."
        if shift && "$@"; then
            echo "✓ $1 ($(_elapsed))"
        else
            echo "✗ FAILED: $1 ($(_elapsed))" >&2; exit 1
        fi
    }

    _step "Build image"              just build
    echo ""
    _step "Structure tests"          just test-structure
    echo ""
    _step "Generate bootable disk"   just generate-bootable-image
    echo ""
    echo "▶ Launching VM (interactive) ..."
    just boot-vm

# ── Private helpers ────────────────────────────────────────────────────────────

# Auto-install bcvk via cargo if not present
[group('dev')]
_ensure-bcvk:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v bcvk &>/dev/null && exit 0
    echo "bcvk not found — attempting to install via cargo ..."
    if command -v cargo &>/dev/null; then
        cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk
    else
        echo "" >&2
        echo "ERROR: bcvk is not installed and cargo is not available." >&2
        echo "" >&2
        echo "Install bcvk:" >&2
        echo "  Cargo:  cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk" >&2
        echo "  dnf:    sudo dnf install bcvk   (Fedora 42+)" >&2
        echo "" >&2
        echo "Also requires: qemu-kvm, virtiofsd" >&2
        exit 1
    fi
