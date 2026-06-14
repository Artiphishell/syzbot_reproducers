#!/bin/bash
set -e

# build.sh - Build kernel configurations for maple tree data race reproduction
# Usage: ./build.sh <path-to-kernel-source>
#
# Creates 3 kernel configurations:
#   1. kcsan         - KCSAN for data race detection (reuses existing build)
#   2. kcsan_strict  - KCSAN strict mode, more watchpoints, no permissive
#   3. standard      - Baseline with lockdep, no sanitizers
#
# Caching: Uses ccache for compiler caching; reuses existing build objects

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?Usage: $0 <kernel-source-path>}"
SRC="$(cd "$SRC" && pwd)"

BUILDS_DIR="$SCRIPT_DIR/builds"
LOGS_DIR="$SCRIPT_DIR/logs"
NPROC=$(nproc)
JOBS=$((NPROC > 32 ? 32 : NPROC))

export CCACHE_DIR="$SCRIPT_DIR/.ccache"
mkdir -p "$CCACHE_DIR" "$BUILDS_DIR" "$LOGS_DIR"

echo "[*] Kernel source: $SRC"
echo "[*] Build dir: $BUILDS_DIR"
echo "[*] Jobs: $JOBS"
echo "[*] Using ccache at $CCACHE_DIR"

# Existing pre-built KCSAN kernel
EXISTING_BUILD="$SRC/out-38a879f4-j4"
EXISTING_BZIMAGE="$EXISTING_BUILD/arch/x86/boot/bzImage"
EXISTING_CONFIG="$EXISTING_BUILD/.config"

compile_poc() {
    echo "[*] Compiling PoC..."
    gcc -static -O2 -pthread -o "$SCRIPT_DIR/poc_bin" "$SCRIPT_DIR/poc.c"
    echo "[*] PoC compiled: $SCRIPT_DIR/poc_bin"
}

create_initramfs() {
    local config_name="$1"
    local initramfs_dir="$BUILDS_DIR/$config_name/initramfs"
    
    rm -rf "$initramfs_dir"
    mkdir -p "$initramfs_dir"/{bin,dev,proc,sys,tmp,etc}
    
    cp /usr/bin/busybox "$initramfs_dir/bin/busybox"
    for cmd in sh cat echo ls mkdir mount umount sleep dmesg grep; do
        ln -sf busybox "$initramfs_dir/bin/$cmd"
    done
    
    cp "$SCRIPT_DIR/poc_bin" "$initramfs_dir/bin/poc"
    
    cat > "$initramfs_dir/init" <<'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp

# Enable KCSAN if available
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
if [ -f /sys/kernel/debug/kcsan ]; then
    echo "on" > /sys/kernel/debug/kcsan 2>/dev/null || true
    echo "[init] KCSAN enabled via debugfs"
fi

echo "[init] Kernel: $(cat /proc/version)"
echo "[init] Running PoC (will drop privileges to uid 1000)..."

/bin/poc

echo "[init] PoC completed. Checking dmesg..."
dmesg | grep -B2 -A 30 "BUG: KCSAN" 2>/dev/null || true
dmesg | grep -B2 -A 30 "BUG: KASAN" 2>/dev/null || true
dmesg | grep -c "data-race" 2>/dev/null && echo "[init] Found data-race reports" || true

echo o > /proc/sysrq-trigger 2>/dev/null || true
sleep 2
/bin/busybox poweroff -f 2>/dev/null || true
INIT
    chmod +x "$initramfs_dir/init"
    
    (cd "$initramfs_dir" && find . | cpio -o -H newc 2>/dev/null | gzip) > "$BUILDS_DIR/$config_name/initramfs.cpio.gz"
    echo "[*] Created initramfs for $config_name"
}

setup_existing_build() {
    local config_name="$1"
    local out_dir="$BUILDS_DIR/$config_name"
    
    echo "============================================"
    echo "[*] Setting up $config_name (reusing existing build)"
    echo "============================================"
    
    mkdir -p "$out_dir/arch/x86/boot"
    
    if [ -f "$EXISTING_BZIMAGE" ]; then
        rm -f "$out_dir/arch/x86/boot/bzImage"
        cp "$EXISTING_BZIMAGE" "$out_dir/arch/x86/boot/bzImage"
        rm -f "$out_dir/.config"
        cp "$EXISTING_CONFIG" "$out_dir/.config" 2>/dev/null || true
        echo "[*] Copied existing KCSAN kernel"
    else
        echo "[!] ERROR: No existing KCSAN build found at $EXISTING_BZIMAGE"
        return 1
    fi
    
    create_initramfs "$config_name"
}

build_kernel() {
    local config_name="$1"
    local config_mods="$2"
    local out_dir="$BUILDS_DIR/$config_name"
    
    echo "============================================"
    echo "[*] Building kernel config: $config_name"
    echo "============================================"
    
    # Skip if already built
    if [ -f "$out_dir/arch/x86/boot/bzImage" ]; then
        echo "[*] bzImage already exists, skipping build"
        create_initramfs "$config_name"
        return 0
    fi
    
    # Ensure source tree is clean for O= builds
    if [ -f "$SRC/vmlinux.o" ] || [ -f "$SRC/.config" ]; then
        echo "[*] Cleaning source tree for O= build..."
        make -C "$SRC" mrproper 2>&1 | tail -3
    fi
    
    mkdir -p "$out_dir"
    
    # Start from existing config
    if [ -f "$EXISTING_CONFIG" ]; then
        rm -f "$out_dir/.config"
        cp "$EXISTING_CONFIG" "$out_dir/.config"
    else
        make -C "$SRC" O="$out_dir" CC="ccache gcc" defconfig 2>&1 | tail -3
    fi
    
    # Apply config modifications
    eval "$config_mods"
    
    # Regenerate config
    make -C "$SRC" O="$out_dir" CC="ccache gcc" olddefconfig 2>&1 | tail -5
    
    echo "[*] Key config for $config_name:"
    grep -E 'CONFIG_KCSAN=|CONFIG_KASAN=|CONFIG_PER_VMA_LOCK=|CONFIG_SMP=' "$out_dir/.config" 2>/dev/null || true
    
    echo "[*] Building kernel (timeout 600s)..."
    if timeout 600 make -C "$SRC" O="$out_dir" CC="ccache gcc" -j"$JOBS" bzImage 2>&1 | tail -20; then
        if [ -f "$out_dir/arch/x86/boot/bzImage" ]; then
            echo "[*] Kernel built: $out_dir/arch/x86/boot/bzImage"
        else
            echo "[!] Build FAILED for $config_name (no bzImage)"
            return 1
        fi
    else
        echo "[!] Build FAILED for $config_name"
        return 1
    fi
    
    create_initramfs "$config_name"
}

# Compile PoC
compile_poc

# Config 1: Reuse existing KCSAN build (fast)
setup_existing_build "kcsan"

# Config 2: KCSAN strict mode
build_kernel "kcsan_strict" '
    local cfg="$out_dir/.config"
    sed -i "s/.*CONFIG_KCSAN_EARLY_ENABLE.*/CONFIG_KCSAN_EARLY_ENABLE=y/" "$cfg"
    sed -i "s/.*CONFIG_KCSAN_PERMISSIVE.*/# CONFIG_KCSAN_PERMISSIVE is not set/" "$cfg"
    sed -i "s/.*CONFIG_KCSAN_SELFTEST.*/# CONFIG_KCSAN_SELFTEST is not set/" "$cfg"
    sed -i "s/CONFIG_KCSAN_SKIP_WATCH=.*/CONFIG_KCSAN_SKIP_WATCH=500/" "$cfg"
    sed -i "s/CONFIG_KCSAN_REPORT_ONCE_IN_MS=.*/CONFIG_KCSAN_REPORT_ONCE_IN_MS=0/" "$cfg"
    sed -i "s/CONFIG_KCSAN_NUM_WATCHPOINTS=.*/CONFIG_KCSAN_NUM_WATCHPOINTS=128/" "$cfg"
'

# Config 3: Standard - no sanitizers baseline
build_kernel "standard" '
    local cfg="$out_dir/.config"
    sed -i "s/CONFIG_KCSAN=y/# CONFIG_KCSAN is not set/" "$cfg"
    sed -i "s/.*CONFIG_KASAN.*/# CONFIG_KASAN is not set/" "$cfg"
'

echo ""
echo "[*] All builds complete!"
for cfg in kcsan kcsan_strict standard; do
    bz="$BUILDS_DIR/$cfg/arch/x86/boot/bzImage"
    initrd="$BUILDS_DIR/$cfg/initramfs.cpio.gz"
    if [ -f "$bz" ]; then
        sz=$(stat -c%s "$bz")
        echo "  [OK] $cfg: bzImage=$(echo $sz | numfmt --to=iec)B initramfs=$(test -f "$initrd" && echo "OK" || echo "MISSING")"
    else
        echo "  [MISSING] $cfg"
    fi
done
