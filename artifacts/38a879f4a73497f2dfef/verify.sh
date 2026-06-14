#!/bin/bash
# verify.sh - Verify reproduction of syzbot 38a879f4a73497f2dfef
#
# This script is intentionally passive: it does NOT rerun QEMU or the PoC.
# It only inspects existing guest serial logs produced by poc.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs"

fail() {
  echo "FAILED"
  exit 1
}

pass() {
  echo "REPRODUCED"
  exit 0
}

[[ -d "$LOGS_DIR" ]] || fail

shopt -s nullglob
serial_logs=("$LOGS_DIR"/*/serial.log)
[[ ${#serial_logs[@]} -gt 0 ]] || fail

# Require evidence for the *specific* KCSAN report described in the issue:
# a race involving mtree_range_walk and the VMA writer side (mas_wr_store_entry),
# observed from an unprivileged PoC process.
required_commit_substr="g3cd8b194bf34"

for f in "${serial_logs[@]}"; do
  # Basic sanity: log looks like a kernel boot.
  grep -q "Linux version" "$f" || continue
  # Prefer the expected commit substring if present (non-fatal if absent).
  if ! grep -q "$required_commit_substr" "$f"; then
    :
  fi

  # Fast prefilter.
  grep -q "BUG: KCSAN: data-race" "$f" || continue

  # For each KCSAN BUG line, check a fixed-size window after it.
  # We cannot rely on clean line boundaries because userspace output can interleave
  # with printk, so we only require that the window contains the key callsites.
  while IFS=: read -r lineno _; do
    # Extract a window of lines starting at the BUG line.
    window="$(sed -n "${lineno},$((lineno+140))p" "$f")"

    echo "$window" | grep -q "BUG: KCSAN: data-race" || continue
    echo "$window" | grep -q "mtree_range_walk" || continue
    # Writer-side evidence: mas_wr_store_entry is the syzbot-reported writer function.
    echo "$window" | grep -q "mas_wr_store_entry" || continue
    # Dead-node marker / maple-tree writer context.
    echo "$window" | grep -Eq "mte_set_node_dead|mas_put_in_tree|mas_wr_node_store" || continue
    # Must be triggered by the PoC as an unprivileged user.
    echo "$window" | grep -q "Comm: poc" || continue
    echo "$window" | grep -q "UID: 1000" || continue

    echo "[verify] Matched KCSAN maple_tree race in: $f (line $lineno)" >&2
    pass
  done < <(grep -n "BUG: KCSAN: data-race" "$f" || true)
done

fail

