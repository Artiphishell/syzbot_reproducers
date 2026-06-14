#!/bin/bash
# verify.sh - verify reproduction from QEMU guest serial logs.
#
# Succeeds iff we can find objective KASAN evidence of the target UAF:
#   - "BUG: KASAN: slab-use-after-free" in bpf_trace_run4
#   - stack shows mm_page_alloc tracepoint path
#   - allocation originates from bpf_raw_tp_link_attach
#   - free originates from bpf_link deferred dealloc via (classic) RCU

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="$SCRIPT_DIR/logs"

shopt -s nullglob

logs=(
  "$LOG_ROOT"/*/serial_attempt_*.log
  "$LOG_ROOT"/serial_attempt_*.log
)

if (( ${#logs[@]} == 0 )); then
  echo "FAILED"
  exit 1
fi

reproduced=0

for log in "${logs[@]}"; do
  # 1) Must be a KASAN slab-UAF in bpf_trace_run4.
  if ! grep -Eq "BUG: KASAN: slab-use-after-free.*bpf_trace_run4" "$log"; then
    continue
  fi

  # 2) Must be reached via mm_page_alloc tracepoint.
  if ! grep -Eq "__traceiter_mm_page_alloc|trace_mm_page_alloc" "$log"; then
    continue
  fi

  # 3) Lifetime signature must match: allocated in bpf_raw_tp_link_attach.
  if ! grep -Eq "Allocated by task" "$log"; then
    continue
  fi
  if ! grep -Eq "\bbpf_raw_tp_link_attach\b" "$log"; then
    continue
  fi

  # 4) Freed via classic RCU callback path used by bpf_link (matches RCA & report).
  if ! grep -Eq "Freed by task" "$log"; then
    continue
  fi
  if ! grep -Eq "\bbpf_link_defer_dealloc_rcu_gp\b|\brcu_core\b|\brcu_do_batch\b" "$log"; then
    continue
  fi

  reproduced=1
  break
done

if (( reproduced == 1 )); then
  echo "REPRODUCED"
  exit 0
fi

echo "FAILED"
exit 1

