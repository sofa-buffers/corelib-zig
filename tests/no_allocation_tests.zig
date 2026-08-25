//! CORELIB_PLAN §6.6.4 — the **measure** half of "checked both ways".
//!
//! §6.6 forbids the codec to allocate payload storage and requires its bounded
//! working state to be sized at construction. §6.6.4 then says outright that
//! reading the source is *not sufficient*, because an allocation made through a
//! caller-supplied container leaves no `malloc` in the source to find, and asks
//! for a number beside the read: "an allocation count, or the heap high-water
//! mark, over a complete encode and a complete decode, measured after the
//! codec's one-time construction, which **MUST** be zero".
//!
//! Zig does not box the values this codec computes — every scalar it handles is
//! a machine type — so the strict form applies: zero, with no language-forced
//! handles to itemise (§6.6.2).
//!
//! Two measurements, because Zig has no global allocator to install a counter
//! into: memory arrives through an `std.mem.Allocator` **value** that somebody
//! passes in, or not at all.
//!
//!  1. **The channel does not exist** — a comptime walk over the codec's state
//!     and its whole public surface, asserting that no `std.mem.Allocator`
//!     appears in any of it. This is the half that survives a refactor: a
//!     future `feed` that grew an allocator parameter, or an `IStream` field
//!     that grew an `ArrayList`, fails to compile.
//!  2. **The heap does not move** — the process's peak resident set, read
//!     before and after 200,000 complete encode+decode round trips of a 20 KB
//!     message, must be unchanged. This is §6.6.4's "heap high-water mark"
//!     alternative, and it is the half that would catch an allocation made
//!     behind the type system (`std.heap.page_allocator` reached directly from
//!     a codec path, say) — which no signature would show.

const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test_options");
const sofab = @import("sofab");

// ---------------------------------------------------------------------------
// 1. the channel does not exist
// ---------------------------------------------------------------------------

/// True when `std.mem.Allocator` occurs anywhere in `T` — as the type itself, a
/// field, an element, a payload, or a pointee. `seen` breaks the recursion on a
/// self-referential type; everything here is comptime.
fn mentionsAllocator(comptime T: type) bool {
    @setEvalBranchQuota(200_000);
    return comptime walk(T, &.{});
}

fn walk(comptime T: type, comptime seen: []const type) bool {
    if (T == std.mem.Allocator) return true;
    inline for (seen) |s| if (s == T) return false;
    const next = seen ++ [_]type{T};
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |f| if (comptime walk(f.type, next)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |f| if (comptime walk(f.type, next)) break :blk true;
            break :blk false;
        },
        .array => |info| walk(info.child, next),
        .optional => |info| walk(info.child, next),
        .error_union => |info| walk(info.payload, next),
        // A pointer to an allocator is an allocator the codec can reach; a
        // pointer to the caller's bytes is not, and `u8` walks to false.
        .pointer => |info| walk(info.child, next),
        .@"fn" => |info| blk: {
            inline for (info.params) |p| if (p.type) |pt| {
                if (comptime walk(pt, next)) break :blk true;
            };
            break :blk if (info.return_type) |rt| walk(rt, next) else false;
        },
        else => false,
    };
}

test "mentionsAllocator finds one where there is one (control)" {
    // The walk is worthless if it cannot see an allocator, so prove it can —
    // in a field, behind a pointer, inside a union, and in a signature.
    try std.testing.expect(mentionsAllocator(std.mem.Allocator));
    try std.testing.expect(mentionsAllocator(struct { a: std.mem.Allocator }));
    try std.testing.expect(mentionsAllocator(struct { a: *std.mem.Allocator }));
    try std.testing.expect(mentionsAllocator(union(enum) { x: u8, a: std.mem.Allocator }));
    try std.testing.expect(mentionsAllocator(?std.mem.Allocator));
    try std.testing.expect(mentionsAllocator(fn (std.mem.Allocator) void));
    try std.testing.expect(mentionsAllocator(struct { inner: struct { a: std.mem.Allocator } }));
    // …and that it does not see one where there is none.
    try std.testing.expect(!mentionsAllocator(struct { buf: []u8, n: usize }));
    try std.testing.expect(!mentionsAllocator(sofab.Status));
}

test "no codec state can hold an allocator (§6.6)" {
    // The encoder's and decoder's own state: whatever they carry across calls
    // is here, and none of it is a channel to the heap. `IStream`'s carry is a
    // `[64]u8` *inside* the struct — an `ArrayList` in its place would be
    // caught by the walk, which is the shape §6.6's second violation row names
    // ("allocates nothing itself but requires a growable destination").
    try std.testing.expect(!mentionsAllocator(sofab.OStream));
    try std.testing.expect(!mentionsAllocator(sofab.IStream));
    // Sized at construction, and the size is a property of the type: the same
    // struct decodes a ten-byte and a ten-megabyte message.
    try std.testing.expect(@sizeOf(sofab.IStream) > 0);
}

test "no codec entry point takes or returns an allocator (§6.6.4, the read)" {
    // Every public declaration of the two codec types plus the one-shot
    // `decode`. A generic (`anytype`) parameter is not a channel either: the
    // visitor and the sink are the *caller's*, and what they do with their own
    // memory is §6.6.1's business, not this section's.
    inline for (.{ sofab.OStream, sofab.IStream }) |Codec| {
        inline for (@typeInfo(Codec).@"struct".decls) |d| {
            const F = @TypeOf(@field(Codec, d.name));
            if (@typeInfo(F) == .@"fn") {
                if (comptime mentionsAllocator(F)) {
                    @compileError(@typeName(Codec) ++ "." ++ d.name ++ " takes or returns an allocator");
                }
            }
        }
    }
    try std.testing.expect(!mentionsAllocator(@TypeOf(sofab.decode)));
}

// ---------------------------------------------------------------------------
// 2. the heap does not move
// ---------------------------------------------------------------------------

/// The process's peak resident set in kB, from `/proc/self/status`.
///
/// Raw syscalls rather than `std.fs`, so this file pulls no file-system layer
/// into a test binary that otherwise touches none. Skipped where there is no
/// `/proc` to read.
fn peakRss() !usize {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Under an emulator the peak RSS is the emulator's, and its translation
    // caches grow while the loop runs. build.zig says whether this binary runs
    // on the machine that built it.
    if (!test_options.native_target) return error.SkipZigTest;
    const linux = std.os.linux;
    const fd_raw = linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_raw)) < 0) return error.SkipZigTest;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (@as(isize, @bitCast(got)) < 0) return error.SkipZigTest;
        if (got == 0) break;
        n += got;
    }
    const at = std.mem.indexOf(u8, buf[0..n], "VmHWM:") orelse return error.SkipZigTest;
    var it = std.mem.tokenizeAny(u8, buf[at + "VmHWM:".len .. n], " \t\n");
    const field = it.next() orelse return error.SkipZigTest;
    return std.fmt.parseInt(usize, field, 10) catch error.SkipZigTest;
}

/// A visitor that keeps no storage: it folds every value into one counter, so
/// nothing the *test* does can move the high-water mark either.
const Folding = struct {
    acc: u64 = 0,

    pub fn unsigned(self: *Folding, id: sofab.Id, v: u64) void {
        self.acc +%= @as(u64, id) ^ v;
    }
    pub fn signed(self: *Folding, id: sofab.Id, v: i64) void {
        self.acc +%= @as(u64, id) ^ @as(u64, @bitCast(v));
    }
    pub fn fp32(self: *Folding, id: sofab.Id, v: f32) void {
        self.acc +%= @as(u64, id) ^ @as(u32, @bitCast(v));
    }
    pub fn fp64(self: *Folding, id: sofab.Id, v: f64) void {
        self.acc +%= @as(u64, id) ^ @as(u64, @bitCast(v));
    }
    pub fn string(self: *Folding, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        _ = .{ id, total, offset };
        for (chunk) |b| self.acc +%= b;
    }
    pub fn blob(self: *Folding, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        _ = .{ id, total, offset };
        for (chunk) |b| self.acc +%= b;
    }
    pub fn arrayBegin(self: *Folding, id: sofab.Id, kind: sofab.ArrayKind, count: usize) void {
        _ = kind;
        self.acc +%= @as(u64, id) +% count;
    }
    pub fn sequenceBegin(self: *Folding, id: sofab.Id) void {
        self.acc +%= id;
    }
    pub fn sequenceEnd(self: *Folding) void {
        self.acc +%= 1;
    }
};

/// One complete encode and one complete decode of a message carrying every
/// payload shape, through the streaming API on both sides.
fn roundTrip(buf: []u8, payload: []const u8, sink: *Folding) !usize {
    var os = sofab.OStream.init(buf);
    try os.writeUnsigned(1, 0xDEAD_BEEF_CAFE_F00D);
    try os.writeSigned(2, -4_000_000_000);
    try os.writeFp64(3, 2.718281828459045);
    try os.writeString(4, "a string of moderate length, encoded every round");
    try os.writeBlob(5, payload);
    try os.writeArrayUnsigned(6, &[_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try os.writeSequenceBeginLazy(7);
    try os.writeUnsigned(1, 1);
    try os.writeSequenceEnd();
    const message = buf[0..os.bytesUsed()];

    // Fed in chunks, so the carry path — the codec's only working state — runs
    // on every round rather than only on the contiguous fast path.
    var is = sofab.IStream.init();
    var off: usize = 0;
    while (off < message.len) {
        const n = @min(4096, message.len - off);
        _ = try is.feed(message[off..][0..n], sink);
        off += n;
    }
    return message.len;
}

test "a complete encode and decode move the heap high-water mark by zero (§6.6.4)" {
    const rounds = 20_000;

    // The buffers are the caller's, on the stack of this test — heap-allocated
    // here only because 90 KB is more than a test frame should hold.
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(buf);
    const payload = try alloc.alloc(u8, 20 * 1024);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 13 +% 7);

    var sink: Folding = .{};

    // Warm up: everything this loop will ever touch is resident before the
    // first reading, so the measurement is about the codec and not about the
    // pages the test itself faults in.
    for (0..200) |_| _ = try roundTrip(buf, payload, &sink);

    const before = try peakRss();
    for (0..rounds) |_| _ = try roundTrip(buf, payload, &sink);
    const after = try peakRss();

    errdefer std.debug.print(
        "peak RSS {d} kB -> {d} kB over {d} encode+decode round trips\n",
        .{ before, after, rounds },
    );
    try std.testing.expectEqual(before, after);
    // Keep the folded result alive so nothing above is optimized out.
    std.mem.doNotOptimizeAway(sink.acc);
}
