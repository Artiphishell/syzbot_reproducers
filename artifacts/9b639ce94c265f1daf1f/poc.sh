#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDS_DIR="$SCRIPT_DIR/builds"
LOGS_DIR="$SCRIPT_DIR/logs"
INITRAMFS="/workspaces/mono-repo/libs/artiphishell_agents/tests/hackerone/linux_kernel/initramfs/initramfs.cpio.gz"
POC_BINARY="$SCRIPT_DIR/poc"

# Prepare logs directory
rm -rf "$LOGS_DIR"
mkdir -p "$LOGS_DIR"

prepare_initramfs() {
    local variant="$1"
    local work_dir="$LOGS_DIR/$variant/initramfs_work"
    local output="$LOGS_DIR/$variant/initramfs.cpio.gz"

    mkdir -p "$work_dir"
    mkdir -p "$LOGS_DIR/$variant"

    # Unpack existing initramfs
    cd "$work_dir"
    zcat "$INITRAMFS" | cpio -idm 2>/dev/null || true

    # Inject the PoC binary
    cp "$POC_BINARY" "$work_dir/poc"
    chmod +x "$work_dir/poc"

    # Write a custom init script
    cat > "$work_dir/init" << 'INITEOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc     proc  /proc
mount -t sysfs    sysfs /sys
mount -t devtmpfs dev   /dev 2>/dev/null || true
mount -t tmpfs    tmpfs /tmp
mount -t tmpfs    tmpfs /run
mkdir -p /dev/pts
mount -t devpts   devpts /dev/pts 2>/dev/null || true

# Redirect all output to serial console
exec > /dev/ttyS0 2>&1

echo "[init] Booting..."
hostname kernel-vm
ifconfig lo 127.0.0.1 up

echo ""
echo "=============================================="
echo "  BOOT COMPLETE: kernel-vm is ready"
echo "=============================================="
echo ""

# Make /dev/cuse accessible to non-root users
echo "[init] Setting permissions on /dev/cuse..."
ls -la /dev/cuse 2>&1 || echo "[init] /dev/cuse not found"
chmod 0666 /dev/cuse 2>/dev/null || echo "[init] chmod /dev/cuse failed"

# Grant capabilities to the PoC
if [ -x /poc ]; then
    echo "[init] Granting capabilities and running /poc as vscode ..."
    setcap cap_net_admin,cap_net_raw+eip /poc 2>/dev/null || true
    echo "[init] Running PoC..."
    su vscode -s /bin/sh -c /poc
    POC_EXIT=$?
    echo "[init] /poc exited with status $POC_EXIT"
fi

echo "[init] Sleeping 5s to collect kernel logs..."
sleep 5

# Dump dmesg for crash evidence
echo "[init] === dmesg tail ==="
dmesg | tail -100

echo "[init] Powering off..."
poweroff -f
INITEOF
    chmod +x "$work_dir/init"

    # Repack
    cd "$work_dir"
    find . | sort | cpio -o -H newc 2>/dev/null | gzip -1 > "$output"

    echo "$output"
}

run_variant() {
    local variant="$1"
    local kernel="$2"
    local log_dir="$LOGS_DIR/$variant"
    local serial_log="$log_dir/serial.log"

    mkdir -p "$log_dir"

    echo "=== Running variant: $variant ==="
    echo "    Kernel: $kernel"

    # Prepare initramfs with PoC
    local initramfs
    initramfs="$(prepare_initramfs "$variant")"
    echo "    Initramfs: $initramfs"
    echo "    Serial log: $serial_log"

    timeout 180 qemu-system-x86_64 \
        -m 2048 \
        -smp 1 \
        -kernel "$kernel" \
        -initrd "$initramfs" \
        -append "console=ttyS0 root=/dev/ram rdinit=/init panic_on_warn=0 oops=panic panic=5" \
        -nographic \
        -serial file:"$serial_log" \
        -monitor none \
        -display none \
        -no-reboot \
        -enable-kvm 2>/dev/null \
    || timeout 180 qemu-system-x86_64 \
        -m 2048 \
        -smp 1 \
        -kernel "$kernel" \
        -initrd "$initramfs" \
        -append "console=ttyS0 root=/dev/ram rdinit=/init panic_on_warn=0 oops=panic panic=5" \
        -nographic \
        -serial file:"$serial_log" \
        -monitor none \
        -display none \
        -no-reboot \
    || true

    echo "    QEMU exited."
    echo ""
    echo "=== $variant: Serial log (crash-relevant lines) ==="
    if [ -f "$serial_log" ]; then
        grep -E "(BUG|KASAN|null-ptr-deref|Oops|RIP|Call Trace|cuse|fuse|general protection|panic|poc|init)" "$serial_log" | head -80 || true
        echo ""
        echo "=== $variant: Full serial log tail ==="
        tail -120 "$serial_log" || true
    else
        echo "    No serial log found!"
    fi
    echo ""
}

# Main: Run each built variant
if [ -f "$BUILDS_DIR/kasan/arch/x86/boot/bzImage" ]; then
    run_variant "kasan" "$BUILDS_DIR/kasan/arch/x86/boot/bzImage"
else
    echo "ERROR: No kasan kernel found. Run build.sh first."
    exit 1
fi

echo ""
echo "=== All variants complete. Logs are in $LOGS_DIR ==="
ls -la "$LOGS_DIR"/*/serial.log 2>/dev/null || true
