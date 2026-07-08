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

const N = 1000;

// The float workload value (3.14159) is a fixed payload byte pattern matching
// the other ports' bench tools — deliberately not a math constant, so the
// encoded bytes stay identical across languages.

/// A representative small telemetry-style message: a few scalars, a float, a
/// short string and a small array — plus a nested sequence.
fn encodeTypical(os: *sofab.OStream) void {
    os.writeUnsigned(1, 0xDEAD_BEEF) catch unreachable;
    os.writeSigned(2, -12345) catch unreachable;
    os.writeBoolean(3, true) catch unreachable;
    os.writeFp32(4, 3.14159) catch unreachable;
    os.writeString(5, "sofab") catch unreachable;
    os.writeArrayUnsigned(6, &[_]u16{ 10, 20, 30, 40 }) catch unreachable;
    os.writeSequenceBegin(7) catch unreachable;
    os.writeUnsigned(1, 99) catch unreachable;
    os.writeSigned(2, -7) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
}

/// Run `ctx.run()` repeatedly until ~1 s of CPU time has elapsed (after one
/// warm-up call) and return throughput in MB/s for a message of `bytes` bytes.
fn measure(bytes: usize, ctx: anytype) f64 {
    ctx.run(); // warmup
    const t0 = util.cpuNow();
    var it: u64 = 0;
    var el: f64 = undefined;
    while (true) {
        ctx.run();
        it += 1;
        el = util.cpuNow() - t0;
        if (el >= 1.0) break;
    }
    // MB/s, MB = 1e6 bytes
    return @as(f64, @floatFromInt(bytes)) * @as(f64, @floatFromInt(it)) / el / 1e6;
}

var src: [N]u64 = undefined;
var u64_buf: [N * 11 + 16]u8 = undefined;
var typ_buf: [256]u8 = undefined;
var enc_u64_out: [N * 11 + 16]u8 = undefined;
var enc_typ_out: [256]u8 = undefined;

const EncodeU64 = struct {
    fn run(_: @This()) void {
        var os = sofab.OStream.init(&enc_u64_out);
        os.writeArrayUnsigned(1, @as([]const u64, &src)) catch unreachable;
        std.mem.doNotOptimizeAway(os.bytesUsed());
    }
};

const EncodeTypical = struct {
    fn run(_: @This()) void {
        var os = sofab.OStream.init(&enc_typ_out);
        encodeTypical(&os);
        std.mem.doNotOptimizeAway(os.bytesUsed());
    }
};

fn Decode(comptime message: *const []const u8) type {
    return struct {
        fn run(_: @This()) void {
            var sink: util.Checksum = .{};
            var is = sofab.IStream.init();
            is.feed(message.*, &sink) catch unreachable;
            std.mem.doNotOptimizeAway(sink.acc);
        }
    };
}

var u64_msg: []const u8 = undefined;
var typ_msg: []const u8 = undefined;

pub fn main(init: std.process.Init) !void {
    util.makeSrc(N, &src);

    // Pre-encode the messages (to learn their byte sizes and as decode input).
    var os_u64 = sofab.OStream.init(&u64_buf);
    try os_u64.writeArrayUnsigned(1, @as([]const u64, &src));
    u64_msg = u64_buf[0..os_u64.bytesUsed()];

    var os_typ = sofab.OStream.init(&typ_buf);
    encodeTypical(&os_typ);
    typ_msg = typ_buf[0..os_typ.bytesUsed()];

    const enc_u64 = measure(u64_msg.len, EncodeU64{});
    const enc_typ = measure(typ_msg.len, EncodeTypical{});
    const dec_u64 = measure(u64_msg.len, Decode(&u64_msg){});
    const dec_typ = measure(typ_msg.len, Decode(&typ_msg){});

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
