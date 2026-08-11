//! Array helpers the generated **decode** path needs for array fields: bounded
//! element stores, growth of a decode-owned destination, and wrapper-array
//! element placement.
//!
//! None of them carry schema knowledge — the count, the element default and the
//! allocator are passed in — so they live here rather than being emitted into
//! every generated module. Every helper here has an emitted call site: the set
//! is closed (CORELIB_PLAN §6.1), so nothing untraceable sits on the public
//! surface.
//!
//! There is no encode-side helper, and in particular no trailing-default trim:
//! a compact scalar array is written linearly and gap-free, `M` being its
//! length, so `[1, 2, 0, 0]` and `[1, 2]` are different values that encode
//! differently (MESSAGE_SPEC §3).

const std = @import("std");

/// Store the next native-array element into a dynamic slice, growing a capped
/// initial allocation geometrically as the elements actually arrive — never past
/// the announced wire count `n`.
///
/// The counterpart to allocating `n` elements up front: the wire count is
/// untrusted, so a decoder that believes it would let a one-line header demand
/// an arbitrary allocation. Starting small and growing to what actually arrives
/// bounds the cost to the data really sent, while `n` still caps the total. An
/// element the grow cannot hold (allocation failure) is dropped.
///
/// **Allocator contract:** each grow abandons the previous block rather than
/// freeing it, so this expects an arena — the decode allocator generated code
/// passes in, released as a whole when the message is dropped. Handed a
/// general-purpose allocator it leaks every intermediate block.
pub fn putGrowing(s: anytype, a: std.mem.Allocator, i: *usize, n: usize, v: std.meta.Elem(@TypeOf(s.*))) void {
    if (i.* >= n) return;
    if (i.* >= s.*.len) {
        const T = std.meta.Elem(@TypeOf(s.*));
        const new = a.alloc(T, @min(@max(s.*.len * 2, i.* + 1), n)) catch return;
        @memcpy(new[0..s.*.len], s.*);
        @memset(new[s.*.len..], std.mem.zeroes(T));
        s.* = new;
    }
    @constCast(&s.*[i.*]).* = v;
    i.* += 1;
}

/// Store the next native-array element into a fixed `[N]T` destination.
///
/// An element past the schema capacity `N` flags the message malformed: a wire
/// count above the schema count is INVALID and must be rejected, never clamped
/// (MESSAGE_SPEC §7.1).
pub fn putChecked(s: anytype, i: *usize, v: std.meta.Elem(@TypeOf(s)), inv: *bool) void {
    if (i.* >= s.len) {
        inv.* = true;
        return;
    }
    @constCast(&s[i.*]).* = v;
    i.* += 1;
}

/// Grow a decode-owned slice to `n` elements, filling new slots with `fill`.
/// Returns false when the allocation fails — the caller then drops the data
/// rather than writing out of range.
pub fn grow(comptime T: type, a: std.mem.Allocator, s: *[]const T, n: usize, fill: T) bool {
    if (s.*.len >= n) return true;
    const new = a.alloc(T, n) catch return false;
    @memcpy(new[0..s.*.len], s.*);
    @memset(new[s.*.len..], fill);
    s.* = new;
    return true;
}

/// Allocate a zeroed native-array destination of exactly `n` elements (the wire
/// count). On allocation failure the array decodes as empty.
pub fn allocN(comptime T: type, a: std.mem.Allocator, n: usize) []const T {
    const s = a.alloc(T, n) catch return &.{};
    @memset(s, std.mem.zeroes(T));
    return s;
}

/// Place a wrapper-array string/blob element at its wire id (= array index),
/// growing the destination and filling the id gaps left by omitted default
/// elements (MESSAGE_SPEC §5.1).
pub fn setElem(comptime T: type, a: std.mem.Allocator, s: *[]const T, id: usize, fill: T, v: T) void {
    if (!grow(T, a, s, id + 1, fill)) return;
    @constCast(&s.*[id]).* = v;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "putChecked flags an over-count element instead of clamping" {
    var dst = [_]u32{ 0, 0 };
    var i: usize = 0;
    var inv = false;
    putChecked(dst[0..], &i, 1, &inv);
    putChecked(dst[0..], &i, 2, &inv);
    try std.testing.expect(!inv);
    putChecked(dst[0..], &i, 3, &inv); // one past the schema count
    try std.testing.expect(inv);
    try std.testing.expectEqual(@as(u32, 2), dst[1]);
}

test "grow fills new slots and keeps the old ones" {
    var s: []const u32 = &.{ 1, 2 };
    try std.testing.expect(grow(u32, std.testing.allocator, &s, 4, 0));
    defer std.testing.allocator.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqual(@as(u32, 2), s[1]);
    try std.testing.expectEqual(@as(u32, 0), s[3]);
    // Already long enough: unchanged, nothing allocated.
    try std.testing.expect(grow(u32, std.testing.allocator, &s, 2, 0));
    try std.testing.expectEqual(@as(usize, 4), s.len);
}

test "setElem fills the gaps left by omitted default elements" {
    var s: []const u32 = &.{};
    setElem(u32, std.testing.allocator, &s, 3, 0, 9);
    defer std.testing.allocator.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqual(@as(u32, 0), s[0]);
    try std.testing.expectEqual(@as(u32, 9), s[3]);
}

test "putGrowing never allocates past the announced count" {
    // An arena, per the allocator contract: growing abandons the previous block.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: []const u32 = &.{};
    var i: usize = 0;
    // An announced count of 3: the store grows as elements arrive, and the
    // fourth is refused rather than growing the allocation past what was
    // announced.
    for ([_]u32{ 1, 2, 3, 4 }) |v| putGrowing(&s, arena.allocator(), &i, 3, v);
    try std.testing.expectEqual(@as(usize, 3), i);
    try std.testing.expect(s.len <= 3);
    try std.testing.expectEqual(@as(u32, 3), s[2]);
}

test "putGrowing on a lying header allocates only what arrives" {
    // The header announces a million elements; two arrive. The allocation must
    // follow the data, not the claim.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: []const u32 = &.{};
    var i: usize = 0;
    putGrowing(&s, arena.allocator(), &i, 1_000_000, 7);
    putGrowing(&s, arena.allocator(), &i, 1_000_000, 8);
    try std.testing.expectEqual(@as(usize, 2), i);
    try std.testing.expect(s.len < 16);
    try std.testing.expectEqual(@as(u32, 8), s[1]);
}

test "allocN yields exactly n zeroed elements" {
    const s = allocN(u32, std.testing.allocator, 3);
    defer std.testing.allocator.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 3), s.len);
    for (s) |v| try std.testing.expectEqual(@as(u32, 0), v);
}
