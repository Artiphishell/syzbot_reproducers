#!/bin/bash
# poc.sh - Boot QEMU with KASAN kernel and run bpf_trace_run4 UAF PoC
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs"
BUILDS_DIR="$SCRIPT_DIR/builds"
INITRAMFS_BASE="/workspaces/mono-repo/libs/artiphishell_agents/tests/hackerone/linux_kernel/initramfs/initramfs.cpio.gz"

NUM_ATTEMPTS=5
VM_TIMEOUT=600

echo "[poc.sh] Starting reproduction of KASAN: slab-use-after-free in bpf_trace_run4"

if [ ! -f "$BUILDS_DIR/kasan/arch/x86/boot/bzImage" ]; then
    echo "[poc.sh] ERROR: KASAN kernel not found. Run build.sh first."
    exit 1
fi
if [ ! -f "$BUILDS_DIR/poc" ]; then
    echo "[poc.sh] ERROR: PoC binary not found. Run build.sh first."
    exit 1
fi

ACCEL="tcg,thread=multi"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    echo "[poc.sh] KVM acceleration available"
else
    echo "[poc.sh] WARNING: No KVM access, using multi-threaded TCG"
fi

create_initramfs() {
    local poc_binary="$1"
    local output="$2"
    local poc_duration="$3"

    local workdir
    workdir=$(mktemp -d /tmp/initramfs_work.XXXXXX)

    (cd "$workdir" && zcat "$INITRAMFS_BASE" | cpio -id 2>/dev/null) || true

    cp "$poc_binary" "$workdir/poc"
    chmod +x "$workdir/poc"

    cat > "$workdir/init" << INITEOF
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc     proc  /proc
mount -t sysfs    sysfs /sys
mount -t devtmpfs dev   /dev 2>/dev/null || mdev -s
mount -t tmpfs    tmpfs /tmp
mount -t tmpfs    tmpfs /run
echo 7 > /proc/sys/kernel/printk 2>/dev/null || true
hostname kernel-vm
ifconfig lo 127.0.0.1 up
echo ""
echo "=============================================="
echo "  BOOT COMPLETE: kernel-vm is ready"
echo "=============================================="
echo ""
if [ -x /poc ]; then
    echo 0 > /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null || true
    cp /poc /run/poc
    chmod +x /run/poc
    setcap cap_bpf,cap_perfmon,cap_sys_admin+eip /run/poc 2>/dev/null || \
        setcap cap_bpf,cap_sys_admin+eip /run/poc 2>/dev/null || \
        setcap cap_sys_admin+eip /run/poc 2>/dev/null || true
    echo "[init] Running PoC as vscode (uid=1000)..."
    su vscode -s /bin/sh -c "POC_DURATION=${poc_duration} /run/poc" 2>&1
    echo "[init] /poc exited with status \$?"
    echo ""
    echo "========== DMESG OUTPUT =========="
    dmesg 2>&1 | tail -400
    echo "========== END DMESG =========="
    sleep 2
    poweroff -f
fi
exec /bin/sh
INITEOF
    chmod +x "$workdir/init"

    (cd "$workdir" && find . | sort | cpio -o -H newc 2>/dev/null | gzip -1 > "$output")
    rm -rf "$workdir"
}

VARIANT_LOG_DIR="$LOGS_DIR/kasan"
mkdir -p "$VARIANT_LOG_DIR"

KERNEL="$BUILDS_DIR/kasan/arch/x86/boot/bzImage"

echo ""
echo "================================================================"
echo "[poc.sh] Running KASAN variant"
echo "================================================================"

FOUND=0
for attempt in $(seq 1 $NUM_ATTEMPTS); do
    echo ""
    echo "[poc.sh] Attempt $attempt/$NUM_ATTEMPTS"

    SERIAL_LOG="$VARIANT_LOG_DIR/serial_attempt_${attempt}.log"
    INITRAMFS_CUSTOM="$VARIANT_LOG_DIR/initramfs_${attempt}.cpio.gz"

    POC_DURATION=$((180 + attempt * 60))

    create_initramfs "$BUILDS_DIR/poc" "$INITRAMFS_CUSTOM" "$POC_DURATION"

    echo "[poc.sh] Booting QEMU (poc_duration=${POC_DURATION}s, vm_timeout=${VM_TIMEOUT}s)..."
    timeout "$VM_TIMEOUT" \
        qemu-system-x86_64 \
            -accel "$ACCEL" \
            -m 4096 \
            -smp 2 \
            -kernel "$KERNEL" \
            -initrd "$INITRAMFS_CUSTOM" \
            -append "console=ttyS0 root=/dev/ram rdinit=/init kasan.fault=report kasan_multi_shot panic_on_warn=0 preempt=full" \
            -nographic \
            -no-reboot \
            -serial file:"$SERIAL_LOG" \
            -monitor none \
            -display none \
            2>&1 || true

    echo "[poc.sh] QEMU exited for attempt $attempt"

    if [ -f "$SERIAL_LOG" ]; then
        KASAN_COUNT=$(grep -c "BUG: KASAN" "$SERIAL_LOG" 2>/dev/null || echo "0")
        echo "[poc.sh] Serial log: $(wc -l < "$SERIAL_LOG") lines, KASAN reports: $KASAN_COUNT"

        if [ "$KASAN_COUNT" -gt 0 ]; then
            echo ""
            echo "[poc.sh] *** KASAN BUG DETECTED in attempt $attempt! ***"
            echo ""
            grep -B2 -A60 "BUG: KASAN: slab-use-after-free in bpf_trace_run4" "$SERIAL_LOG" 2>/dev/null | head -80 || \
                grep -B2 -A60 "BUG: KASAN" "$SERIAL_LOG" | head -80

            if grep -q "bpf_trace_run4" "$SERIAL_LOG" 2>/dev/null; then
                echo ""
                echo "[poc.sh] *** CONFIRMED: slab-use-after-free in bpf_trace_run4 ***"
                FOUND=1
            fi
        else
            echo "[poc.sh] No KASAN report in this attempt"
        fi
    fi

    rm -f "$INITRAMFS_CUSTOM"

    if [ "$FOUND" -eq 1 ]; then
        echo "[poc.sh] Bug reproduced! Stopping."
        break
    fi
done

echo ""
echo "[poc.sh] Summary:"
for log in "$VARIANT_LOG_DIR"/serial_attempt_*.log; do
    [ -f "$log" ] || continue
    if grep -q "BUG: KASAN.*slab-use-after-free.*bpf_trace_run" "$log" 2>/dev/null; then
        echo "  $(basename "$log"): *** KASAN slab-use-after-free in bpf_trace_run FOUND ***"
    elif grep -q "BUG: KASAN" "$log" 2>/dev/null; then
        echo "  $(basename "$log"): KASAN bug found (check details)"
    else
        echo "  $(basename "$log"): No KASAN report"
    fi
done

echo ""
echo "[poc.sh] All attempts complete. Logs in: $VARIANT_LOG_DIR"
