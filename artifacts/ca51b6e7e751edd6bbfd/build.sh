#!/bin/bash
# build.sh <repo-sources>
# Builds kernel with KASAN + PoC for bpf_trace_run4 slab-use-after-free
set -euo pipefail

REPO="${1:?Usage: $0 <repo-sources>}"
REPO="$(realpath "$REPO")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="/workspaces/mono-repo/libs/artiphishell_agents/tests/hackerone/linux_kernel/configs/ca51b6e7e751edd6bbfd.config"

echo "[build.sh] Source: $REPO"

export SCCACHE_DIR="${SCCACHE_DIR:-/tmp/sccache}"
export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-20G}"
mkdir -p "$SCCACHE_DIR"

CC_WRAP="sccache gcc"
BUILD_DIR="$SCRIPT_DIR/builds/kasan"
mkdir -p "$BUILD_DIR"

echo "[build.sh] Building KASAN kernel..."

cp "$CONFIG_SRC" "$BUILD_DIR/.config"

# Adapt config for GCC build (original config was for clang 21)
sed -i '/CONFIG_CC_IS_CLANG/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CLANG_VERSION/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_AS_IS_LLVM/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_LD_IS_LLD/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_LLD_VERSION/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CC_VERSION_TEXT/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_GCC_VERSION/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_AS_VERSION/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_LD_VERSION/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CC_HAS_COUNTED_BY/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CC_HAS_BROKEN_COUNTED_BY_REF/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CC_HAS_MULTIDIMENSIONAL_NONSTRING/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_CC_HAS_ASSUME/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_RUSTC/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_RUST_IS_AVAILABLE/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_PAHOLE_HAS_BTF_TAG/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_PAHOLE_HAS_LANG_EXCLUDE/d' "$BUILD_DIR/.config"
sed -i '/CONFIG_PAHOLE_VERSION/d' "$BUILD_DIR/.config"
sed -i 's/CONFIG_DEBUG_INFO_BTF=y/# CONFIG_DEBUG_INFO_BTF is not set/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_DEBUG_INFO_BTF_MODULES=y/# CONFIG_DEBUG_INFO_BTF_MODULES is not set/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_BPF_PRELOAD_UMD=y/# CONFIG_BPF_PRELOAD_UMD is not set/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_RUST=y/# CONFIG_RUST is not set/' "$BUILD_DIR/.config"

make -C "$REPO" O="$BUILD_DIR" CC="gcc" HOSTCC="gcc" olddefconfig 2>&1 | tail -5

echo "[build.sh] Checking critical configs..."
for cfg in CONFIG_KASAN CONFIG_KASAN_GENERIC CONFIG_PREEMPT CONFIG_BPF_SYSCALL CONFIG_BPF_EVENTS CONFIG_SLUB_RCU_DEBUG; do
    val=$(grep "^${cfg}=" "$BUILD_DIR/.config" 2>/dev/null || echo "NOT SET")
    echo "  $cfg = $val"
done

make -C "$REPO" O="$BUILD_DIR" \
    CC="$CC_WRAP" HOSTCC="sccache gcc" \
    -j$(nproc) \
    bzImage 2>&1 | tail -20

if [ ! -f "$BUILD_DIR/arch/x86/boot/bzImage" ]; then
    echo "[build.sh] FAILED: bzImage not found"
    exit 1
fi
echo "[build.sh] SUCCESS: $BUILD_DIR/arch/x86/boot/bzImage"
ls -lh "$BUILD_DIR/arch/x86/boot/bzImage"

# Compile PoC using kernel UAPI headers for correct union bpf_attr layout
echo ""
echo "[build.sh] Compiling PoC..."
gcc -O2 -static -pthread \
    -I"$REPO/include/uapi" \
    -I"$REPO/arch/x86/include/uapi" \
    -I"$BUILD_DIR/include/generated/uapi" \
    -I"$BUILD_DIR/arch/x86/include/generated/uapi" \
    -Wno-all \
    -o "$SCRIPT_DIR/builds/poc" \
    "$SCRIPT_DIR/poc.c"
echo "[build.sh] PoC compiled: $SCRIPT_DIR/builds/poc"

echo ""
echo "[build.sh] All builds complete."
