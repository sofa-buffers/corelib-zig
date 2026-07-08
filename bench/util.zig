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
};

/// A spread of unsigned values exercising 1..10-byte varints (identical
/// generator in every language: `src[i] = i * 0x9E3779B97F4A7C15`, wrapping).
pub fn makeSrc(comptime n: usize, out: *[n]u64) void {
    for (out, 0..) |*v, i| v.* = @as(u64, i) *% 0x9E37_79B9_7F4A_7C15;
}
