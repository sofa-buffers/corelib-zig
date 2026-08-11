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

// ---- Callgrind workload entry points (one op each) ------------------------
// `export` gives each a stable C symbol so `--toggle-collect=run_<w>` matches.
// The workloads themselves — data, message and buffers — are `util`'s, shared
// with `bench.zig` so the two tools cannot drift apart.

export fn run_encode_u64_array() void {
    var os = sofab.OStream.init(&util.enc_u64_out);
    os.writeArrayUnsigned(1, @as([]const u64, &util.src)) catch unreachable;
    std.mem.doNotOptimizeAway(os.bytesUsed());
}

export fn run_encode_typical() void {
    var os = sofab.OStream.init(&util.enc_typ_out);
    util.encodeTypical(&os);
    std.mem.doNotOptimizeAway(os.bytesUsed());
}

export fn run_decode_u64_array() void {
    var sink: util.Checksum = .{};
    var is = sofab.IStream.init();
    _ = is.feed(util.u64_msg, &sink) catch unreachable;
    std.mem.doNotOptimizeAway(sink.acc);
}

export fn run_decode_typical() void {
    var sink: util.Checksum = .{};
    var is = sofab.IStream.init();
    _ = is.feed(util.typ_msg, &sink) catch unreachable;
    std.mem.doNotOptimizeAway(sink.acc);
}

pub fn main(init: std.process.Init) !void {
    // Decode inputs and byte sizes — outside the measured op.
    try util.prepare();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv[0]
    const workload = args.next() orelse {
        std.process.exit(2); // no workload named
    };

    var bytes: usize = undefined;
    if (std.mem.eql(u8, workload, "encode_u64_array")) {
        @call(.never_inline, run_encode_u64_array, .{});
        bytes = util.u64_msg.len;
    } else if (std.mem.eql(u8, workload, "encode_typical")) {
        @call(.never_inline, run_encode_typical, .{});
        bytes = util.typ_msg.len;
    } else if (std.mem.eql(u8, workload, "decode_u64_array")) {
        @call(.never_inline, run_decode_u64_array, .{});
        bytes = util.u64_msg.len;
    } else if (std.mem.eql(u8, workload, "decode_typical")) {
        @call(.never_inline, run_decode_typical, .{});
        bytes = util.typ_msg.len;
    } else {
        std.process.exit(2); // unknown workload
    }

    var buf: [64]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &buf);
    const err = &stderr_writer.interface;
    try err.print("BYTES={d}\n", .{bytes});
    try err.flush();
}
