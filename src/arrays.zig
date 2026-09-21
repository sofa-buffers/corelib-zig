//! Array helpers the generated **decode** path needs for array fields: bounded
//! element stores, growth of a decode-owned destination, and wrapper-array
//! element placement.
//!
//! None of them carry schema knowledge — the bound, the element default and the
//! allocator are passed in, the element type is a type parameter — so they live
//! here rather than being emitted into every generated module (SofaBuffers
//! ARCHITECTURE §8). Every helper here has an emitted call site: the set is
//! closed (CORELIB_PLAN §6.1), so nothing untraceable sits on the public
//! surface.
//!
//! There is no encode-side helper, and in particular no trailing-default trim:
//! a compact scalar array is written linearly and gap-free, `M` being its
//! length, so `[1, 2, 0, 0]` and `[1, 2]` are different values that encode
//! differently (MESSAGE_SPEC §3).
//!
//! ## Ids are positions (MESSAGE_SPEC §5.1)
//!
//! A **wrapper array** — one whose elements are strings, blobs, sub-messages or
//! further arrays — carries no count header. Each element arrives keyed by an
//! unbounded varint id, that id **is** the element's index, and the decoded
//! array's length is *highest present id + 1*. Three consequences run through
//! every helper below:
//!
//! * a missing id **fills a gap** with the element default rather than shifting
//!   every later element down by one — an interior element equal to that default
//!   may be omitted by a conformant encoder (§2);
//! * a repeated id **replaces** rather than appends (§7.4);
//! * the container therefore grows as elements arrive, and what has to be
//!   bounded is the **index**, *before* the container it indexes into is
//!   extended (CORELIB_PLAN §7.2 item 8). A rejected id must leave the container
//!   unextended, so a lower id delivered afterwards still lands.
//!
//! A **native array** is the other shape (SofaBuffers ARCHITECTURE §9.5 shape
//! A): its count is on the wire ahead of its payload, so that count is bounded
//! at the header word and the destination is then allocated at exactly it, once.
//! `allocCounted` is that shape; `placeElem` / `reserveElem` / `reserveRow` are
//! the wrapper one.
//!
//! ## One index rule, two verdicts: `Bound` (CORELIB_PLAN §6.2.1)
//!
//! Which bound governs an array decides only what breaching it is *called*, so
//! the comparison has exactly one implementation here (`overIndex`,
//! `overCount`) and the caller states which rule it is under:
//!
//! * `.{ .schema = n }` — the schema declared `count: n`. The wire contradicts
//!   the schema both peers agreed on, so a breach is `error.InvalidMessage`
//!   (MESSAGE_SPEC §7.1). A schema `count` is a **capacity**, not a length: the
//!   container starts empty and the wire carries the length, so `id >= n` is the
//!   test and not `id > n`.
//! * `.{ .receiver = n }` — the schema declared none, so the receiver's own cap
//!   governs. The bytes are well formed and decode under a looser cap, so a
//!   breach is `error.LimitExceeded` (§6.3) — a policy rejection, never
//!   `INVALID` and never a shortened array.
//!
//! **The two are never both in play**: §6.2.1 forbids applying a receiver cap to
//! a field the schema already bounds, which is why `Bound` is a two-state value
//! rather than a pair of optional arguments. There is deliberately **no third
//! tag**: §6.2.1 admits "no unset state and no unlimited mode", so omitting the
//! bound is a *compile* error here — the guarantee the sibling ports buy with
//! unexported fields and required named arguments. `Bound.Err()` narrows the
//! error set to the one verdict that bound can produce, so a schema-bounded call
//! site never handles a `LimitExceeded` that cannot occur there.
//!
//! **The number stays the caller's.** Nothing here holds a limit, defaults one,
//! keeps one past the call it was given for, or clamps to one. A format ceiling
//! (§6.2 `ARRAY_MAX`) is not a receiver cap and is never reported as one — that
//! ceiling is the decoder's, and its violation is `error.InvalidMessage`.
//!
//! **The bound is a `comptime` parameter**, because the generator knows it
//! statically (ARCHITECTURE §8: "resolve everything at generation time"). A call
//! site therefore lowers to the same comparison against the same constant an
//! emitted `if (id >= 5)` produced, with no runtime tag test and no call frame —
//! which is the whole reason the bound can move here at no cost on a maxspeed
//! target.
//!
//! ## What is *not* here
//!
//! A string or blob element's own `maxlen` is not one of these arguments: the
//! payload arrives through the visitor's own callback and its length must be
//! decided at the **length word**, before the payload, so a message truncated
//! right after that word is `INVALID` rather than `INCOMPLETE` (MESSAGE_SPEC
//! §5.2). There is no sizing call here for it to ride — the receiver-cap half
//! rides `PayloadAcc.beginCapped` / `takeCapped` instead — so the schema-`maxlen`
//! comparison stays in the generated `fixlenBegin` arm, beside the `overIndex`
//! that bounds the element's index at the same word.
//!
//! Likewise the **routing** of a framed element — binding the element index,
//! descending into the child scope, resetting a re-opened wrapper row (§7.4) —
//! has a different shape per schema and stays generated. `reserveElem` owns
//! growth and the bound, and stops at the slot.
//!
//! **A skipped field is never bounded here**, and nothing here can skip one:
//! every call site sits behind the MESSAGE_SPEC §7.3 tag test, in the arm that
//! decodes the field, so a field whose wire type contradicts the declared one is
//! stepped over without reaching a helper at all.

const std = @import("std");

/// Which bound governs an array's element index or element count, and therefore
/// what breaching it is called (CORELIB_PLAN §6.2.1). See the module note: the
/// two are never both in play, there is no third state, and the number is the
/// caller's.
pub const Bound = union(enum) {
    /// The schema declared `count: n` (a **capacity**). A breach contradicts the
    /// schema both peers agreed on: `INVALID` (MESSAGE_SPEC §7.1).
    schema: usize,
    /// The schema declared none, so the receiver's own cap governs. A breach is
    /// a policy rejection of well-formed bytes: `LimitExceeded` (§6.2.1, §6.3).
    receiver: usize,

    /// The error set this bound can produce — the one verdict, not a union of
    /// both. This is what the withdrawn capped/uncapped entry-point split used
    /// to buy by having two names; the bound now carries it in the type instead,
    /// so a schema-bounded call site still handles no error that cannot occur
    /// there.
    pub inline fn Err(comptime b: Bound) type {
        return switch (b) {
            .schema => error{InvalidMessage},
            .receiver => error{LimitExceeded},
        };
    }
};

/// THE implementation of the element-**index** rule, for any element type
/// (CORELIB_PLAN §6.2.1: the rule "MUST have one implementation whichever way it
/// was stated").
///
/// A wrapper array carries no count header, so the index is what a bound can
/// bind: its length is highest present id + 1 (MESSAGE_SPEC §5.1), and two
/// elements at id 0 and id 65535 are a 65536-slot container. The comparison runs
/// **before** anything is sized and before `id + 1` is ever formed, which is the
/// enforcement point §6.2.1 fixes for an array with no count word.
///
/// Exposed on its own for the one site that has no container operation to ride:
/// a generated `fixlenBegin` bounds a string/blob element's index at the
/// **length word**, so a message that ends right there is still `INVALID` rather
/// than `INCOMPLETE` (MESSAGE_SPEC §5.2). `placeElem` and `reserveElem` call it
/// for the placement itself.
pub inline fn overIndex(comptime b: Bound, id: usize) b.Err()!void {
    switch (b) {
        .schema => |n| if (id >= n) return error.InvalidMessage,
        .receiver => |n| if (id >= n) return error.LimitExceeded,
    }
}

/// The length twin of `overIndex`: an announced element **count**, checked at
/// the count word and before the storage it would size (ARCHITECTURE §9.5 shape
/// A, CORELIB_PLAN §6.2.1).
///
/// A count is the wire's *claim* about how many elements follow, bounded by
/// nothing until a schema `count` or a receiver cap bounds it, so nothing here
/// allocates from a count that has not been through this first. It is `n > m`
/// rather than `n >= m` because this is a length against a capacity, where
/// `overIndex` is an index against one.
inline fn overCount(comptime b: Bound, n: usize) b.Err()!void {
    switch (b) {
        .schema => |m| if (n > m) return error.InvalidMessage,
        .receiver => |m| if (n > m) return error.LimitExceeded,
    }
}

/// Store the next native-array element into a dynamic slice, refusing an element
/// past the announced wire count `n`.
///
/// **The A shape** (SofaBuffers ARCHITECTURE §9.5): a native array's count is on
/// the wire ahead of its payload, so that count is bounded — by `allocCounted`,
/// against the schema `count` (`INVALID`) or the receiver cap (`LimitExceeded`)
/// — and the destination is then allocated at exactly it, once. `n` is that same
/// checked count, so `s` is already `n` long when the first element arrives and
/// the growth below is dead: `i >= n` returns before `i >= s.len` can be true.
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

/// Element capacity of the block backing a `growTo`-owned destination of length
/// `len` — the growth invariant this pair maintains, and the reason neither
/// helper needs a capacity field the generated destination has nowhere to keep.
///
/// **Every block `growTo` allocates holds `ceilPowerOfTwo(n)` elements, and the
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
/// **Private: the bound is not this function's.** Every public entry point
/// bounds the index or the count *before* calling here, so this is the mechanism
/// and never the policy. Out of memory keeps its own channel — `false`, not an
/// error — so a refused index stays distinguishable from a failed allocation.
///
/// **Geometry (CORELIB_PLAN §7.2 item 8).** The block is extended to *at least*
/// `n`, never to exactly `n`: a wrapper array is filled one element at a time
/// (`placeElem`), and reallocating on every element costs O(n²) copies — against
/// the arena of the allocator contract above, which *abandons* the old block
/// rather than freeing it, those copies are the peak memory, not garbage.
/// Doubling makes the total O(n) with O(log n) allocations. The slice handed
/// back is still exactly `n` long, because for a wrapper array that length *is*
/// the decoded value: highest present id + 1 (MESSAGE_SPEC §5.1). The spare
/// capacity lives past its end and is claimed, not reallocated, by the next
/// call — see `capacityFor`.
///
/// **Precondition.** The destination is this function's own: it starts empty
/// (`&.{}`, which generated decode assigns before the array's first element) and
/// is modified only through the wrapper-array helpers from then on. That is what
/// makes `capacityFor` true of it. A slice from elsewhere — `allocCounted`, a
/// literal — belongs to the count-prefixed shape, which is allocated at its
/// checked count once and never grown; the two shapes never mix (SofaBuffers
/// ARCHITECTURE §9.5).
fn growTo(comptime T: type, a: std.mem.Allocator, s: *[]const T, n: usize, fill: T) bool {
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

/// Allocate a zeroed destination of exactly `n` elements.
///
/// **Private: the bound is not this function's.** `n` has been through
/// `overCount` at the count word before it reaches here (`allocCounted`,
/// `reserveRow`). On allocation failure the array decodes as empty, which keeps
/// out of memory distinguishable from a refused count.
fn allocExact(comptime T: type, a: std.mem.Allocator, n: usize) []const T {
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
/// `@constCast` that `putGrowing`, `putChecked` and `placeElem` already end in,
/// exposed for the stores that do not go through one of them.
///
/// Composes, which is why it is a pointer helper rather than a set of
/// purpose-shaped ones: a decode path into a nested row reaches its leaf as
/// `at(at(rows, i).*, j)`, and a struct element's field as `at(rows, i).x`.
///
/// The element id IS the array index (MESSAGE_SPEC §5.1), so a caller reserves
/// the slot through one of the helpers below — which grows the destination to
/// id + 1, default-filling the gaps left by elements a conformant encoder
/// omitted (§2) — and every child store then lands HERE, at that index.
/// Appending instead would shorten the array by the size of any interior gap,
/// and would decode a REOPENED element id as a second element rather than
/// merging into the first (§7.4).
pub fn at(s: anytype, i: usize) *std.meta.Elem(@TypeOf(s)) {
    return @constCast(&s[i]);
}

/// **(1) Place a leaf element** — a wrapper-array `string` or `blob` — at its
/// wire id (= array index), growing the destination and filling the id gaps
/// omitted default elements left (MESSAGE_SPEC §5.1, §2).
///
/// `bound` is the array's **count** bound and is decided before any growth. An
/// element's own `maxlen` is not this call's business — see the module note: the
/// payload arrives through the visitor's own callback and is bounded there, at
/// the length word, before it is handed to `v`.
///
/// Growth is `growTo`'s: the destination ends up exactly `id + 1` long while the
/// block behind it doubles, so filling an array element by element costs O(n)
/// copies rather than O(n²). A failed allocation drops the element rather than
/// writing out of range, and keeps its own channel — it is not an error, so out
/// of memory and a refused index stay distinguishable.
pub inline fn placeElem(
    comptime T: type,
    comptime bound: Bound,
    a: std.mem.Allocator,
    s: *[]const T,
    id: usize,
    fill: T,
    v: T,
) bound.Err()!void {
    try overIndex(bound, id);
    if (!growTo(T, a, s, id + 1, fill)) return;
    @constCast(&s.*[id]).* = v;
}

/// **(2) Reserve a framed element** — the slot a wrapper-array `struct`, `union`
/// or nested-array element will be routed into: bound the index, then grow to
/// `id + 1` filling the gaps with `fill` (MESSAGE_SPEC §5.1, §2).
///
/// Returns false **only** when the allocation failed, so the caller can drop the
/// subtree; a refused index is the error instead, and leaves the container
/// unextended.
///
/// This helper owns growth and the bound, and stops at the slot. It does not own
/// the child's field routing — binding the element index, descending into the
/// element scope, resetting a re-opened wrapper row (§7.4) — which has a
/// different shape per schema and stays generated (ARCHITECTURE §8).
pub inline fn reserveElem(
    comptime T: type,
    comptime bound: Bound,
    a: std.mem.Allocator,
    s: *[]const T,
    id: usize,
    fill: T,
) bound.Err()!bool {
    try overIndex(bound, id);
    return growTo(T, a, s, id + 1, fill);
}

/// **(3) Reserve a matrix row** — row `id` of an array whose elements are
/// themselves native arrays — and size it to its announced element `count`
/// (ARCHITECTURE §9.5: the row's count is on the wire ahead of its payload, so
/// it is bounded and then allocated exactly, once).
///
/// **The order is normative.** The row INDEX is bounded before the row's own
/// count is ever looked at, and both before anything is sized — so a refused row
/// neither measures nor allocates the row it would have held, and the outer
/// array is not left partially extended (CORELIB_PLAN §7.2 item 8).
///
/// `idx` bounds the **outer** array, `cnt` the row's own length; the two are
/// separate arguments because they can be governed by different rules — an inner
/// array the schema bounds inside an outer one it does not. Their error sets are
/// merged, so a caller that mixes the categories handles both and one that does
/// not handles one.
///
/// Returns `void`: an allocation failure leaves the row empty (or the outer
/// array short), which the caller's own bounded element store absorbs exactly as
/// it absorbs a short destination anywhere else.
pub inline fn reserveRow(
    comptime T: type,
    comptime idx: Bound,
    comptime cnt: Bound,
    a: std.mem.Allocator,
    s: *[]const []const T,
    id: usize,
    count: usize,
) (idx.Err() || cnt.Err())!void {
    try overIndex(idx, id);
    try overCount(cnt, count);
    if (!growTo([]const T, a, s, id + 1, &.{})) return;
    at(s.*, id).* = allocExact(T, a, count);
}

/// Allocate a **native** array's destination at exactly its announced count,
/// bounded first (ARCHITECTURE §9.5 shape A).
///
/// `n` is the array's wire count, read from its header and otherwise bounded
/// only by the format ceiling — a ~10-byte message can claim `2^31` elements —
/// so the comparison runs **before** the allocation it exists to prevent, which
/// is the point of it sitting here rather than after the call.
///
/// **Out of memory is a different outcome and keeps its own channel**: a failed
/// allocation yields the empty slice, so the caller can always tell "the count
/// was refused" (an error) from "the allocator had no room" (an empty array) —
/// the one distinction a bound on an allocating helper must not lose. A refused
/// count is never a shortened array (§6.2.1: rejected, never clamped).
pub inline fn allocCounted(
    comptime T: type,
    comptime bound: Bound,
    a: std.mem.Allocator,
    n: usize,
) bound.Err()![]const T {
    try overCount(bound, n);
    return allocExact(T, a, n);
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

// --- the index rule, once, for both verdicts (§6.2.1) -----------------------

test "overIndex: a schema count is a capacity, so id >= count is INVALID" {
    // `count: 4` admits ids 0..3 — the container starts empty and the wire
    // carries the length (MESSAGE_SPEC §3, §7.1).
    try overIndex(.{ .schema = 4 }, 0);
    try overIndex(.{ .schema = 4 }, 3);
    try std.testing.expectError(error.InvalidMessage, overIndex(.{ .schema = 4 }, 4));
}

test "overIndex: an unbounded array's cap breach is LimitExceeded, not INVALID" {
    // The same comparison, the other verdict: the bytes are well formed and
    // would decode under a looser cap, so this is policy (§6.3), and a port
    // that answered InvalidMessage here would read as a wire divergence.
    try overIndex(.{ .receiver = 4 }, 3);
    try std.testing.expectError(error.LimitExceeded, overIndex(.{ .receiver = 4 }, 4));
}

test "Bound.Err narrows to the one verdict its bound can produce" {
    // A schema-bounded call site handles no LimitExceeded, and vice versa --
    // what the withdrawn capped/uncapped name split used to buy.
    try std.testing.expect(Bound.Err(.{ .schema = 1 }) == error{InvalidMessage});
    try std.testing.expect(Bound.Err(.{ .receiver = 1 }) == error{LimitExceeded});
}

test "the bound folds at comptime: the whole check is constant-evaluable" {
    // The reason the bound can move here at no cost (ARCHITECTURE §8's maxspeed
    // override): `bound` is comptime, so the switch is resolved during
    // compilation and `overIndex(.{ .schema = 5 }, id)` lowers to the same
    // comparison against the same constant an emitted `if (id >= 5)` produced.
    const admitted = comptime blk: {
        overIndex(.{ .schema = 5 }, 4) catch break :blk false;
        break :blk true;
    };
    const refused = comptime blk: {
        overIndex(.{ .schema = 5 }, 5) catch break :blk true;
        break :blk false;
    };
    try std.testing.expect(admitted);
    try std.testing.expect(refused);
}

// --- (1) place a leaf element ----------------------------------------------

test "placeElem fills the gaps left by omitted interior elements" {
    // §5.1/§2: an interior element equal to the element default may be omitted,
    // so a gap in the ids is a default element and not a shift.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const []const u8 = &.{};
    try placeElem([]const u8, .{ .schema = 8 }, a, &s, 0, "", "zero");
    try placeElem([]const u8, .{ .schema = 8 }, a, &s, 3, "", "three");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("zero", s[0]);
    try std.testing.expectEqualStrings("", s[1]);
    try std.testing.expectEqualStrings("", s[2]);
    try std.testing.expectEqualStrings("three", s[3]);

    // A lower id delivered afterwards lands in its own slot; a repeated id
    // replaces rather than appending (§7.4).
    try placeElem([]const u8, .{ .schema = 8 }, a, &s, 1, "", "one");
    try placeElem([]const u8, .{ .schema = 8 }, a, &s, 3, "", "THREE");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("one", s[1]);
    try std.testing.expectEqualStrings("THREE", s[3]);
}

test "placeElem: the id at the bound lands, the id past it is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const u32 = &.{};
    try placeElem(u32, .{ .schema = 4 }, a, &s, 3, 0, 7); // the last legal id
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectError(
        error.InvalidMessage,
        placeElem(u32, .{ .schema = 4 }, a, &s, 4, 0, 9),
    );
}

test "placeElem: a rejected id leaves the container unextended (§7.2 item 8)" {
    // The property the order buys: the check runs before any growth, so a lower
    // id delivered after the refusal still lands where it belongs.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const u32 = &.{};
    try placeElem(u32, .{ .schema = 4 }, a, &s, 1, 0, 11);
    try std.testing.expectEqual(@as(usize, 2), s.len);

    try std.testing.expectError(
        error.InvalidMessage,
        placeElem(u32, .{ .schema = 4 }, a, &s, 4, 0, 99),
    );
    try std.testing.expectEqual(@as(usize, 2), s.len); // not partially extended

    try placeElem(u32, .{ .schema = 4 }, a, &s, 0, 0, 10);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(@as(u32, 10), s[0]);
    try std.testing.expectEqual(@as(u32, 11), s[1]);
}

test "placeElem: an id past the receiver cap is LimitExceeded, not INVALID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const []const u8 = &.{};
    try placeElem([]const u8, .{ .receiver = 4 }, a, &s, 3, "", "d");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("d", s[3]);
    try std.testing.expectEqualStrings("", s[0]); // the gap keeps the fill

    try std.testing.expectError(
        error.LimitExceeded,
        placeElem([]const u8, .{ .receiver = 4 }, a, &s, 4, "", "e"),
    );
    try std.testing.expectEqual(@as(usize, 4), s.len);
}

test "placeElem refuses a huge index without forming id + 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: []const u32 = &.{};
    try std.testing.expectError(
        error.LimitExceeded,
        placeElem(u32, .{ .receiver = 65536 }, arena.allocator(), &s, std.math.maxInt(usize), 0, 7),
    );
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

// --- (2) reserve a framed element ------------------------------------------

test "reserveElem grows to the slot and fills the gaps with the element default" {
    const Element = struct { value: u64 = 0 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const Element = &.{};
    try std.testing.expect(try reserveElem(Element, .{ .schema = 4 }, a, &s, 2, .{}));
    try std.testing.expectEqual(@as(usize, 3), s.len);
    at(s, 2).value = 42;
    // The gap is the element default, not a shifted neighbour.
    try std.testing.expectEqual(@as(u64, 0), s[0].value);
    try std.testing.expectEqual(@as(u64, 0), s[1].value);
    try std.testing.expectEqual(@as(u64, 42), s[2].value);

    // A re-opened element id continues the element already there (§7.4's merge
    // half): the slot is the same one, so the routing that follows writes on it.
    try std.testing.expect(try reserveElem(Element, .{ .schema = 4 }, a, &s, 2, .{}));
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u64, 42), s[2].value);
}

test "reserveElem: an id past the bound is refused and extends nothing" {
    const Element = struct { value: u64 = 0 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const Element = &.{};
    try std.testing.expect(try reserveElem(Element, .{ .schema = 3 }, a, &s, 2, .{}));
    try std.testing.expectError(
        error.InvalidMessage,
        reserveElem(Element, .{ .schema = 3 }, a, &s, 3, .{}),
    );
    try std.testing.expectEqual(@as(usize, 3), s.len);

    // The unbounded flavour, same shape, the other verdict.
    var u: []const Element = &.{};
    try std.testing.expect(try reserveElem(Element, .{ .receiver = 3 }, a, &u, 2, .{}));
    try std.testing.expectError(
        error.LimitExceeded,
        reserveElem(Element, .{ .receiver = 3 }, a, &u, 3, .{}),
    );
    try std.testing.expectEqual(@as(usize, 3), u.len);
}

test "reserveElem: a failed allocation is false, never an error" {
    // The one distinction a bound on an allocating helper must not lose: out of
    // memory keeps its own channel, so the caller drops the subtree without
    // reporting a refusal that never happened.
    const Element = struct { value: u64 = 0 };
    var pool: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);

    var s: []const Element = &.{};
    try std.testing.expect(!try reserveElem(Element, .{ .schema = 4 }, fba.allocator(), &s, 0, .{}));
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

// --- (3) reserve a matrix row ----------------------------------------------

test "reserveRow sizes the row at its announced count, index bounded first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows: []const []const u32 = &.{};
    try reserveRow(u32, .{ .schema = 2 }, .{ .schema = 4 }, a, &rows, 1, 3);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 0), rows[0].len); // the gap is an empty row
    try std.testing.expectEqual(@as(usize, 3), rows[1].len);
    at(rows[1], 0).* = 5;
    try std.testing.expectEqual(@as(u32, 5), rows[1][0]);
}

test "reserveRow: the row index is refused before the row's count is looked at" {
    // ORDER IS NORMATIVE. With a cap on the index and a schema count on the row,
    // a breach of both must be reported as the INDEX's category -- and the row
    // that is not going to exist must not be measured or allocated.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows: []const []const u32 = &.{};
    try std.testing.expectError(
        error.LimitExceeded,
        reserveRow(u32, .{ .receiver = 2 }, .{ .schema = 4 }, a, &rows, 2, 9),
    );
    try std.testing.expectEqual(@as(usize, 0), rows.len);

    // A legal index with an over-count row: now the count's verdict, and the
    // outer array is still not extended.
    try std.testing.expectError(
        error.InvalidMessage,
        reserveRow(u32, .{ .receiver = 2 }, .{ .schema = 4 }, a, &rows, 1, 5),
    );
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "reserveRow: a rejected row leaves the outer array usable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows: []const []const u32 = &.{};
    try reserveRow(u32, .{ .schema = 4 }, .{ .schema = 4 }, a, &rows, 2, 1);
    try std.testing.expectError(
        error.InvalidMessage,
        reserveRow(u32, .{ .schema = 4 }, .{ .schema = 4 }, a, &rows, 4, 1),
    );
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try reserveRow(u32, .{ .schema = 4 }, .{ .schema = 4 }, a, &rows, 0, 2);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].len);
}

// --- the A shape: a bounded count, allocated exactly, once -------------------

test "allocCounted yields exactly n zeroed elements" {
    const s = try allocCounted(u32, .{ .schema = 8 }, std.testing.allocator, 3);
    defer std.testing.allocator.free(@constCast(s));
    try std.testing.expectEqual(@as(usize, 3), s.len);
    for (s) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "allocCounted: a count is a length against a capacity, so n == bound fits" {
    const a = std.testing.allocator;
    const at_bound = try allocCounted(u32, .{ .receiver = 64 }, a, 64);
    defer a.free(@constCast(at_bound));
    try std.testing.expectEqual(@as(usize, 64), at_bound.len);
    try std.testing.expectError(error.LimitExceeded, allocCounted(u32, .{ .receiver = 64 }, a, 65));
    try std.testing.expectError(error.InvalidMessage, allocCounted(u32, .{ .schema = 64 }, a, 65));
}

test "allocCounted refuses before it allocates anything" {
    // A pool with no room at all: reaching the allocator is observable as an
    // empty result, so an over-bound count that errors instead proves the check
    // ran ahead of the allocation it exists to prevent.
    var pool: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const a = fba.allocator();
    try std.testing.expectError(error.LimitExceeded, allocCounted(u32, .{ .receiver = 64 }, a, 65));
    // …and within the bound, out of memory keeps its own channel.
    const oom = try allocCounted(u32, .{ .receiver = 64 }, a, 4);
    try std.testing.expectEqual(@as(usize, 0), oom.len);
}

test "a refused count is an error, never a shortened array" {
    // §6.2.1 "Rejected, never clamped": the caller must not be handed `bound`
    // elements where the wire said more.
    const a = std.testing.allocator;
    try std.testing.expectError(error.LimitExceeded, allocCounted(u32, .{ .receiver = 8 }, a, 1_000_000));
}

test "the bound is the caller's, per call: nothing is retained between them" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.LimitExceeded, allocCounted(u32, .{ .receiver = 4 }, a, 8));
    const wider = try allocCounted(u32, .{ .receiver = 16 }, a, 8); // the earlier 4 binds nothing
    defer a.free(@constCast(wider));
    try std.testing.expectEqual(@as(usize, 8), wider.len);
}

test "the A shape allocates once: allocCounted, then no store ever grows" {
    // What generated code does since generator#396: the count is bounded first,
    // the destination is allocated at exactly it, and the stores fill it. A pool
    // with room for that one allocation and nothing more proves the growth
    // branch is never reached — a second allocation could not come out of it.
    const n: usize = 64;
    var pool: [n * @sizeOf(u32) + 32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pool);
    const a = fba.allocator();

    var s = try allocCounted(u32, .{ .schema = n }, a, n);
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
