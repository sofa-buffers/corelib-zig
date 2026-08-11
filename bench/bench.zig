//! SofaBuffers Zig — throughput benchmark (MB/s, CPU time).
//!
//! Mirror of `corelib-rs/benches/bench.rs` and the C/C++ tools: encode/decode
//! throughput for every workload in `workloads.zig` — the 1000-element `u64`
//! array, the small `typical` message, the unbounded 1 MB `blob` and the
//! `composite` message. Each row runs in a ~1 s CPU-time loop and reports MB/s,
//! and the table matches the other ports' exactly, so the implementations can
//! be compared directly (BENCH_SPEC.md).
//!
//! **Read the `blob 1MB` rows against each other, not against the others.**
//! Five bytes of that message are metadata and a million are payload, so its
//! MB/s figure is this machine's memory bandwidth rather than a statement about
//! the codec. The signal is the *difference* between the one-shot and streaming
//! rows — the cost of the divisible-run path (CORELIB_PLAN §5.1) — and under
//! MB/s that difference is a low-single-digit fraction of a bandwidth-bound
//! row. `bench/run_callgrind.sh` is where that comparison actually reads.
//!
//! Run with:  `zig build bench`

const std = @import("std");
const w = @import("workloads");
const util = @import("util.zig");

/// Adapts a comptime-known workload function to the `ctx.run()` shape the
/// timing helpers take. The function stays comptime, so the measured loop calls
/// it directly and can inline it — a runtime function pointer would put an
/// indirect call into every operation and charge the short workloads several
/// percent for the table's plumbing.
fn Runner(comptime f: w.Op) type {
    return struct {
        pub inline fn run(_: @This()) usize {
            return f();
        }
    };
}

/// Run `wl` repeatedly until ~1 s of CPU time has elapsed (after its setup and
/// one warm-up call) and return throughput in MB/s for its encoded size.
///
/// The clock is read once per batch, never per operation — see
/// `util.batch_seconds`.
fn measure(comptime wl: w.Workload) f64 {
    const ctx = Runner(wl.run){};
    if (wl.setup) |setup| std.mem.doNotOptimizeAway(setup());
    std.mem.doNotOptimizeAway(ctx.run()); // warmup — also fixes `wl.bytes`
    const bytes = wl.bytes.*;
    const batch = util.calibrateBatch(ctx);
    const t0 = util.cpuNow();
    var it: u64 = 0;
    var el: f64 = undefined;
    while (true) {
        var k: u64 = 0;
        while (k < batch) : (k += 1) std.mem.doNotOptimizeAway(ctx.run());
        it += batch;
        el = util.cpuNow() - t0;
        if (el >= 1.0) break;
    }
    // MB/s, MB = 1e6 bytes
    return @as(f64, @floatFromInt(bytes)) * @as(f64, @floatFromInt(it)) / el / 1e6;
}

pub fn main(init: std.process.Init) !void {
    w.prepare();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("=== SofaBuffers Zig throughput (CPU time, MB/s) ===\n", .{});
    try out.print("{s:<26} {s:>12}\n", .{ "Workload", "MB/s" });
    try out.print("{s:<26} {s:>12}\n", .{ "--------", "----" });
    // The table walks the shared workload list, so a row cannot exist here and
    // be missing from the Callgrind tool (or vice versa), and the rows come out
    // in the order BENCH_SPEC's grammar prints them.
    inline for (w.workloads) |wl| {
        const mb_s = measure(wl);
        try out.print("{s:<26} {d:>12.2}\n", .{ wl.label, mb_s });
        try out.flush(); // a ~1 s row at a time, rather than a silent minute
    }
    try out.print("\nMB = 1e6 bytes. ~1s CPU-time loop per workload.\n", .{});
    try out.flush();
}
