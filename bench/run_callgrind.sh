#!/usr/bin/env bash
#
# SofaBuffers Zig — machine-independent instruction cost.
#
# Runs each benchmark workload once under Callgrind and reports instructions
# retired per operation (Ir/op). Unlike wall-clock or CPU time, instruction
# counts are deterministic and independent of the host's clock speed and
# scheduler, so the numbers compare across machines (and against the C/C++/
# Rust/Go/Python/TypeScript tools — the workloads, ids and values are identical).
#
# The `callgrind` tool (bench/callgrind.zig) exposes each workload as an
# `export fn run_<workload>` performing exactly one op; `--collect-atstart=no
# --toggle-collect=run_<workload>` therefore measures a single op's Ir directly
# — no rep-count subtraction (native symbols, unlike the JIT/interpreted ports).
#
# The workload names and row labels come from the tool's own `--list`, so this
# script keeps no copy of the table: a workload added in bench/workloads.zig
# shows up here without touching this file.
#
# This is where the `blob 1MB` rows earn their keep: the one-shot-to-streaming
# delta is the cost of the divisible-run path (CORELIB_PLAN §5.1) with the
# machine's memory bandwidth taken out of it, which under MB/s drowns in the
# noise of a bandwidth-bound row.
#
# Prereqs: valgrind, zig. This builds the tool if missing.
# Usage:   bash bench/run_callgrind.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v valgrind >/dev/null 2>&1; then
    echo "error: valgrind not found (needed for instruction counts)." >&2
    echo "       install it, e.g.  apt-get install valgrind" >&2
    exit 1
fi

echo ">> building callgrind tool (ReleaseFast) ..." >&2
zig build callgrind
BIN="$ROOT/zig-out/bin/callgrind"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built." >&2
    exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

run_cg() { # $1 workload
    valgrind --tool=callgrind --collect-atstart=no --toggle-collect="run_$1" \
        --callgrind-out-file="$OUT/$1.out" "$BIN" "$1" \
        >/dev/null 2>"$OUT/$1.log"
}

ir_of()    { grep -m1 '^summary:' "$OUT/$1.out" 2>/dev/null | awk '{print $2}'; }
bytes_of() { grep -ohE 'BYTES=[0-9]+' "$OUT/$1.log" 2>/dev/null | head -1 | cut -d= -f2; }

echo ">> Measuring instructions/op under Callgrind (this is slow) ..." >&2
echo
echo "==============================================================================="
echo " SofaBuffers Zig instruction cost   (Callgrind, Ir/op)"
echo " instructions/op: lower is better. Deterministic & machine-independent."
echo "==============================================================================="
printf "%-26s %16s %9s\n" "Workload" "instr/op" "bytes"
printf "%-26s %16s %9s\n" "--------" "--------" "-----"

while IFS=$'\t' read -r name label; do
    [ -n "$name" ] || continue
    run_cg "$name"
    ir="$(ir_of "$name")"; b="$(bytes_of "$name")"
    printf "%-26s %16s %9s\n" "$label" "${ir:--}" "${b:--}"
done < <("$BIN" --list)

echo
echo "Ir = instructions retired (Callgrind). Independent of CPU clock and OS"
echo "scheduling; depends only on the executed code, so it compares across machines."
echo "The blob 1MB rows are read against each other: one-shot to streaming is the"
echo "cost of the divisible-run path (CORELIB_PLAN §5.1) on this port."
