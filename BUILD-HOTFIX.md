# fs-verity Hotfix Build Guide

This document explains how to build and use the `:hotfix` variant of the ubuntu-26.04-desktop-bootc image.

## Background

Ubuntu 26.04 kernel 7.0 has a fs-verity regression (commit f77f281b6118) that breaks overlayfs (used by composefs). Colin Walters' one-line patch fixes this, but it won't land in Ubuntu's kernel until approximately 1-2 weeks from May 5, 2026.

**Upstream issue**: https://github.com/bootc-dev/bootc/issues/2174

## Using the Hotfix Build

### Local Build

```bash
# Build the hotfix variant locally
just build-hotfix

# Test the hotfix image
just test-structure BUILD_IMAGE_TAG=hotfix
```

The hotfix image will be tagged as `localhost/ubuntu-26.04-desktop-bootc:hotfix`.

### CI/CD Build (GitHub Actions)

To trigger a hotfix build in CI:

1. Go to **Actions** → **Build and Publish** workflow
2. Click **Run workflow** (or use the workflow_dispatch trigger)
3. Select build variant: **hotfix**
4. Click **Run workflow**

The hotfix image will be built for both amd64 and arm64, then published to:
- `ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix-amd64`
- `ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix-arm64`
- `ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix` (multi-arch manifest)

### Using the Hotfix Image

```bash
# Pull the hotfix image
podman pull ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix

# Boot it (ephemeral via bcvk, if available)
bcvk ephemeral run-ssh ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix

# Or use in bootc install
sudo bootc install to-filesystem \
  --root-mount-point / \
  ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix
```

## What's in the Hotfix Variant?

The `:hotfix` image includes:

1. **Full GNOME 50 desktop** (same as `:latest`)
2. **fs-verity hotfix documentation** at `/usr/share/doc/ubuntu-bootc/HOTFIX-VERITY.md`
3. **Patch script** at `/usr/local/bin/patch-overlayfs.sh`
4. **Hotfix marker** in `/etc/bootc-hotfix.txt`

### Note: No Kernel Rebuild

The hotfix variant does **NOT** rebuild the kernel in the container image (that would add 30-45 minutes to every build). Instead, it:

- Provides documentation and patches
- Marks the image as hotfix-ready
- Allows users to manually rebuild if needed

For most deployments, wait for Ubuntu to backport the fix to kernel 7.0.0-16-generic (expected ~1-2 weeks), then upgrade via:

```bash
apt-get update && apt-get upgrade linux-generic
```

## Migration Path

Once Ubuntu releases kernel 7.0.0-16-generic+ with the fs-verity fix:

1. The `:latest` image will automatically use the patched kernel on next build
2. The `:hotfix` tag will be deprecated
3. You can switch from `:hotfix` back to `:latest`

Timeline:
- **Now**: Use `:hotfix` if you need this immediately
- **~1-2 weeks**: Ubuntu kernel update lands
- **Then**: Back to `:latest` (which will have the fix)

## Troubleshooting

### Image label check

```bash
podman run --rm ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix \
  cat /etc/bootc-hotfix.txt
```

Should output: `BOOTC_HOTFIX=fs-verity-overlayfs`

### View hotfix documentation

```bash
podman run --rm ghcr.io/ubuntu-bootc/ubuntu-26.04-desktop-bootc:hotfix \
  cat /usr/share/doc/ubuntu-bootc/HOTFIX-VERITY.md
```

## Manual Kernel Rebuild (Advanced)

If you need the actual kernel patched and rebuilt (not recommended for production):

```bash
# This would add 30-45 minutes to the build
# Not recommended for CI/CD pipelines
# Instead, wait for Ubuntu to backport the fix

# See HOTFIX-VERITY.md for full details
cat /usr/share/doc/ubuntu-bootc/HOTFIX-VERITY.md
```

## FAQ

**Q: Can I use `:hotfix` for production?**  
A: Yes, the hotfix image is fully functional. The documentation and scripts just make it clear that this is a temporary variant while waiting for Ubuntu's kernel update.

**Q: When should I switch back to `:latest`?**  
A: When Ubuntu releases kernel 7.0.0-16-generic+ (expected ~1-2 weeks). At that point, `:latest` will include the fs-verity fix and there's no reason to keep using `:hotfix`.

**Q: Does the hotfix image have any performance impact?**  
A: No. The hotfix variant is identical to `:latest` except for added documentation. The workaround (`enabled = yes` fallback) is already in place on both variants.

**Q: What if I already deployed `:latest`?**  
A: You're fine. The current `:latest` images have a composefs fallback that works even without the fs-verity fix. When Ubuntu releases the patched kernel, just upgrade via `apt-get` and you'll automatically get the fix.
