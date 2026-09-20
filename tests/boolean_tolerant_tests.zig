//! The shared `boolean_tolerant` cases (CORELIB_PLAN §4.4).
//!
//! **Canonical on encode, tolerant on decode.** An encoder MUST write `true` as
//! `1`; a decoder MUST read *every* value other than `0` as `true` — such a
//! value is not INVALID (§5.2), it is normalized away, and a re-encode emits
//! `1`. A boolean is therefore **not** bound the way an `enum` or a `bitfield`
//! is (MESSAGE_SPEC §1): those carry the width their declaration implies and a
//! value outside it *is* INVALID, while a boolean carries no width bound at all.
//!
//! ```text
//! 00 80 02
//! ^^ id 0, wire type 0 (unsigned varint) — a boolean has no wire type of its own
//!    ^^^^^ varint 256 … which is `true`, not INVALID and not a truncation to `false`
//! ```
//!
//! The positive `vectors` array cannot reach this half of §4.4: its bytes come
//! from replaying `fields` ops through a conforming encoder, and a conforming
//! encoder never emits a non-canonical boolean. Bytes carrying `2`, `256` or
//! `2^64-1` at a boolean position only ever arrive from *someone else's*
//! encoder — hence a separate, hand-authored block.
//!
//! **Three defects, three assertions.** Each case is decoded *and* re-encoded,
//! because no single check sees all three ways a port can violate §4.4:
//!
//! | the defect | what catches it |
//! |---|---|
//! | answers INVALID for `256` (a boolean read as a bounded type) | the verdict |
//! | masks the varint to the destination width before the zero test, so `256` becomes `false` | the stored representation |
//! | stores the raw `2` without normalizing | the re-encode — it emits `2` where §4.4 demands `1` |
//!
//! The middle one is the dangerous one: the outcome is `complete` and a
//! truthiness check says "true", so only the *bytes of the destination* expose
//! it. The last one survives both the verdict and a truthiness check, and only
//! the re-encode shows it.
//!
//! **Where this port answers.** The Zig corelib has no boolean read callback:
//! §4.4 assigns the boolean surface to the pair `unsigned` (in) /
//! `writeBoolean` (out), and a boolean array rides the unsigned-varint array
//! wire type, so its elements arrive through the same `unsigned` callback
//! behind an `arrayBegin`. What the corelib owes is the **whole** value,
//! unnarrowed (`Unsigned = u64`, on every target); the normalization to `0`/`1`
//! is the generated layer's, and `Receiver` below is exactly the shape
//! generated code emits for a boolean field. The write side is the corelib's
//! again: `writeBoolean` maps `false`/`true` onto the canonical `0`/`1`, and
//! `writeArrayUnsigned` carries the normalized elements (this port has no
//! boolean-array writer — the declared element width never reaches the wire,
//! §4.7).
//!
//! **Read back as bytes, never as a `bool`.** A Zig `bool` object may only hold
//! the representations of `false` and `true`; one holding `2` has no value and
//! loading it is illegal, so comparing it against `true` could not tell us
//! whether anything was normalized. The destination is therefore poisoned with
//! a byte that is neither (`0xAA`), and read back through a byte view: what is
//! asserted is that the object ends up holding a representation it is *allowed*
//! to have. Only once those bytes check out is the destination read as `bool`
//! to drive the re-encode.
//!
//! **`requires` means REJECT here, not skip** — the rule a *vector* gets, not
//! the one `header_limits` gets. §4.4 lifts the width bound the **type**
//! carries, never the one a **build** has: §6.2.2 lists a 32-bit scalar value
//! width as a permitted profile variation, and §6.2 makes a varint that does
//! not fit the built width INVALID (§5.2.2). Skipping such a case would assert
//! nothing at all in exactly the build most likely to truncate. This build
//! compiles the whole format in and its scalar width is 64-bit unconditionally,
//! so every tag is satisfied, all eight cases run positively and the reject
//! path is unreachable — it is implemented anyway, so that a port profile added
//! later grades itself instead of needing this file rewritten.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const vectors_json = @embedFile("test_vectors");

// ---------------------------------------------------------------------------
// capability gating
// ---------------------------------------------------------------------------

/// The shared vector README's tag set. Only `array` and `int64` appear in this
/// block today; the rest are listed so a case that grows a tag resolves instead
/// of stopping the suite.
///
/// An unrecognised tag panics rather than being ignored — this repo's standing
/// rule for every shared block (`vectors_tests.zig`, `header_limits_tests.zig`).
/// It is stricter than the corpus's forward-compatibility note, and
/// deliberately so: here an unknown tag decides between *running* a case and
/// *rejecting* its bytes, and guessing that wrong is a silent false green.
const Capability = enum {
    /// fp32/fp64/string/blob, or a fixed-length array.
    fixlen,
    /// any array field.
    array,
    /// a nested sequence.
    sequence,
    /// a 64-bit float (implies `fixlen`).
    fp64,
    /// a value, element or id outside the 32-bit range.
    int64,

    fn parse(tag: []const u8) Capability {
        return std.meta.stringToEnum(Capability, tag) orelse {
            std.debug.print("unknown `requires` capability tag: {s}\n", .{tag});
            @panic("teach this suite the capability tag rather than ignoring it");
        };
    }

    /// Whether *this* build can represent the capability. Every arm is `true`:
    /// this port compiles the whole wire format in and its scalar value width
    /// is 64-bit on every target (`types.Unsigned = u64`), so the capability set
    /// is complete. A build option that narrows either flips its arm, and the
    /// gate below then turns the affected cases into rejections.
    fn supported(self: Capability) bool {
        return switch (self) {
            .fixlen, .array, .sequence, .fp64, .int64 => true,
        };
    }
};

/// True when the case asks for something this build cannot represent — in which
/// case its bytes must be **rejected**, not skipped (§7 of the block's rules).
fn mustReject(case: std.json.Value) bool {
    const reqs = get(case, "requires") orelse return false;
    for (reqs.array.items) |r| {
        if (!Capability.parse(r.string).supported()) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// the receiver — generated decode's shape for a boolean field
// ---------------------------------------------------------------------------

/// The byte a destination slot holds before the decode. Neither `false` nor
/// `true`, so a decoder that never writes the slot fails the value check
/// instead of matching a zero-initialized buffer's `false` (case
/// `boolean_tolerant_zero` is the one that would otherwise pass for free).
const poison: u8 = 0xAA;

/// A `[]bool` seen as the bytes it occupies. The only legal way to look at a
/// destination that may hold a representation `bool` does not admit.
fn byteView(dst: []bool) []u8 {
    return @as([*]u8, @ptrCast(dst.ptr))[0..dst.len];
}

/// The visitor generated code emits for a boolean field: an id test, then the
/// §4.4 normalization — `value != 0`, applied to the **whole** 64-bit value the
/// corelib delivered. Narrowing it first is precisely the truncation this block
/// exists to catch, so nothing here casts.
///
/// `arrayBegin` has to be declared even though it stores only bookkeeping: this
/// port dispatches by `@hasDecl`, so a visitor without it makes the decoder skip
/// the whole array and cases 7/8 would deliver no elements at all.
const Receiver = struct {
    field_id: sofab.Id,
    /// The decode destination, poisoned before the feed. Written through the
    /// `bool` type, read back through `byteView`.
    dst: []bool,
    /// How many elements arrived.
    next: usize = 0,
    /// The element count the wire announced, and the element category with it —
    /// `null` when no array header reached us (every scalar case).
    announced: ?usize = null,
    kind: ?sofab.ArrayKind = null,
    /// Set when more values arrived than the case's `expect.values` has slots.
    /// Recorded rather than asserted here: an assertion raised inside a decoder
    /// callback can be absorbed by the decoder or leave the stream in a state
    /// that masks the failure, so every verdict is passed out and checked after
    /// `feed` returns.
    overflow: bool = false,

    pub fn unsigned(self: *Receiver, id: sofab.Id, value: u64) void {
        if (id != self.field_id) return;
        if (self.next == self.dst.len) {
            self.overflow = true;
            return;
        }
        self.dst[self.next] = value != 0;
        self.next += 1;
    }

    pub fn arrayBegin(self: *Receiver, id: sofab.Id, kind: sofab.ArrayKind, count: usize) void {
        if (id != self.field_id) return;
        self.announced = count;
        self.kind = kind;
    }
};

// ---------------------------------------------------------------------------
// case plumbing
// ---------------------------------------------------------------------------

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return v.object.get(key);
}

fn parseCases(arena: std.mem.Allocator) []const std.json.Value {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, vectors_json, .{}) catch
        @panic("failed to parse test_vectors.json");
    const block = doc.object.get("boolean_tolerant") orelse return &.{};
    return block.array.items;
}

/// The outcomes a case can state. Every case in the block today says
/// `complete` — a *tolerated* value is not a *rejected* one — but the key is
/// read rather than assumed, so a future case cannot be silently mis-run.
const Outcome = enum {
    complete,
    incomplete,
    invalid,

    fn parse(s: []const u8) Outcome {
        return std.meta.stringToEnum(Outcome, s) orelse {
            std.debug.print("unknown expect.outcome: {s}\n", .{s});
            @panic("teach this suite the outcome rather than passing the case");
        };
    }
};

/// How the bytes reach the decoder. This port has two decode implementations —
/// the contiguous fast path and the resumable one — and case 6/8's ten-byte
/// varints are exactly the shape a carry buffer gets wrong, so both are run,
/// the streaming one also a byte at a time.
const Feed = enum { one_shot, whole, chunked };

/// Every fixed buffer this suite encodes into. The longest re-encode in the
/// block is seven bytes; a case that outgrows this fails loudly here rather
/// than through a byte comparison that reads as a conformance failure.
const buffer_bytes: usize = 64;

fn fieldId(case: std.json.Value) sofab.Id {
    // Read from the case, never hardcoded: every case carries `id: 0` today,
    // and a runner that assumes it would write the re-encode at the wrong id
    // the moment the block grows a case with another.
    const raw = get(case, "id").?.integer;
    if (raw < 0 or raw > sofab.ID_MAX) @panic("boolean_tolerant case carries an id this port cannot hold");
    return @intCast(raw);
}

// ---------------------------------------------------------------------------
// the positive path: decode, then re-encode what the decode produced
// ---------------------------------------------------------------------------

/// Run one case whose `requires` this build satisfies. Returns the number of
/// assertions made, for the run report.
fn runPositive(arena: std.mem.Allocator, case: std.json.Value, how: Feed) !usize {
    const expect = get(case, "expect").?;
    // §4.4 tolerates, it does not reject: anything but `complete` here is a
    // case this runner was not written for.
    try std.testing.expectEqual(Outcome.complete, Outcome.parse(get(expect, "outcome").?.string));

    const id = fieldId(case);
    const values = get(expect, "values").?.array.items;
    const bytes = common.hexToBytes(arena, get(case, "serialized_hex").?.string);
    const want_bytes = common.hexToBytes(arena, get(expect, "reencoded_hex").?.string);
    if (want_bytes.len > buffer_bytes) @panic("a boolean_tolerant re-encode outgrew the buffer — raise it");

    // --- A. decode ---------------------------------------------------------
    const dst = arena.alloc(bool, values.len) catch @panic("oom");
    @memset(byteView(dst), poison);

    var r: Receiver = .{ .field_id = id, .dst = dst };
    const st = switch (how) {
        .one_shot => try sofab.decode(bytes, &r),
        .whole => blk: {
            var is = sofab.IStream.init();
            break :blk try is.feed(bytes, &r);
        },
        .chunked => blk: {
            var is = sofab.IStream.init();
            // A decoder fed nothing sits at a field boundary; the loop below
            // overwrites this for every non-empty case.
            var last: sofab.Status = .complete;
            for (bytes) |b| last = try is.feed(&.{b}, &r);
            break :blk last;
        },
    };
    try std.testing.expectEqual(sofab.Status.complete, st);

    // Exactly as many values as the wire carries — no more (a decoder that
    // replayed elements) and no fewer (one that stopped early).
    try std.testing.expect(!r.overflow);
    try std.testing.expectEqual(values.len, r.next);
    if (values.len > 1) {
        // The count word cross-check: a decoder that delivers fewer elements
        // than it announced is a defect this catches for free.
        try std.testing.expectEqual(@as(?usize, values.len), r.announced);
        try std.testing.expectEqual(@as(?sofab.ArrayKind, .unsigned), r.kind);
    } else {
        try std.testing.expectEqual(@as(?usize, null), r.announced);
    }

    // The stored *representation*, not a truthiness test: a slot holding `2`
    // would satisfy every "is it true?" check in the language, and a slot the
    // decoder never touched still holds `poison`.
    const raw = byteView(dst);
    for (values, raw, 0..) |v, got, i| {
        const want: u8 = @intFromBool(v.bool);
        if (got != want) {
            std.debug.print(
                "element {d}: destination byte is 0x{x:0>2}, expected 0x{x:0>2} ({})\n",
                .{ i, got, want, v.bool },
            );
            return error.TestUnexpectedResult;
        }
    }

    // --- B. re-encode ------------------------------------------------------
    // From the decode destination, never from `expect.values`: re-encoding the
    // expectation would match `reencoded_hex` trivially and leave the whole
    // decode half unverified. Reading `dst` as `bool` is legal only because the
    // byte check above established it holds a representation `bool` admits.
    var buf: [buffer_bytes]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    if (dst.len == 1) {
        try os.writeBoolean(id, dst[0]);
    } else {
        // No boolean-array writer in this port; §4.7 makes the element width an
        // API concern that never reaches the wire, so the narrowest one will do.
        const elems = arena.alloc(u8, dst.len) catch @panic("oom");
        for (dst, elems) |b, *e| e.* = @intFromBool(b);
        try os.writeArrayUnsigned(id, elems);
    }
    // Compared against `reencoded_hex`, whole. For cases 1 and 2 it equals
    // `serialized_hex`; for the other six it does not, and that difference is
    // the test — as is comparing the bytes rather than their length, `0002` and
    // `0001` being the same size.
    try std.testing.expectEqualSlices(u8, want_bytes, buf[0..os.bytesUsed()]);

    return 2;
}

// ---------------------------------------------------------------------------
// the reject path: a tag this build does not satisfy
// ---------------------------------------------------------------------------

/// Run one case whose `requires` this build does **not** satisfy: its bytes
/// carry a construct or a width this build cannot represent, so the conformant
/// answer is INVALID (§5.2.2) — not a receiver-cap refusal, which is §6.2.1's
/// tier for well-formed bytes a policy declines, and not a skip.
///
/// Unreachable in this build (`Capability.supported` is `true` throughout) and
/// kept compiled so a narrowed profile grades itself here rather than silently
/// testing nothing.
fn runRejected(arena: std.mem.Allocator, case: std.json.Value) !usize {
    const bytes = common.hexToBytes(arena, get(case, "serialized_hex").?.string);
    // Binds nothing: what is asserted is the verdict, not what arrived first.
    var r: Receiver = .{ .field_id = fieldId(case), .dst = &.{} };
    var is = sofab.IStream.init();

    if (is.feed(bytes, &r)) |st| {
        std.debug.print("a case this build cannot represent was accepted: {s}\n", .{@tagName(st)});
        return error.TestExpectedInvalidMessage;
    } else |e| {
        try std.testing.expectEqual(sofab.Error.InvalidMessage, e);
    }

    // Terminal: a verdict a later feed lifts is a conformance defect of its own.
    if (is.feed(&[_]u8{0x00}, &r)) |st| {
        std.debug.print("a terminal rejection consumed a further feed: {s}\n", .{@tagName(st)});
        return error.TestExpectedTerminalVerdict;
    } else |e| {
        try std.testing.expectEqual(sofab.Error.InvalidMessage, e);
    }

    return 1;
}

// ---------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------

test "the boolean_tolerant block is present and every case is well formed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = parseCases(arena_state.allocator());

    // A floor, not an equality: the block may grow upstream. Zero cases means
    // the asset copy went stale — a runner against a pre-§4.4 `test_vectors.json`
    // iterates nothing and passes, which is the failure mode this guards.
    try std.testing.expect(cases.len >= 8);

    var scalars: usize = 0;
    var arrays: usize = 0;
    for (cases) |c| {
        const expect = get(c, "expect").?;
        try std.testing.expectEqual(Outcome.complete, Outcome.parse(get(expect, "outcome").?.string));
        // Every tag resolves; an unknown one stops the suite rather than
        // deciding "run it" by default.
        _ = mustReject(c);
        _ = fieldId(c);
        const n = get(expect, "values").?.array.items.len;
        try std.testing.expect(n > 0);
        // Hand-authored, decode-then-re-encode only: no `fields` op list and no
        // sparse column here.
        try std.testing.expect(get(c, "fields") == null);
        try std.testing.expect(get(expect, "reencoded_hex") != null);
        if (n == 1) scalars += 1 else arrays += 1;
    }
    // Both halves of the rule are present: the scalar surface and the element
    // one. A runner filtering on `len(values) == 1` would lose the second.
    try std.testing.expect(scalars >= 6);
    try std.testing.expect(arrays >= 2);
}

test "the block carries the value that separates a wide read from a truncated one" {
    // `255` and `256` sit one step apart on purpose: a decoder that masks the
    // accumulated varint to a byte before testing it against zero passes the
    // first and turns the second into `false` while still answering `complete`.
    // Asserted here on its own, because a copy of the block that lost either
    // one would pass every case below.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = parseCases(arena_state.allocator());

    var seen_255 = false;
    var seen_256 = false;
    for (cases) |c| {
        const name = get(c, "name").?.string;
        if (std.mem.eql(u8, name, "boolean_tolerant_255")) seen_255 = true;
        if (std.mem.eql(u8, name, "boolean_tolerant_256")) seen_256 = true;
    }
    try std.testing.expect(seen_255);
    try std.testing.expect(seen_256);
}

test "every boolean_tolerant case decodes normalized and re-encodes canonical (§4.4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var decoded: usize = 0;
    var rejected: usize = 0;
    var checks: usize = 0;
    for (cases) |case| {
        const name = get(case, "name").?.string;
        errdefer std.debug.print("boolean_tolerant case [{s}] failed\n", .{name});
        if (mustReject(case)) {
            checks += try runRejected(arena, case);
            rejected += 1;
            continue;
        }
        for ([_]Feed{ .one_shot, .whole, .chunked }) |how| {
            errdefer std.debug.print("  … on the {s} feed\n", .{@tagName(how)});
            checks += try runPositive(arena, case, how);
        }
        decoded += 1;
    }

    // `found == decoded + rejected`: no third bucket exists here, a gated-out
    // case being a negative case rather than an inapplicable one.
    try std.testing.expectEqual(cases.len, decoded + rejected);
    std.debug.print(
        "\n[boolean_tolerant] {d} cases found, {d} decoded, {d} rejected by `requires`, {d} checks\n",
        .{ cases.len, decoded, rejected, checks },
    );
}
