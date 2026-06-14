#!/usr/bin/env bash
set -euo pipefail

# Verification script for syzbot ID 9b639ce94c265f1daf1f
#
# This script MUST NOT trigger the bug. It only checks evidence left by ./poc.sh
# in QEMU serial logs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs"

fail() {
  echo "FAILED"
  exit 1
}

pass() {
  echo "REPRODUCED"
  exit 0
}

shopt -s nullglob
serial_logs=("$LOGS_DIR"/*/serial.log)
shopt -u nullglob

(( ${#serial_logs[@]} > 0 )) || fail

# Match the original reported crash signature:
# - KASAN null-ptr-deref at 0x230..0x237 (fch->pq_prealloc)
# - Oops GPF (non-canonical address 0xdffffc...)
# - crash site in fuse_dev_alloc_install/fuse_dev_install
# - call trace includes cuse_channel_open

for log in "${serial_logs[@]}"; do
  [[ -s "$log" ]] || continue

  # Normalize CRLF from serial output.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  tr -d '\r' <"$log" >"$tmp"

  # Core crash signatures
  grep -qE 'Oops: general protection fault, probably for non-canonical address 0xdffffc0000000046' "$tmp" || continue
  grep -qE 'KASAN: null-ptr-deref in range \[0x0*230-0x0*237\]' "$tmp" || continue

  # Must be the FUSE/CUSE open path
  grep -qE '\bcuse_channel_open\b' "$tmp" || continue
  grep -qE '\bfuse_dev_(alloc_install|install)\b' "$tmp" || continue

  # Ensure we saw a trace (objective kernel evidence)
  grep -qE 'Call Trace:|<TASK>|---\[ end trace' "$tmp" || continue

  pass
done

fail

