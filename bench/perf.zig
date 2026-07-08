//! SofaBuffers Zig — combined per-operation cost benchmark.
//!
//! Mirror of `corelib-rs/benches/perf.rs` and the C/C++ tools: encodes/decodes
//! the identical message (same field ids, types and values) through the
//! streaming API and prints the identical report, so the implementations can be
//! compared directly. Two complementary metrics per workload:
//!
//!   1. CPU cycles/op  -- cost of the code itself, read off the hardware cycle
//!      counter (x86 TSC, AArch64 virtual count register). Tracks code changes
//!      rather than the host's clock speed.
//!
//!   2. Throughput MB/s -- a "speedtest" for this machine, derived from process
//!      CPU time (not wall-clock). MB = 1e6 bytes.
//!
//! Both metrics are gathered over the same adaptive ~1 s CPU-time loop, so they
//! describe the exact same work.
//!
//! Run with:  `zig build perf`

const std = @import("std");
const sofab = @import("sofab");
const util = @import("util.zig");

// ---------------------------------------------------------------------------
// message under test (identical to perf.c / perf.cpp / perf.rs)
// ---------------------------------------------------------------------------
// The float workload values (3.14159, 2.71828…, …) are fixed payload bytes
// chosen to match the other ports exactly — deliberately not math constants.
const perf_string = "perf-benchmark-message";

const perf_samples = [8]u32{ 1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000, 6_000_000, 7_000_000, 8_000_000 };
const perf_deltas = [8]i32{ -100_000, -200_000, -300_000, -400_000, -500_000, -600_000, -700_000, -800_000 };
const perf_fp64 = [4]f64{ 3.14159265, 6.28318530, 9.42477795, 12.56637060 };

fn perfEncode(buf: []u8) usize {
    var os = sofab.OStream.init(buf);
    os.writeUnsigned(1, 0xDEAD_BEEF) catch unreachable;
    os.writeSigned(2, -12345) catch unreachable;
    os.writeUnsigned(3, 0x0123_4567_89AB_CDEF) catch unreachable;
    os.writeSigned(4, -5_000_000_000_000) catch unreachable;
    os.writeBoolean(5, true) catch unreachable;
    os.writeFp32(6, 3.14159) catch unreachable;
    os.writeFp64(7, 2.718281828459045) catch unreachable;
    os.writeString(8, perf_string) catch unreachable;
    os.writeArrayUnsigned(9, &perf_samples) catch unreachable;
    os.writeArraySigned(10, &perf_deltas) catch unreachable;
    os.writeArrayFp64(11, &perf_fp64) catch unreachable;
    os.writeSequenceBegin(12) catch unreachable;
    os.writeUnsigned(1, 99) catch unreachable;
    os.writeSigned(2, -7) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
    return os.bytesUsed();
}

/// Decode sink: folds every value into a checksum (so nothing is elided) and
/// captures the top-level `u32` (id 1) and the string (id 8) for the
/// self-check. Fixed-size string buffer — no per-iteration heap allocation.
const PerfOut = struct {
    acc: u64 = 0,
    depth: i32 = 0,
    u32_top: u32 = 0,
    str_len: usize = 0,
    str_buf: [32]u8 = undefined,

    pub fn unsigned(self: *PerfOut, id: sofab.Id, v: u64) void {
        self.acc +%= v ^ id;
        if (self.depth == 0 and id == 1) self.u32_top = @truncate(v);
    }
    pub fn signed(self: *PerfOut, id: sofab.Id, v: i64) void {
        self.acc +%= @as(u64, @bitCast(v)) ^ id;
    }
    pub fn fp32(self: *PerfOut, _: sofab.Id, v: f32) void {
        self.acc +%= @as(u32, @bitCast(v));
    }
    pub fn fp64(self: *PerfOut, _: sofab.Id, v: f64) void {
        self.acc +%= @as(u64, @bitCast(v));
    }
    pub fn string(self: *PerfOut, id: sofab.Id, _: usize, offset: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
        if (id == 8 and offset < self.str_buf.len) {
            const end = @min(offset + chunk.len, self.str_buf.len);
            @memcpy(self.str_buf[offset..end], chunk[0 .. end - offset]);
            self.str_len = end;
        }
    }
    pub fn blob(self: *PerfOut, _: sofab.Id, _: usize, _: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
    }
    pub fn sequenceBegin(self: *PerfOut, _: sofab.Id) void {
        self.depth += 1;
    }
    pub fn sequenceEnd(self: *PerfOut) void {
        self.depth -= 1;
    }
};

fn perfDecode(buf: []const u8, out: *PerfOut) void {
    var is = sofab.IStream.init();
    is.feed(buf, out) catch unreachable;
}

// ---------------------------------------------------------------------------
// large-array workload (identical to bench.zig / the other ports): a
// standalone 1000-element u64 array. BENCH_SPEC.md requires both benchmark
// tools to exercise this large array *and* the typical/perf message.
// ---------------------------------------------------------------------------
const PERF_N = 1000;

var u64_src: [PERF_N]u64 = undefined;
var u64_buf: [PERF_N * 11 + 16]u8 = undefined;
var scalar_buf: [512]u8 = undefined;

// ---------------------------------------------------------------------------
// measurement
// ---------------------------------------------------------------------------
const PerfResult = struct {
    iters: u64,
    cycles_op: f64, // hardware cycles per operation
    ns_op: f64, // CPU nanoseconds per operation
    mb_s: f64, // throughput, MB/s (MB = 1e6 bytes)
};

fn perfReport(out: anytype, what: []const u8, r: PerfResult, bytes: usize) !void {
    try out.print("\n--- perf: {s} ---\n", .{what});
    try out.print("  iterations    : {d}\n", .{r.iters});
    try out.print("  message size  : {d} bytes\n", .{bytes});
    if (util.have_cycles) {
        try out.print("  cycles/op     : {d:.1}  (hardware cycle counter)\n", .{r.cycles_op});
    } else {
        try out.print("  cycles/op     : (cycle counter unavailable on this arch)\n", .{});
    }
    try out.print("  CPU time/op   : {d:.1} ns  (process CPU time, not wall-clock)\n", .{r.ns_op});
    try out.print("  throughput    : {d:.1} MB/s  (speedtest, MB = 1e6 bytes)\n", .{r.mb_s});
}

fn measureEncode(ctx: anytype) struct { PerfResult, usize } {
    var msg: usize = 0;
    for (0..1000) |_| msg = ctx.run(); // warmup

    var sink: usize = 0;
    var it: u64 = 0;
    const c0 = util.cycles();
    const t0 = util.cpuNow();
    var el: f64 = undefined;
    while (true) {
        sink +%= ctx.run();
        it += 1;
        el = util.cpuNow() - t0;
        if (el >= 1.0) break;
    }
    const c1 = util.cycles();
    std.mem.doNotOptimizeAway(sink);

    const fit: f64 = @floatFromInt(it);
    return .{ .{
        .iters = it,
        .cycles_op = @as(f64, @floatFromInt(c1 -% c0)) / fit,
        .ns_op = el / fit * 1e9,
        .mb_s = @as(f64, @floatFromInt(msg)) * fit / el / 1e6,
    }, msg };
}

fn measureDecode(buf: []const u8) PerfResult {
    for (0..1000) |_| {
        var out: PerfOut = .{};
        perfDecode(buf, &out); // warmup
        std.mem.doNotOptimizeAway(out.acc);
    }

    var sink: u64 = 0;
    var it: u64 = 0;
    const c0 = util.cycles();
    const t0 = util.cpuNow();
    var el: f64 = undefined;
    while (true) {
        var o: PerfOut = .{};
        perfDecode(buf, &o);
        sink +%= o.acc;
        it += 1;
        el = util.cpuNow() - t0;
        if (el >= 1.0) break;
    }
    const c1 = util.cycles();
    std.mem.doNotOptimizeAway(sink);

    const fit: f64 = @floatFromInt(it);
    return .{
        .iters = it,
        .cycles_op = @as(f64, @floatFromInt(c1 -% c0)) / fit,
        .ns_op = el / fit * 1e9,
        .mb_s = @as(f64, @floatFromInt(buf.len)) * fit / el / 1e6,
    };
}

const EncodeScalar = struct {
    fn run(_: @This()) usize {
        return perfEncode(&scalar_buf);
    }
};

const EncodeU64 = struct {
    fn run(_: @This()) usize {
        var os = sofab.OStream.init(&u64_buf);
        os.writeArrayUnsigned(1, @as([]const u64, &u64_src)) catch unreachable;
        return os.bytesUsed();
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("=== SofaBuffers Zig per-op cost (cycles/op + throughput MB/s) ===\n", .{});

    const enc = measureEncode(EncodeScalar{});
    try perfReport(out, "serialize (stream API)", enc[0], enc[1]);
    try out.flush();

    // Sanity check that the decode actually reproduces the data.
    var check: PerfOut = .{};
    perfDecode(scalar_buf[0..enc[1]], &check);
    if (check.u32_top != 0xDEAD_BEEF or !std.mem.eql(u8, check.str_buf[0..check.str_len], perf_string)) {
        std.debug.print("perf: decode self-check failed\n", .{});
        std.process.exit(1);
    }

    const dec = measureDecode(scalar_buf[0..enc[1]]);
    try perfReport(out, "deserialize (stream API)", dec, enc[1]);
    try out.flush();

    // Second reference workload: a standalone 1000-element u64 array, measured
    // with the exact same perf machinery as above.
    util.makeSrc(PERF_N, &u64_src);

    const enc_u64 = measureEncode(EncodeU64{});
    try perfReport(out, "encode u64[1000] (stream API)", enc_u64[0], enc_u64[1]);
    try out.flush();

    const dec_u64 = measureDecode(u64_buf[0..enc_u64[1]]);
    try perfReport(out, "decode u64[1000] (stream API)", dec_u64, enc_u64[1]);

    try out.print("\ncycles/op tracks code cost; MB/s is this machine's throughput.\n", .{});
    try out.flush();
}
