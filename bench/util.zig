//! Shared benchmark plumbing: process-CPU clock, hardware cycle counter, and
//! the checksum visitor that keeps the optimizer honest. Workloads, timing
//! rules and output grammar follow `documentation/BENCH_SPEC.md`.

const std = @import("std");
const builtin = @import("builtin");
const sofab = @import("sofab");

/// Process CPU time in seconds (not wall-clock), via
/// `clock_gettime(CLOCK_PROCESS_CPUTIME_ID)` — so the number reflects the cost
/// of the implementation rather than OS scheduling noise.
pub fn cpuNow() f64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.PROCESS_CPUTIME_ID, &ts);
            return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
        },
        else => @compileError("the bench tools need a POSIX process CPU clock (Linux)"),
    }
}

/// Whether this target has a userspace-readable hardware cycle counter.
pub const have_cycles = switch (builtin.cpu.arch) {
    .x86_64, .x86, .aarch64 => true,
    else => false,
};

/// Read the hardware cycle counter (x86 TSC / AArch64 virtual count register).
pub inline fn cycles() u64 {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => blk: {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            break :blk (@as(u64, hi) << 32) | lo;
        },
        .aarch64 => blk: {
            var v: u64 = undefined;
            asm volatile ("mrs %[v], cntvct_el0"
                : [v] "=r" (v),
            );
            break :blk v;
        },
        else => 0,
    };
}

/// Decode sink that folds every value into a checksum so the optimizer cannot
/// elide the decode work.
pub const Checksum = struct {
    acc: u64 = 0,

    pub fn unsigned(self: *Checksum, id: sofab.Id, v: u64) void {
        self.acc +%= v ^ id;
    }
    pub fn signed(self: *Checksum, id: sofab.Id, v: i64) void {
        self.acc +%= @as(u64, @bitCast(v)) ^ id;
    }
    pub fn fp32(self: *Checksum, _: sofab.Id, v: f32) void {
        self.acc +%= @as(u32, @bitCast(v));
    }
    pub fn fp64(self: *Checksum, _: sofab.Id, v: f64) void {
        self.acc +%= @as(u64, @bitCast(v));
    }
    pub fn string(self: *Checksum, _: sofab.Id, _: usize, _: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
    }
    pub fn blob(self: *Checksum, _: sofab.Id, _: usize, _: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
    }
    // Declaring `sequenceBegin` is what makes a visitor descend: without it the
    // decoder auto-skips whole sub-sequences, and the typical-message workload
    // would stop decoding the two fields inside its nested scope — measuring
    // less work than the other ports' benchmarks do (BENCH_SPEC).
    pub fn sequenceBegin(self: *Checksum, id: sofab.Id) void {
        self.acc +%= id;
    }
    pub fn sequenceEnd(self: *Checksum) void {
        self.acc +%= 1;
    }
};

/// A spread of unsigned values exercising 1..10-byte varints (identical
/// generator in every language: `src[i] = i * 0x9E3779B97F4A7C15`, wrapping).
pub fn makeSrc(comptime n: usize, out: *[n]u64) void {
    for (out, 0..) |*v, i| v.* = @as(u64, i) *% 0x9E37_79B9_7F4A_7C15;
}

/// How long one batch of operations runs before the clock is read again.
///
/// `clock_gettime(CLOCK_PROCESS_CPUTIME_ID)` is a real syscall — never
/// vDSO-accelerated — costing on the order of a microsecond, so reading it once
/// per operation would time the clock rather than the codec. Ten milliseconds of
/// work per read puts the clock cost under ~0.01 % of a batch.
pub const batch_seconds: f64 = 0.01;

/// Grow a batch until it spans `batch_seconds`, so the single clock read that
/// ends it is a rounding error against the work it timed. Doubles as warmup.
pub fn calibrateBatch(ctx: anytype) u64 {
    var batch: u64 = 1;
    while (true) : (batch *= 2) {
        const t0 = cpuNow();
        var k: u64 = 0;
        while (k < batch) : (k += 1) std.mem.doNotOptimizeAway(ctx.run());
        if (cpuNow() - t0 >= batch_seconds) return batch;
    }
}

/// Element count of the `u64 array (1000)` workload (BENCH_SPEC).
pub const N = 1000;

/// The `typical` message of BENCH_SPEC: a few scalars, a float, a short string
/// and a small array, plus a nested sequence. The literal values are the
/// spec's — every port encodes these exact bytes, so they must not be swapped
/// for language math constants.
pub fn encodeTypical(os: *sofab.OStream) void {
    os.writeUnsigned(1, 0xDEAD_BEEF) catch unreachable;
    os.writeSigned(2, -12345) catch unreachable;
    os.writeBoolean(3, true) catch unreachable;
    os.writeFp32(4, 3.14159) catch unreachable;
    os.writeString(5, "sofab") catch unreachable;
    os.writeArrayUnsigned(6, &[_]u16{ 10, 20, 30, 40 }) catch unreachable;
    os.writeSequenceBeginLazy(7) catch unreachable;
    os.writeUnsigned(1, 99) catch unreachable;
    os.writeSigned(2, -7) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
}

/// The two workload inputs `bench` and `callgrind` share, plus the output
/// buffers their encode halves write into. Filled by `prepare`.
pub var src: [N]u64 = undefined;
pub var u64_msg: []const u8 = undefined;
pub var typ_msg: []const u8 = undefined;
pub var enc_u64_out: [N * 11 + 16]u8 = undefined;
pub var enc_typ_out: [256]u8 = undefined;
var u64_buf: [N * 11 + 16]u8 = undefined;
var typ_buf: [256]u8 = undefined;

/// Build the workload data and pre-encode both messages — the decode inputs and
/// the byte sizes the reports print. Never part of a measured operation.
pub fn prepare() !void {
    makeSrc(N, &src);
    var os_u64 = sofab.OStream.init(&u64_buf);
    try os_u64.writeArrayUnsigned(1, @as([]const u64, &src));
    u64_msg = u64_buf[0..os_u64.bytesUsed()];

    var os_typ = sofab.OStream.init(&typ_buf);
    encodeTypical(&os_typ);
    typ_msg = typ_buf[0..os_typ.bytesUsed()];
}
