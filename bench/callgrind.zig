//! SofaBuffers Zig — machine-independent instruction cost (Callgrind Ir/op).
//!
//! Companion to `bench.zig` (throughput) and `perf.zig` (cycles/op): each
//! workload of `workloads.zig` is exposed as an `export fn run_<workload>` that
//! performs *exactly one* op. `bench/run_callgrind.sh` runs this tool once per
//! workload under
//!   valgrind --tool=callgrind --collect-atstart=no --toggle-collect=run_<w>
//! so the collected instructions retired (Ir) is one op's count directly — a
//! deterministic, machine-independent per-op cost. Native symbols, so no
//! rep-count subtraction is needed (unlike the JIT/interpreted ports).
//!
//! This is the tool that makes the `blob 1MB` rows readable: the one-shot to
//! streaming delta is the cost of the divisible-run path (CORELIB_PLAN §5.1)
//! with the host's memory bandwidth and scheduler taken out of it, which under
//! MB/s drowns in the noise of a bandwidth-bound row.
//!
//! `main` does the setup (building the datasets, encoding the decode inputs)
//! *outside* the collected region and calls the chosen `run_*` through a
//! function pointer, so the call really enters the exported symbol Callgrind
//! toggles on. It prints `BYTES=<n>` on stderr to feed the table's size column.
//!
//! Run with:  zig build callgrind   (then bench/run_callgrind.sh drives it)

const std = @import("std");
const w = @import("workloads");

// ---- Callgrind workload entry points (one op each) ------------------------
// `export` gives each a stable C symbol so `--toggle-collect=run_<w>` matches.
// The workloads themselves — data, messages and buffers — are `workloads.zig`'s,
// shared with `bench.zig` and `perf.zig` so the tools cannot drift apart.

export fn run_encode_u64_array() void {
    std.mem.doNotOptimizeAway(w.encodeU64Array());
}

export fn run_encode_typical() void {
    std.mem.doNotOptimizeAway(w.encodeTypical());
}

export fn run_encode_blob_oneshot() void {
    std.mem.doNotOptimizeAway(w.encodeBlobOneshot());
}

export fn run_encode_blob_streaming() void {
    std.mem.doNotOptimizeAway(w.encodeBlobStreaming());
}

export fn run_encode_composite() void {
    std.mem.doNotOptimizeAway(w.encodeComposite());
}

export fn run_decode_u64_array() void {
    std.mem.doNotOptimizeAway(w.decodeU64Array());
}

export fn run_decode_typical() void {
    std.mem.doNotOptimizeAway(w.decodeTypical());
}

export fn run_decode_blob() void {
    std.mem.doNotOptimizeAway(w.decodeBlob());
}

export fn run_decode_composite() void {
    std.mem.doNotOptimizeAway(w.decodeComposite());
}

export fn run_decode_composite_skip() void {
    std.mem.doNotOptimizeAway(w.decodeCompositeSkip());
}

/// The exported entry points, in the workload table's order. Kept beside the
/// table rather than derived from it because the *symbol name* is what
/// Callgrind toggles on, and a symbol cannot be spelled from a comptime string
/// without losing the `export fn` shape that guarantees it. The comptime check
/// below is what keeps the two from drifting.
const entries = [_]*const fn () callconv(.c) void{
    &run_encode_u64_array,
    &run_encode_typical,
    &run_encode_blob_oneshot,
    &run_encode_blob_streaming,
    &run_encode_composite,
    &run_decode_u64_array,
    &run_decode_typical,
    &run_decode_blob,
    &run_decode_composite,
    &run_decode_composite_skip,
};

comptime {
    if (entries.len != w.workloads.len)
        @compileError("bench/callgrind.zig has no `run_` entry point for every workload");
}

pub fn main(init: std.process.Init) !void {
    // Datasets and decode inputs — outside the measured op.
    w.prepare();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv[0]
    const arg = args.next() orelse {
        std.process.exit(2); // no workload named
    };

    var buf: [4096]u8 = undefined;

    // `--list` is what `bench/run_callgrind.sh` takes its workload names and
    // row labels from, so the script keeps no copy of either.
    if (std.mem.eql(u8, arg, "--list")) {
        var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
        const out = &stdout_writer.interface;
        for (w.workloads) |wl| try out.print("{s}\t{s}\n", .{ wl.name, wl.label });
        try out.flush();
        return;
    }

    const idx = for (w.workloads, 0..) |wl, i| {
        if (std.mem.eql(u8, wl.name, arg)) break i;
    } else std.process.exit(2); // unknown workload

    const wl = w.workloads[idx];
    if (wl.setup) |setup| std.mem.doNotOptimizeAway(setup());
    // Through the function pointer: an inlined copy of the body would leave the
    // exported symbol Callgrind is toggling on unentered, and every count zero.
    entries[idx]();

    var stderr_writer = std.Io.File.stderr().writer(init.io, &buf);
    const err = &stderr_writer.interface;
    try err.print("BYTES={d} CHECK={d}\n", .{ wl.bytes.*, w.checksum });
    try err.flush();
}
