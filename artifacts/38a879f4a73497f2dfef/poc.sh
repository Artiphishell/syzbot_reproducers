#!/bin/bash
set -e

# poc.sh - Run the maple tree data race PoC against each kernel configuration
# Boots QEMU VMs with each kernel, runs the PoC, and captures output

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDS_DIR="$SCRIPT_DIR/builds"
LOGS_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOGS_DIR"

run_config() {
    local config="$1"
    local bzimage="$BUILDS_DIR/$config/arch/x86/boot/bzImage"
    local initramfs="$BUILDS_DIR/$config/initramfs.cpio.gz"
    local logfile="$LOGS_DIR/$config/output.log"
    
    mkdir -p "$LOGS_DIR/$config"
    
    echo "============================================"
    echo "[*] Running PoC with config: $config"
    echo "============================================"
    
    if [ ! -f "$bzimage" ]; then
        echo "[!] bzImage not found for $config: $bzimage" | tee "$logfile"
        return 1
    fi
    if [ ! -f "$initramfs" ]; then
        echo "[!] initramfs not found for $config: $initramfs" | tee "$logfile"
        return 1
    fi
    
    # Write header
    cat > "$logfile" <<EOF
[*] Configuration: $config
[*] bzImage: $bzimage
[*] initramfs: $initramfs
[*] Start time: $(date)

EOF
    
    # Run QEMU directly, redirecting all output to log file
    # PoC runs for 15 seconds, plus boot ~8s, total ~25s
    # Use -serial file: to write serial output directly to a file
    local serial_log="$LOGS_DIR/$config/serial.log"
    
    timeout 45 qemu-system-x86_64 \
        -kernel "$bzimage" \
        -initrd "$initramfs" \
        -append "console=ttyS0 earlyprintk=serial kcsan.early_enable=1 nokaslr panic=-1 printk.devkmsg=on loglevel=7" \
        -m 2048 \
        -smp 4 \
        -cpu host,migratable=no \
        -enable-kvm \
        -nographic \
        -no-reboot \
        -serial file:"$serial_log" \
        -monitor none \
        -display none \
        > /dev/null 2>&1 || true
    
    # Append serial output to main log
    if [ -f "$serial_log" ]; then
        cat "$serial_log" >> "$logfile"
    fi
    
    echo "" >> "$logfile"
    echo "============================================" >> "$logfile"
    echo "[*] Analysis for $config:" >> "$logfile"
    echo "[*] End time: $(date)" >> "$logfile"
    
    # Summarize findings
    if grep -q "BUG: KCSAN" "$logfile" 2>/dev/null; then
        echo "[FOUND] KCSAN data-race report detected in $config!" | tee -a "$logfile"
        echo "--- KCSAN Report ---"
        grep -A 35 "BUG: KCSAN" "$logfile" | head -80
        echo "--- End KCSAN Report ---"
    fi
    
    if grep -q "BUG: KASAN" "$logfile" 2>/dev/null; then
        echo "[FOUND] KASAN report detected in $config!" | tee -a "$logfile"
        echo "--- KASAN Report ---"
        grep -A 35 "BUG: KASAN" "$logfile" | head -60
        echo "--- End KASAN Report ---"
    fi
    
    if grep -q -E "WARNING:|Oops:" "$logfile" 2>/dev/null; then
        echo "[FOUND] Kernel warning/oops in $config" | tee -a "$logfile"
    fi
    
    if ! grep -q -E "BUG:|WARNING:|Oops:" "$logfile" 2>/dev/null; then
        echo "[*] No bug reports found in $config" | tee -a "$logfile"
    fi
    
    echo ""
}

# Run available configs
for config in kcsan kcsan_strict standard; do
    if [ -d "$BUILDS_DIR/$config" ]; then
        run_config "$config" || true
    else
        echo "[!] Config $config not built, skipping"
    fi
done

echo ""
echo "============================================"
echo "[*] Summary of results"
echo "============================================"
for config in kcsan kcsan_strict standard; do
    logfile="$LOGS_DIR/$config/output.log"
    if [ -f "$logfile" ]; then
        kcsan_count=$(grep -c "BUG: KCSAN" "$logfile" 2>/dev/null || true)
        kasan_count=$(grep -c "BUG: KASAN" "$logfile" 2>/dev/null || true)
        race_count=$(grep -c "data-race" "$logfile" 2>/dev/null || true)
        echo "  $config: KCSAN=${kcsan_count:-0} KASAN=${kasan_count:-0} data-race=${race_count:-0}"
    else
        echo "  $config: no log found"
    fi
done
echo ""
echo "[*] Logs available in: $LOGS_DIR/"
