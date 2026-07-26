//! Array helpers the generated encode/decode paths need for every array field.
//!
//! None of them carry schema knowledge — the count, the element default and the
//! allocator are passed in — so they live here rather than being emitted into
//! every generated module.

const std = @import("std");

/// Store the next native-array element into a dynamic (count-less) slice,
/// bounds-checked.
///
/// The slice is pre-sized to the wire count, so the bound only guards a failed
/// allocation; the data is then dropped rather than written out of range.
pub fn put(s: anytype, i: *usize, v: std.meta.Elem(@TypeOf(s))) void {
    if (i.* >= s.len) return;
    @constCast(&s[i.*]).* = v;
    i.* += 1;
}

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

/// Trim the trailing run of element defaults off a fixed-count native array:
/// returns `a[0..M']`, where `M'` is one past the last element that differs from
/// the element default (`0` when every element is the default).
///
/// A `count: N` array is fixed-length, so its canonical wire form carries only
/// those `M'` elements and the decoder rebuilds the trailing default run from
/// the schema count (MESSAGE_SPEC §3). A dynamic (count-less) array has no `N`
/// to refill from and is never trimmed.
///
/// Elements compare by BIT PATTERN — the element's byte image — never by `==`.
/// A trailing `-0.0` (which `== 0.0`) must survive the round-trip instead of
/// being silently trimmed to `+0.0`, and a `NaN` is never a default. Every
/// native element type (u8..u64, i8..i64, f32, f64, bool, and the enum/bitfield
/// integer backings) is padding-free, so the byte image is exact.
///
/// `a` is a fixed field's `[0..]` (a `*const [N]T`) or its `sliceAsBytes` image,
/// so the result is always a slice, never the pointer-to-array.
pub fn trimTail(a: anytype) []const std.meta.Elem(@TypeOf(a)) {
    var n = a.len;
    while (n > 0 and std.mem.allEqual(u8, std.mem.asBytes(&a[n - 1]), 0)) : (n -= 1) {}
    return a[0..n];
}

/// Mutable pointer to the last element of a decode-allocated slice.
pub fn last(s: anytype) *std.meta.Elem(@TypeOf(s)) {
    return @constCast(&s[s.len - 1]);
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

test "trimTail drops only the trailing run" {
    const a = [_]u32{ 1, 0, 2, 0, 0 };
    try std.testing.expectEqual(@as(usize, 3), trimTail(a[0..]).len);
}

test "trimTail of an all-default array is empty" {
    const a = [_]u32{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 0), trimTail(a[0..]).len);
    // A slice, not a `[0]u32`: indexing a comptime zero-length ARRAY type is a
    // compile error even on a branch that cannot run, and generated code always
    // passes a slice.
    const e: []const u32 = &.{};
    try std.testing.expectEqual(@as(usize, 0), trimTail(e).len);
}

test "trimTail compares bits: -0.0 is not the default" {
    // == would trim these (since -0.0 == 0.0) and change the encoded bytes.
    const a = [_]f32{ 1.0, -0.0 };
    try std.testing.expectEqual(@as(usize, 2), trimTail(a[0..]).len);
    const b = [_]f64{ 1.0, -0.0 };
    try std.testing.expectEqual(@as(usize, 2), trimTail(b[0..]).len);
    // +0.0 is.
    const c = [_]f32{ 1.0, 0.0, 0.0 };
    try std.testing.expectEqual(@as(usize, 1), trimTail(c[0..]).len);
}

test "trimTail never takes a NaN for the default" {
    const a = [_]f64{std.math.nan(f64)};
    try std.testing.expectEqual(@as(usize, 1), trimTail(a[0..]).len);
}

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

test "put drops an over-count element silently" {
    var dst = [_]u32{0};
    var i: usize = 0;
    put(dst[0..], &i, 7);
    put(dst[0..], &i, 8); // no room; dropped, no flag
    try std.testing.expectEqual(@as(u32, 7), dst[0]);
    try std.testing.expectEqual(@as(usize, 1), i);
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
