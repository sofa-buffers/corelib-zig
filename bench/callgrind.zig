//! SofaBuffers Zig — machine-independent instruction cost (Callgrind Ir/op).
//!
//! Companion to `bench.zig` (throughput) and `perf.zig` (cycles/op): each
//! workload is an `export fn run_<workload>` that performs *exactly one* op.
//! `bench/run_callgrind.sh` runs this tool once per workload under
//!   valgrind --tool=callgrind --collect-atstart=no --toggle-collect=run_<w>
//! so the collected instructions retired (Ir) is one op's count directly — a
//! deterministic, machine-independent per-op cost. Native symbols, so no
//! rep-count subtraction is needed (unlike the JIT/interpreted ports).
//!
//! `main` does the setup (encode the decode inputs) *outside* the collected
//! region and calls the chosen `run_*` via `@call(.never_inline, …)` so the
//! call really enters the exported symbol Callgrind toggles on. It prints
//! `BYTES=<n>` on stderr to feed the table's size column.
//!
//! Run with:  zig build callgrind   (then bench/run_callgrind.sh drives it)

const std = @import("std");
const sofab = @import("sofab");
const util = @import("util.zig");

const N = 1000;

/// Identical to bench.zig's `encodeTypical` — a small mixed message.
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

var src: [N]u64 = undefined;
var u64_buf: [N * 11 + 16]u8 = undefined;
var typ_buf: [256]u8 = undefined;
var enc_u64_out: [N * 11 + 16]u8 = undefined;
var enc_typ_out: [256]u8 = undefined;
var u64_msg: []const u8 = undefined;
var typ_msg: []const u8 = undefined;

// ---- Callgrind workload entry points (one op each) ------------------------
// `export` gives each a stable C symbol so `--toggle-collect=run_<w>` matches.

export fn run_encode_u64_array() void {
    var os = sofab.OStream.init(&enc_u64_out);
    os.writeArrayUnsigned(1, @as([]const u64, &src)) catch unreachable;
    std.mem.doNotOptimizeAway(os.bytesUsed());
}

export fn run_encode_typical() void {
    var os = sofab.OStream.init(&enc_typ_out);
    encodeTypical(&os);
    std.mem.doNotOptimizeAway(os.bytesUsed());
}

export fn run_decode_u64_array() void {
    var sink: util.Checksum = .{};
    var is = sofab.IStream.init();
    is.feed(u64_msg, &sink) catch unreachable;
    std.mem.doNotOptimizeAway(sink.acc);
}

export fn run_decode_typical() void {
    var sink: util.Checksum = .{};
    var is = sofab.IStream.init();
    is.feed(typ_msg, &sink) catch unreachable;
    std.mem.doNotOptimizeAway(sink.acc);
}

pub fn main(init: std.process.Init) !void {
    util.makeSrc(N, &src);

    // Pre-encode the messages (decode input + byte sizes) — outside the op.
    var os_u64 = sofab.OStream.init(&u64_buf);
    try os_u64.writeArrayUnsigned(1, @as([]const u64, &src));
    u64_msg = u64_buf[0..os_u64.bytesUsed()];

    var os_typ = sofab.OStream.init(&typ_buf);
    encodeTypical(&os_typ);
    typ_msg = typ_buf[0..os_typ.bytesUsed()];

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv[0]
    const workload = args.next() orelse {
        std.process.exit(2); // no workload named
    };

    var bytes: usize = undefined;
    if (std.mem.eql(u8, workload, "encode_u64_array")) {
        @call(.never_inline, run_encode_u64_array, .{});
        bytes = u64_msg.len;
    } else if (std.mem.eql(u8, workload, "encode_typical")) {
        @call(.never_inline, run_encode_typical, .{});
        bytes = typ_msg.len;
    } else if (std.mem.eql(u8, workload, "decode_u64_array")) {
        @call(.never_inline, run_decode_u64_array, .{});
        bytes = u64_msg.len;
    } else if (std.mem.eql(u8, workload, "decode_typical")) {
        @call(.never_inline, run_decode_typical, .{});
        bytes = typ_msg.len;
    } else {
        std.process.exit(2); // unknown workload
    }

    var buf: [64]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &buf);
    const err = &stderr_writer.interface;
    try err.print("BYTES={d}\n", .{bytes});
    try err.flush();
}
