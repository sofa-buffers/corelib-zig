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
WORKLOADS=(encode_u64_array encode_typical decode_u64_array decode_typical)

run_cg() { # $1 workload
    valgrind --tool=callgrind --collect-atstart=no --toggle-collect="run_$1" \
        --callgrind-out-file="$OUT/$1.out" "$BIN" "$1" \
        >/dev/null 2>"$OUT/$1.log"
}

ir_of()    { grep -m1 '^summary:' "$OUT/$1.out" 2>/dev/null | awk '{print $2}'; }
bytes_of() { grep -ohE 'BYTES=[0-9]+' "$OUT/$1.log" 2>/dev/null | head -1 | cut -d= -f2; }

label() {
    case "$1" in
        encode_u64_array) echo "encode: u64 array (1000)";;
        encode_typical)   echo "encode: typical message";;
        decode_u64_array) echo "decode: u64 array (1000)";;
        decode_typical)   echo "decode: typical message";;
    esac
}

echo ">> Measuring instructions/op under Callgrind (this is slow) ..." >&2
echo
echo "==============================================================================="
echo " SofaBuffers Zig instruction cost   (Callgrind, Ir/op)"
echo " instructions/op: lower is better. Deterministic & machine-independent."
echo "==============================================================================="
printf "%-26s %16s %9s\n" "Workload" "instr/op" "bytes"
printf "%-26s %16s %9s\n" "--------" "--------" "-----"

for w in "${WORKLOADS[@]}"; do
    run_cg "$w"
    ir="$(ir_of "$w")"; b="$(bytes_of "$w")"
    printf "%-26s %16s %9s\n" "$(label "$w")" "${ir:--}" "${b:--}"
done
echo
echo "Ir = instructions retired (Callgrind). Independent of CPU clock and OS"
echo "scheduling; depends only on the executed code, so it compares across machines."
