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
//!
//! ## Receiver caps (CORELIB_PLAN §6.2.1)
//!
//! A schema-**unbounded** array — one whose schema declares no `count:` — would
//! otherwise let the sender choose the receiver's allocation, so a receiver cap
//! bounds it. Three helpers here take that cap and perform the comparison:
//! `allocNCapped`, `growCapped` and `setElemCapped`, each the capped form of
//! the call the generated decode path already makes at that point. §6.2.1
//! permits exactly this — "a corelib MAY take a limit as an argument and
//! perform the check itself" — and the rule then has ONE implementation: a
//! caller that passes the cap here does not also guard in front of the call.
//!
//! **The number stays the caller's.** Nothing here holds a limit, defaults one,
//! keeps one past the call it was given for, or clamps to one. The cap is a
//! parameter; a breach is `error.LimitExceeded` (§6.3), a policy rejection of
//! well-formed bytes, never a shortened array. A format ceiling (§6.2
//! `ARRAY_MAX`) is not a receiver cap and is never reported as one — that
//! ceiling is the decoder's, and its violation is `error.InvalidMessage`.
//!
//! **The uncapped forms are for schema-bounded fields only.** There the schema
//! bound governs and its violation is `INVALID` (MESSAGE_SPEC §7.1), decided by
//! generated code before it calls; §6.2.1 forbids a receiver cap on such a
//! field, so those call sites have no cap to pass and no `error.LimitExceeded`
//! to handle. That is why the cap is a second entry point rather than an
//! optional argument: an argument spelled "no cap here" reads as *unlimited*,
//! which §6.2.1 forbids as well, and it would leave every schema-bounded call
//! site handling an error that cannot occur there.
//!
//! **A skipped field is never capped**, and nothing here can skip one: every
//! call site sits behind the MESSAGE_SPEC §7.3 tag test, in the arm that
//! decodes the field, so a field whose wire type contradicts the declared one
//! is stepped over without reaching a helper at all.

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
///
/// **This is the schema-bounded entry point**, as `allocN` is: `n` here is a
/// length the caller has already bounded against the schema `count`. A wrapper
/// array the schema leaves unbounded goes through `growCapped`, which takes the
/// receiver cap and decides it before anything is sized (CORELIB_PLAN §6.2.1).
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

/// `grow` for a **schema-unbounded** wrapper array, bounded by the receiver cap
/// `cap` the caller supplies (CORELIB_PLAN §6.2.1).
///
/// A wrapper array announces no count, so there is no count header to check:
/// its length is the highest present element id + 1 (MESSAGE_SPEC §5.1), which
/// is the `n` the caller passes. Bounding `n` by `cap` is therefore exactly the
/// element-**index** cap §6.2.1 requires — the amplification vector here is one
/// element at a huge id, not a count word, and two elements at id 0 and id
/// 16383 are a 16384-slot container.
///
/// The comparison runs **before** the destination is sized, so an over-cap
/// index neither allocates a block nor extends the slice over capacity the
/// previous call left spare. As in `allocNCapped`, an allocation failure keeps
/// its own channel — `false`, not an error — so out of memory and a refused
/// index stay distinguishable.
pub fn growCapped(
    comptime T: type,
    a: std.mem.Allocator,
    s: *[]const T,
    n: usize,
    fill: T,
    cap: usize,
) error{LimitExceeded}!bool {
    if (n > cap) return error.LimitExceeded;
    return grow(T, a, s, n, fill);
}

/// Allocate a zeroed native-array destination of exactly `n` elements.
///
/// The **A-shape** allocation (SofaBuffers ARCHITECTURE §9.5): everything whose
/// count or length is on the wire ahead of its payload checks that word and
/// allocates exactly it, once. `n` is therefore a count the caller has *already*
/// bounded against the schema `count` — a wire count above it is `INVALID`
/// (MESSAGE_SPEC §7.1) and only generated code knows that number. This helper
/// commits the memory; it does not decide that bound.
///
/// **This is the schema-bounded entry point.** A field the schema leaves
/// unbounded is bounded by the receiver instead, and goes through
/// `allocNCapped`, which takes that cap and decides it here (CORELIB_PLAN
/// §6.2.1). The two are never both in play: §6.2.1 forbids a receiver cap on a
/// field the schema already bounds.
///
/// On allocation failure the array decodes as empty.
pub fn allocN(comptime T: type, a: std.mem.Allocator, n: usize) []const T {
    const s = a.alloc(T, n) catch return &.{};
    @memset(s, std.mem.zeroes(T));
    return s;
}

/// `allocN` for a **schema-unbounded** array, bounded by the receiver cap `cap`
/// the caller supplies (CORELIB_PLAN §6.2.1).
///
/// `n` is the array's wire count, read from its header and otherwise bounded
/// only by the format ceiling — a ~10-byte message can claim `2^31` elements.
/// A count above `cap` is `error.LimitExceeded`: a **policy** rejection of
/// well-formed bytes, distinct from `InvalidMessage` (§6.3), never a clamp. It
/// is decided **before** the allocation it exists to prevent, which is the
/// point of the check sitting here rather than after the call.
///
/// **Out of memory is a different outcome and keeps its own channel.** As in
/// `allocN`, a failed allocation yields the empty slice, so the caller can
/// always tell "the receiver refused this count" (an error) from "the allocator
/// had no room" (an empty array) — the one distinction a cap on an allocating
/// helper must not lose.
///
/// `cap` is used for this one comparison and not retained: the value is the
/// caller's, per §6.2.1, and this helper neither defaults it nor remembers it.
pub fn allocNCapped(
    comptime T: type,
    a: std.mem.Allocator,
    n: usize,
    cap: usize,
) error{LimitExceeded}![]const T {
    if (n > cap) return error.LimitExceeded;
    return allocN(T, a, n);
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
///
/// **This is the schema-bounded entry point**: `id` is an index the caller has
/// already bounded against the schema `count` (an element past it is `INVALID`,
/// MESSAGE_SPEC §7.1). An unbounded wrapper array goes through `setElemCapped`.
pub fn setElem(comptime T: type, a: std.mem.Allocator, s: *[]const T, id: usize, fill: T, v: T) void {
    if (!grow(T, a, s, id + 1, fill)) return;
    @constCast(&s.*[id]).* = v;
}

/// `setElem` for a **schema-unbounded** wrapper array, bounded by the receiver
/// cap `cap` on the element **index** (CORELIB_PLAN §6.2.1) — `growCapped`'s
/// bound, applied at the placement that does the growing.
///
/// `id >= cap` is `error.LimitExceeded`, tested before the destination is sized
/// and before `id + 1` is ever formed.
///
/// **`cap` is the array-count cap, and only that.** An element's own payload
/// length — a `string`'s or `blob`'s `max_dyn_*_len` — is not this call's
/// business: the payload arrives through the visitor's own callback and is
/// bounded there, before it is handed to `v`.
pub fn setElemCapped(
    comptime T: type,
    a: std.mem.Allocator,
    s: *[]const T,
    id: usize,
    fill: T,
    v: T,
    cap: usize,
) error{LimitExceeded}!void {
    if (id >= cap) return error.LimitExceeded;
    setElem(T, a, s, id, fill, v);
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

// --- receiver caps (CORELIB_PLAN §6.2.1) -----------------------------------

test "allocNCapped refuses a count above the cap, before allocating anything" {
    // A pool with no room at all: reaching the allocator is observable as an
    // empty result, so an over-cap count that errors instead proves the check
    // ran ahead of the allocation it exists to prevent.
    var pool: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const a = fba.allocator();
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 65, 64));
}

test "allocNCapped: the cap is a maximum, not an exclusive bound" {
    const a = std.testing.allocator;
    const at_cap = try allocNCapped(u32, a, 64, 64);
    defer a.free(@constCast(at_cap));
    try std.testing.expectEqual(@as(usize, 64), at_cap.len);
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 65, 64));
}

test "a refused count is an error, never a shortened array" {
    // §6.2.1 "Rejected, never clamped": the caller must not be handed `cap`
    // elements where the wire said more.
    const a = std.testing.allocator;
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 1_000_000, 8));
}

test "out of memory and an over-cap count stay distinguishable" {
    // The one distinction a cap on an allocating helper must not lose: OOM
    // keeps `allocN`'s empty-slice channel, the cap breach is the error.
    var pool: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const a = fba.allocator();
    const oom = try allocNCapped(u32, a, 4, 64); // within the cap, no memory
    try std.testing.expectEqual(@as(usize, 0), oom.len);
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 65, 64));
}

test "the cap is the caller's, per call: nothing is retained between them" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 8, 4));
    const wider = try allocNCapped(u32, a, 8, 16); // the earlier 4 binds nothing
    defer a.free(@constCast(wider));
    try std.testing.expectEqual(@as(usize, 8), wider.len);
}

test "growCapped bounds the element index and grows nothing above it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const u32 = &.{};
    // A wrapper array's length is its highest present id + 1, so a cap of 8
    // admits ids 0..7 and refuses id 8.
    try std.testing.expect(try growCapped(u32, a, &s, 8, 0, 8));
    try std.testing.expectEqual(@as(usize, 8), s.len);
    try std.testing.expectError(error.LimitExceeded, growCapped(u32, a, &s, 9, 0, 8));
    // Refused before the destination was sized: the length is what it was.
    try std.testing.expectEqual(@as(usize, 8), s.len);
}

test "growCapped refuses before it claims spare capacity" {
    // The block behind a length of 5 holds 8 (see `capacityFor`), so growing to
    // 6 would be a pure memset with no allocator call at all. The cap must
    // still refuse it, or a destination could pass its cap for free.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const u32 = &.{};
    try std.testing.expect(try growCapped(u32, a, &s, 5, 0, 5));
    try std.testing.expectError(error.LimitExceeded, growCapped(u32, a, &s, 6, 0, 5));
    try std.testing.expectEqual(@as(usize, 5), s.len);
}

test "setElemCapped places up to the cap and refuses the index past it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const []const u8 = &.{};
    try setElemCapped([]const u8, a, &s, 3, "", "d", 4);
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("d", s[3]);
    try std.testing.expectEqualStrings("", s[0]); // the gap keeps the fill

    try std.testing.expectError(error.LimitExceeded, setElemCapped([]const u8, a, &s, 4, "", "e", 4));
    try std.testing.expectEqual(@as(usize, 4), s.len);
}

test "setElemCapped refuses a huge index without forming id + 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: []const u32 = &.{};
    try std.testing.expectError(
        error.LimitExceeded,
        setElemCapped(u32, arena.allocator(), &s, std.math.maxInt(usize), 0, 7, 65536),
    );
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "a matrix row takes the index cap first, then the row's own count" {
    // ARCHITECTURE §9.5: id first, then count -- the order the generated
    // `sequenceBegin` arm calls them in.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows: []const []const u32 = &.{};
    try std.testing.expect(try growCapped([]const u32, a, &rows, 2, &.{}, 4));
    at(rows, 1).* = try allocNCapped(u32, a, 3, 4);
    try std.testing.expectEqual(@as(usize, 3), rows[1].len);

    // The row index is refused before the row's count is ever looked at.
    try std.testing.expectError(error.LimitExceeded, growCapped([]const u32, a, &rows, 5, &.{}, 4));
    // And a row whose own count clears the index cap is refused on the count.
    try std.testing.expectError(error.LimitExceeded, allocNCapped(u32, a, 5, 4));
}

test "the uncapped forms carry no limit of their own" {
    // §6.2.1: the codec holds no limit and defaults none. The schema-bounded
    // entry points take no cap at all, so a count generated code has cleared
    // against the schema is allocated whatever a receiver cap elsewhere says.
    const a = std.testing.allocator;
    const s = allocN(u32, a, 100_000);
    defer a.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 100_000), s.len);
}
