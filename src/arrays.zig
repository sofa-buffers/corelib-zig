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

/// Store the next native-array element into a dynamic slice, refusing an element
/// past the announced wire count `n`.
///
/// **The A shape** (SofaBuffers ARCHITECTURE §9.5): a native array's count is on
/// the wire ahead of its payload, so generated code bounds that count — against
/// the schema `count` (`INVALID`) or the receiver cap (`LimitExceeded`) — and
/// then allocates exactly it, once, through `allocN`. `n` is that same checked
/// count, so `s` is already `n` long when the first element arrives and the
/// growth below is dead: `i >= n` returns before `i >= s.len` can be true.
///
/// The branch is kept as a floor, not as a policy: a destination shorter than
/// `n` would otherwise drop elements silently, which is the one outcome
/// MESSAGE_SPEC §7.1 rules out for an over-count element. It doubles rather than
/// extending by one, so even reached it is O(n) rather than O(n²).
///
/// **Allocator contract:** should the grow run, it abandons the previous block
/// rather than freeing it, so this expects an arena — the decode allocator
/// generated code passes in, released as a whole when the message is dropped.
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

/// Element capacity of the block backing a `grow`-owned destination of length
/// `len` — the growth invariant this pair maintains, and the reason neither
/// helper needs a capacity field the generated destination has nowhere to keep.
///
/// **Every block `grow` allocates holds `ceilPowerOfTwo(n)` elements, and the
/// slice it hands back is the first `n` of them.** The capacity is therefore a
/// pure function of the length, recoverable on the next call without storing
/// anything: a destination of length 5 is a prefix of a block of 8, one of
/// length 8 is a block of exactly 8, and one of length 0 owns nothing.
///
/// The fallback matters only above 2^63 elements, where no power of two fits:
/// the capacity is then the length itself, which simply means every further
/// extension reallocates. It cannot make the claim too large.
inline fn capacityFor(len: usize) usize {
    if (len == 0) return 0;
    return std.math.ceilPowerOfTwo(usize, len) catch len;
}

/// Grow a decode-owned slice to `n` elements, filling new slots with `fill`.
/// Returns false when the allocation fails — the caller then drops the data
/// rather than writing out of range.
///
/// **Geometry (CORELIB_PLAN §7.2 item 8).** The block is extended to *at least*
/// `n`, never to exactly `n`: a sequence array is filled one element at a time
/// (`setElem` below), and reallocating on every element costs O(n²) copies —
/// against the arena of the allocator contract above, which *abandons* the old
/// block rather than freeing it, those copies are the peak memory, not garbage.
/// Doubling makes the total O(n) with O(log n) allocations. The slice handed
/// back is still exactly `n` long, because for a wrapper array that length *is*
/// the decoded value: highest present id + 1 (MESSAGE_SPEC §5.1). The spare
/// capacity lives past its end and is claimed, not reallocated, by the next
/// call — see `capacityFor`.
///
/// **Precondition.** The destination is `grow`'s own: it starts empty (`&.{}`,
/// which generated decode assigns before the array's first element) and is
/// modified only through `grow` / `setElem` from then on. That is what makes
/// `capacityFor` true of it. A slice from elsewhere — `allocN`, a literal —
/// belongs to the count-prefixed shape, which is allocated at its checked count
/// once and never grown; the two shapes never mix (SofaBuffers ARCHITECTURE
/// §9.5).
pub fn grow(comptime T: type, a: std.mem.Allocator, s: *[]const T, n: usize, fill: T) bool {
    const len = s.*.len;
    if (len >= n) return true;
    if (n <= capacityFor(len)) {
        // The room is already allocated — this is the common case once the
        // array has any size at all, and it costs a fill of the new slots.
        const base = @constCast(s.*.ptr);
        @memset(base[len..n], fill);
        s.* = base[0..n];
        return true;
    }
    const new = a.alloc(T, capacityFor(n)) catch return false;
    @memcpy(new[0..len], s.*);
    @memset(new[len..n], fill);
    s.* = new[0..n];
    return true;
}

/// Allocate a zeroed native-array destination of exactly `n` elements.
///
/// The **A-shape** allocation (SofaBuffers ARCHITECTURE §9.5): everything whose
/// count or length is on the wire ahead of its payload checks that word and
/// allocates exactly it, once. `n` is therefore a count the caller has *already*
/// bounded — against the schema `count` (`INVALID` above it, MESSAGE_SPEC §7.1)
/// or against the receiver cap on a schema-unbounded field (`LimitExceeded`,
/// CORELIB_PLAN §6.2.1) — because only generated code knows either number. This
/// helper commits the memory; it does not decide the bound.
///
/// On allocation failure the array decodes as empty.
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

/// Place a wrapper-array string/blob element at its wire id (= array index),
/// growing the destination and filling the id gaps left by omitted default
/// elements (MESSAGE_SPEC §5.1).
///
/// Growth is `grow`'s: the destination ends up exactly `id + 1` long, while the
/// block behind it doubles, so filling an array element by element costs O(n)
/// copies rather than O(n²). `grow`'s precondition is this function's too.
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

test "the A shape allocates once: allocN, then no store ever grows" {
    // What generated code does since generator#396: the count is bounded first,
    // the destination is allocated at exactly it, and the stores fill it. A pool
    // with room for that one allocation and nothing more proves the growth
    // branch is never reached — a second allocation could not come out of it.
    const n: usize = 64;
    var pool: [n * @sizeOf(u32) + 32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const a = fba.allocator();

    var s = allocN(u32, a, n);
    try std.testing.expectEqual(n, s.len);
    var i: usize = 0;
    for (0..n) |k| putGrowing(&s, a, &i, n, @intCast(k));
    try std.testing.expectEqual(n, i);
    for (0..n) |k| try std.testing.expectEqual(@as(u32, @intCast(k)), s[k]);

    // One element past the checked count: refused, and nothing grown into.
    putGrowing(&s, a, &i, n, 999);
    try std.testing.expectEqual(n, i);
    try std.testing.expectEqual(n, s.len);
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
