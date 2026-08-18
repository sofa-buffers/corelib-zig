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

/// Mutable pointer to element `i` of a decode destination.
///
/// A message field is `[]const T` because the same struct is what a caller
/// **constructs** a message from, and a comptime literal — `m.chunks = &.{&b};`
/// — only coerces to a const slice. That constness is the encode-side contract;
/// it says nothing about the decode side, which allocates the destination and
/// then has to fill it. This is where the two meet, and it is the same
/// `@constCast` that `putGrowing`, `putChecked` and `setElem` already end in,
/// exposed for the stores that do not go through one of them.
///
/// Composes, which is why it is a pointer helper rather than a set of
/// purpose-shaped ones: a decode path into a nested row reaches its leaf as
/// `at(at(rows, i).*, j)`, and a struct element's field as `at(rows, i).x`.
///
/// The element id IS the array index (MESSAGE_SPEC §5.1), so a caller grows the
/// destination to id + 1 — default-filling the gaps left by elements a
/// conformant encoder omitted (§2) — and every child store then lands HERE, at
/// that index. Appending instead would shorten the array by the size of any
/// interior gap, and would decode a REOPENED element id as a second element
/// rather than merging into the first (§7.4).
pub fn at(s: anytype, i: usize) *std.meta.Elem(@TypeOf(s)) {
    return @constCast(&s[i]);
}

/// Ceiling on the storage an *announced* element count may claim up front
/// (`allocCapped`), in elements.
///
/// A DoS policy constant, not a wire one: two decoders may disagree about it
/// and still accept the same messages and recover the same values, so no shared
/// vector can settle it. It is versioned with the wire code instead, here, next
/// to the growth policy it belongs to.
///
/// In elements rather than bytes, so the worst case scales with the element
/// width: 1024 `u64`s is 8 KiB of eager storage, and every element a larger
/// count claims beyond that is paid for only as it actually arrives.
pub const ARRAY_INIT_CAP: usize = 1024;

/// Initial storage for a native array announcing `n` wire elements, capped at
/// `ARRAY_INIT_CAP`.
///
/// The announced count is untrusted until its elements arrive: CORELIB_PLAN
/// §4.8 has a decoder read `element_count` "allocating nothing on the strength
/// of that count", so a one-line header claiming `2^31` elements must cost a
/// bounded allocation and nothing more. `putGrowing` then extends the store as
/// the elements really arrive, never past `n`. On allocation failure the array
/// decodes as empty.
pub fn allocCapped(comptime T: type, a: std.mem.Allocator, n: usize) []const T {
    return allocN(T, a, @min(n, ARRAY_INIT_CAP));
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

test "at writes through a const-typed destination" {
    // What a decode does: the field is []const T for the caller's sake, the
    // decoder allocates it and fills it in place.
    var buf = [_]u32{ 0, 0, 0 };
    const dst: []const u32 = buf[0..];
    at(dst, 1).* = 7;
    try std.testing.expectEqual(@as(u32, 7), dst[1]);
    try std.testing.expectEqual(@as(u32, 0), dst[0]);
}

test "at composes for a nested row and a struct element" {
    var r0 = [_]u32{ 0, 0 };
    var r1 = [_]u32{ 0, 0 };
    var rowbuf = [_][]const u32{ r0[0..], r1[0..] };
    const rows: []const []const u32 = rowbuf[0..];
    at(at(rows, 1).*, 0).* = 9; // rows[1][0]
    try std.testing.expectEqual(@as(u32, 9), rows[1][0]);
    try std.testing.expectEqual(@as(u32, 0), rows[0][0]);

    const P = struct { x: i32 = 0, y: i32 = 0 };
    var pts = [_]P{ .{}, .{} };
    const ps: []const P = pts[0..];
    at(ps, 0).x = -3; // a field of a struct element, not the element itself
    try std.testing.expectEqual(@as(i32, -3), ps[0].x);
    try std.testing.expectEqual(@as(i32, 0), ps[1].x);
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

test "allocCapped hands a count under the cap through untouched" {
    const s = allocCapped(u32, std.testing.allocator, 3);
    defer std.testing.allocator.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 3), s.len);
    for (s) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "allocCapped allocates nothing on the strength of an absurd count" {
    // A header announcing 2^31 - 1 elements — 8 GiB of u32 — against a pool
    // that holds only the cap. An eager allocation of the announced count
    // cannot come out of this buffer at all, so the array would decode as
    // empty; the capped one fits and the elements then arrive into it.
    var pool: [ARRAY_INIT_CAP * @sizeOf(u32) + 64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const s = allocCapped(u32, fba.allocator(), 2_147_483_647);
    try std.testing.expectEqual(ARRAY_INIT_CAP, s.len);
    for (s) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "the capped store still holds the elements that do arrive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The announced count is a lie, so the eager allocation is the cap; the two
    // elements that follow land in it without growing anything.
    const n: usize = 2_147_483_647;
    var s = allocCapped(u32, a, n);
    var i: usize = 0;
    putGrowing(&s, a, &i, n, 7);
    putGrowing(&s, a, &i, n, 8);
    try std.testing.expectEqual(@as(usize, 2), i);
    try std.testing.expectEqual(ARRAY_INIT_CAP, s.len);
    try std.testing.expectEqualSlices(u32, &.{ 7, 8 }, s[0..2]);
}
