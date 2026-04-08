image_name := "ubuntu-26.04-desktop-bootc"
image_tag  := env("BUILD_IMAGE_TAG", "latest")
base_dir   := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
selinux    := env("BUILD_SELINUX", "true")

options := if selinux == "true" {
    "-v /var/lib/containers:/var/lib/containers:Z \
     -v /etc/containers:/etc/containers:Z \
     -v /sys/fs/selinux:/sys/fs/selinux \
     --security-opt label=type:unconfined_t"
} else {
    "-v /var/lib/containers:/var/lib/containers \
     -v /etc/containers:/etc/containers"
}

container_runtime := env(
    "CONTAINER_RUNTIME",
    `command -v podman >/dev/null 2>&1 && echo podman || echo docker`
)

# Build the bootc container image
build:
    sudo {{container_runtime}} build -f Containerfile -t "{{image_name}}:{{image_tag}}" .

# Run bootc inside the container (pass sub-commands as ARGS, e.g. `just bootc install to-disk ...`)
bootc *ARGS:
    sudo {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        {{options}} \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{base_dir}}:/data" \
        "{{image_name}}:{{image_tag}}" bootc {{ARGS}}

# Create a 20 GB raw disk image and install onto it
disk-image:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e "{{base_dir}}/bootable.img" ]; then
        fallocate -l 20G "{{base_dir}}/bootable.img"
    fi
    just bootc install to-disk \
        --composefs-backend \
        --via-loopback /data/bootable.img \
        --filesystem "{{filesystem}}" \
        --wipe \
        --bootloader systemd

# Re-chunk the image for efficient OCI layer distribution
rechunk:
    #!/usr/bin/env bash
    set -euo pipefail
    export CHUNKAH_CONFIG_STR="$({{container_runtime}} inspect "{{image_name}}:{{image_tag}}")"
    {{container_runtime}} run --rm \
        "--mount=type=image,src={{image_name}}:{{image_tag}},dest=/chunkah" \
        -e CHUNKAH_CONFIG_STR \
        quay.io/coreos/chunkah build \
            --label ostree.bootable=1 \
            --compressed \
            --max-layers 128 \
        | {{container_runtime}} load \
        | sort -n \
        | head -n1 \
        | cut -d, -f2 \
        | cut -d: -f3 \
        | xargs -I{} {{container_runtime}} tag {} "{{image_name}}:{{image_tag}}"
