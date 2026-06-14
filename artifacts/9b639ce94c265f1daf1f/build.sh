#!/usr/bin/env bash
set -euo pipefail

REPO="${1:?Usage: $0 <kernel-source-dir>}"
REPO="$(cd "$REPO" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDS_DIR="$SCRIPT_DIR/builds"
CONFIG_FILE="/workspaces/mono-repo/libs/artiphishell_agents/tests/hackerone/linux_kernel/configs/9b639ce94c265f1daf1f.config"

# Use sccache
export CC="gcc"
export HOSTCC="gcc"
if command -v sccache &>/dev/null; then
    export CC="sccache gcc"
    export HOSTCC="sccache gcc"
fi

NPROC="$(nproc)"

build_kernel() {
    local variant="$1"
    local build_dir="$BUILDS_DIR/$variant"

    echo "=== Building kernel variant: $variant ==="
    mkdir -p "$build_dir"

    # Copy base config
    cp "$CONFIG_FILE" "$build_dir/.config"

    # The provided config already has KASAN + UBSAN + CUSE=y built in.
    # We just use it as-is for the primary KASAN variant.
    # For different variants we could tweak, but the base config already
    # includes KASAN_GENERIC + UBSAN, which is perfect.
    case "$variant" in
        kasan)
            # Base config already has KASAN + UBSAN. Use as-is.
            ;;
    esac

    # Finalize config
    make -C "$REPO" O="$build_dir" olddefconfig CC="$CC" HOSTCC="$HOSTCC" 2>&1 | tail -5

    # Verify critical configs
    echo "--- Verifying config for $variant ---"
    grep -E 'CONFIG_KASAN=|CONFIG_CUSE=|CONFIG_FUSE_FS=|CONFIG_UBSAN=' "$build_dir/.config" || true

    # Build
    echo "--- Building bzImage for $variant (this may take a while) ---"
    make -C "$REPO" O="$build_dir" -j"$NPROC" bzImage CC="$CC" HOSTCC="$HOSTCC" 2>&1 | tail -20

    if [ -f "$build_dir/arch/x86/boot/bzImage" ]; then
        echo "=== SUCCESS: $variant kernel built at $build_dir/arch/x86/boot/bzImage ==="
    else
        echo "=== FAILED: $variant kernel build failed ==="
        return 1
    fi
}

# Compile PoC statically
echo "=== Compiling PoC ==="
gcc -static -o "$SCRIPT_DIR/poc" "$SCRIPT_DIR/poc.c"
echo "=== PoC compiled at $SCRIPT_DIR/poc ==="

# Build the KASAN variant (already in the config)
build_kernel kasan

echo ""
echo "=== All builds complete ==="
ls -la "$BUILDS_DIR"/*/arch/x86/boot/bzImage 2>/dev/null || true
