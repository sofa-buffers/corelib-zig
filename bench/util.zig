//! Shared benchmark plumbing: the process-CPU clock, the hardware cycle
//! counter and the batching rule the timed loops use. The workloads themselves
//! — datasets, messages and operations — live in `workloads.zig`; timing rules
//! and output grammar follow `documentation/BENCH_SPEC.md`.

const std = @import("std");
const builtin = @import("builtin");

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
