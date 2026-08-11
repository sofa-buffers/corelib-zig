//! SofaBuffers Zig — throughput benchmark (MB/s, CPU time).
//!
//! Mirror of `corelib-rs/benches/bench.rs` and the C/C++ tools: encode/decode
//! throughput for two workloads — a 1000-element u64 array and a small
//! "typical" mixed message. Each workload runs in a ~1 s CPU-time loop and
//! reports MB/s, and the output table matches the other ports so the
//! implementations can be compared directly (BENCH_SPEC.md).
//!
//! Run with:  `zig build bench`

const std = @import("std");
const sofab = @import("sofab");
const util = @import("util.zig");

/// Run `ctx.run()` repeatedly until ~1 s of CPU time has elapsed (after one
/// warm-up call) and return throughput in MB/s for a message of `bytes` bytes.
///
/// The clock is read once per batch, never per operation — see
/// `util.batch_seconds`.
fn measure(bytes: usize, ctx: anytype) f64 {
    std.mem.doNotOptimizeAway(ctx.run()); // warmup
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

const EncodeU64 = struct {
    pub fn run(_: @This()) usize {
        var os = sofab.OStream.init(&util.enc_u64_out);
        os.writeArrayUnsigned(1, @as([]const u64, &util.src)) catch unreachable;
        return os.bytesUsed();
    }
};

const EncodeTypical = struct {
    pub fn run(_: @This()) usize {
        var os = sofab.OStream.init(&util.enc_typ_out);
        util.encodeTypical(&os);
        return os.bytesUsed();
    }
};

fn Decode(comptime message: *const []const u8) type {
    return struct {
        pub fn run(_: @This()) u64 {
            var sink: util.Checksum = .{};
            var is = sofab.IStream.init();
            _ = is.feed(message.*, &sink) catch unreachable;
            return sink.acc;
        }
    };
}

pub fn main(init: std.process.Init) !void {
    try util.prepare();

    const enc_u64 = measure(util.u64_msg.len, EncodeU64{});
    const enc_typ = measure(util.typ_msg.len, EncodeTypical{});
    const dec_u64 = measure(util.u64_msg.len, Decode(&util.u64_msg){});
    const dec_typ = measure(util.typ_msg.len, Decode(&util.typ_msg){});

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("=== SofaBuffers Zig throughput (CPU time, MB/s) ===\n", .{});
    try out.print("{s:<26} {s:>12}\n", .{ "Workload", "MB/s" });
    try out.print("{s:<26} {s:>12}\n", .{ "--------", "----" });
    try out.print("{s:<26} {d:>12.2}\n", .{ "encode: u64 array (1000)", enc_u64 });
    try out.print("{s:<26} {d:>12.2}\n", .{ "encode: typical message", enc_typ });
    try out.print("{s:<26} {d:>12.2}\n", .{ "decode: u64 array (1000)", dec_u64 });
    try out.print("{s:<26} {d:>12.2}\n", .{ "decode: typical message", dec_typ });
    try out.print("\nMB = 1e6 bytes. ~1s CPU-time loop per workload.\n", .{});
    try out.flush();
}
