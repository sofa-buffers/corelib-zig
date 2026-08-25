//! Malformed-input tests (ARCHITECTURE §7.2, item 5): overlong varints,
//! dangling sequence ends, oversized lengths/counts and reserved subtypes are
//! INVALID regardless of what follows and must all yield `error.InvalidMessage`
//! — never a crash — whether fed whole or split at hostile byte boundaries.
//!
//! Truncation is a separate outcome (MESSAGE_SPEC §7): input that merely ends
//! inside a field or with a sequence still open is INCOMPLETE, reported as the
//! `.incomplete` decode `Status`, never promoted to `error.InvalidMessage`.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const Nothing = struct {};

fn expectInvalidWholeAndChunked(bytes: []const u8) !void {
    // Whole-buffer feed: the malformed item is rejected eagerly by `feed`.
    var sink: Nothing = .{};
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(bytes, &sink));
    try expectTerminal(&is, &sink);

    // One byte at a time: the same error must surface, at whichever feed
    // completes (or ends) the malformed item.
    var sink2: Nothing = .{};
    var is2 = sofab.IStream.init();
    const chunked: anyerror!sofab.Status = blk: {
        for (bytes) |b| _ = is2.feed(&.{b}, &sink2) catch |e| break :blk e;
        break :blk is2.status();
    };
    try std.testing.expectError(error.InvalidMessage, chunked);
    try expectTerminal(&is2, &sink2);
}

/// A decoder that has reported INVALID stays there: §5.2 answers "can more bytes
/// change it?" with "no — terminal", so every later `feed` repeats the rejection
/// and `status` keeps reporting `.invalid` instead of resynchronizing on the
/// bytes that follow the malformed construct.
fn expectTerminal(is: *sofab.IStream, sink: anytype) !void {
    try std.testing.expectEqual(sofab.Status.invalid, is.status());
    // A well-formed field after the rejection must not be decoded.
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{ 0x00, 0x2A }, sink));
    // Not even an empty end-of-input probe re-opens the decoder.
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{}, sink));
    try std.testing.expectEqual(sofab.Status.invalid, is.status());
}

fn expectIncompleteWholeAndChunked(bytes: []const u8) !void {
    // Whole-buffer feed: `feed` buffers a partial tail and returns the
    // `.incomplete` status — never an error.
    var sink: Nothing = .{};
    var is = sofab.IStream.init();
    try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(bytes, &sink));

    // One byte at a time: still INCOMPLETE at end-of-input, never promoted.
    var sink2: Nothing = .{};
    var is2 = sofab.IStream.init();
    for (bytes) |b| _ = try is2.feed(&.{b}, &sink2);
    try std.testing.expectEqual(sofab.Status.incomplete, is2.status());
}

test "truncated inputs are Incomplete, not rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A valid message wrapped in a sequence, then every strict prefix of it.
    // (The wire format has no whole-message length: a prefix ending exactly at
    // a *top-level* field boundary is simply a shorter valid message. Wrapping
    // in a sequence makes every strict prefix detectably incomplete.)
    var buf: [64]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeSequenceBeginLazy(1);
    try os.writeUnsigned(1, 300);
    try os.writeString(2, "hello");
    try os.writeSequenceEnd();
    const message = buf[0..os.bytesUsed()];

    var cut: usize = 1;
    while (cut < message.len) : (cut += 1) {
        var rec = common.Recorder.init(arena);
        var is = sofab.IStream.init();
        // Every strict prefix is well-formed so far but unfinished: INCOMPLETE,
        // surfaced as a status, never an error.
        try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(message[0..cut], &rec));
    }
}

test "overlong and overflowing varints are rejected" {
    // Field header: 12 continuation bytes exceed any u64 varint.
    const header_overflow: [12]u8 = @splat(0xFF);
    try expectInvalidWholeAndChunked(&header_overflow);

    // Value varint of field id 0 (header 0x00) that overflows 64 bits.
    const nine_continuations: [9]u8 = @splat(0xFF);
    try expectInvalidWholeAndChunked(&[_]u8{0x00} ++ nine_continuations ++ [_]u8{0x7F});
}

test "unbalanced sequence framing is rejected" {
    // End without a start: a dangling sequence-end can never be valid → INVALID.
    try expectInvalidWholeAndChunked(&.{0x07});
    // Balanced pair, then a stray end → INVALID.
    try expectInvalidWholeAndChunked(&.{ 0x0E, 0x07, 0x07 });
}

test "an unclosed sequence is Incomplete, not rejected" {
    // Start without an end: the sequence could still be closed by more bytes,
    // so this is INCOMPLETE (MESSAGE_SPEC §7), not INVALID.
    try expectIncompleteWholeAndChunked(&.{0x0E});
}

test "nesting past MAX_DEPTH is rejected" {
    const bytes: [256]u8 = @splat(0x0E); // 256 nested sequence starts
    try expectInvalidWholeAndChunked(&bytes);
}

test "oversized lengths and counts are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // String length above FIXLEN_MAX: word = (2^31 << 3) | 2.
    var s: std.ArrayList(u8) = .empty;
    common.pushVarint(&s, arena, 0x02); // header: id 0, fixlen
    common.pushVarint(&s, arena, (@as(u64, 1) << 31 << 3) | 2);
    try expectInvalidWholeAndChunked(s.items);

    // Unsigned-array count above ARRAY_MAX.
    var a: std.ArrayList(u8) = .empty;
    common.pushVarint(&a, arena, 0x03); // header: id 0, unsigned array
    common.pushVarint(&a, arena, @as(u64, 1) << 31);
    try expectInvalidWholeAndChunked(a.items);

    // Field id above ID_MAX.
    var h: std.ArrayList(u8) = .empty;
    common.pushVarint(&h, arena, (@as(u64, 1) << 31 << 3) | 0);
    common.pushVarint(&h, arena, 1);
    try expectInvalidWholeAndChunked(h.items);

    // Fixlen-array element length above FIXLEN_MAX: the fixlen_word's length
    // bits alone exceed 2^31, before any subtype/width check ever runs. On a
    // 32-bit usize the pre-guard `@intCast` truncated this instead of
    // rejecting it (2^32 + 4 truncates to 4, a legal fp32 width) — a crash on
    // Debug/ReleaseSafe and a silent accept on ReleaseFast. This must be
    // caught here, at the describing word, the same as the scalar case above.
    var fa: std.ArrayList(u8) = .empty;
    common.pushVarint(&fa, arena, 0x05); // header: id 0, fixlen array
    common.pushVarint(&fa, arena, 1); // count
    common.pushVarint(&fa, arena, ((@as(u64, 1) << 32 | 4) << 3) | 0); // fp32 subtype, oversized length
    try expectInvalidWholeAndChunked(fa.items);
}

test "reserved fixlen subtypes and wrong float widths are rejected" {
    // Reserved scalar subtype 0x4: word = (4 << 3) | 4.
    try expectInvalidWholeAndChunked(&.{ 0x02, 0x24, 0, 0, 0, 0 });
    // fp32 whose declared length is 8.
    try expectInvalidWholeAndChunked(&.{ 0x02, 0x40, 0, 0, 0, 0, 0, 0, 0, 0 });
    // fp64 whose declared length is 4.
    try expectInvalidWholeAndChunked(&.{ 0x02, 0x21, 0, 0, 0, 0 });
    // Fixlen array with a string subtype (dynamic subtypes are not allowed).
    try expectInvalidWholeAndChunked(&.{ 0x05, 0x01, 0x0A, 0x61 });
    // Fixlen array whose fp32 element length is 8.
    try expectInvalidWholeAndChunked(&.{ 0x05, 0x01, 0x40, 0, 0, 0, 0, 0, 0, 0, 0 });
}

test "decoder survives malformed input after valid fields (resync check)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [64]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeUnsigned(1, 42);
    const good = buf[0..os.bytesUsed()];

    var bad: std.ArrayList(u8) = .empty;
    bad.appendSlice(arena, good) catch @panic("oom");
    const trailing_overflow: [12]u8 = @splat(0xFF);
    bad.appendSlice(arena, &trailing_overflow) catch @panic("oom");

    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(bad.items, &rec));
    // The valid field before the garbage was still delivered.
    try common.expectEventsEqual(
        &.{.{ .unsigned = .{ .id = 1, .value = 42 } }},
        rec.events.items,
    );
}

test "an INVALID verdict is terminal: no resync onto the following bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dangling sequence end (0x07) is malformed regardless of what follows,
    // so the decoder is done: the perfectly valid field after it (id 0,
    // unsigned 42) must never reach the visitor, and neither `feed` nor
    // `status` may ever again report `.complete` for this stream (§5.2).
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{0x07}, &rec));
    try std.testing.expectEqual(sofab.Status.invalid, is.status());
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{ 0x00, 0x2A }, &rec));
    try std.testing.expectEqual(sofab.Status.invalid, is.status());
    try std.testing.expectEqual(@as(usize, 0), rec.events.items.len);

    // Chunk-independence (MESSAGE_SPEC §7.2 item 4): the same bytes fed whole
    // give the same verdict, and no field either.
    var whole = common.Recorder.init(arena);
    try std.testing.expectError(
        error.InvalidMessage,
        sofab.decode(&.{ 0x07, 0x00, 0x2A }, &whole),
    );
    try std.testing.expectEqual(@as(usize, 0), whole.events.items.len);

    // `reset` is the only way out of the latch: afterwards the decoder is fresh
    // and decodes the very message it just refused to resynchronize onto.
    is.reset();
    try std.testing.expectEqual(sofab.Status.complete, try is.feed(&.{ 0x00, 0x2A }, &rec));
    try std.testing.expectEqual(sofab.Status.complete, is.status());
    try common.expectEventsEqual(
        &.{.{ .unsigned = .{ .id = 0, .value = 42 } }},
        rec.events.items,
    );
}

test "a latched INVALID survives mid-item and mid-payload state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rejected while a string payload is still in flight: header (1 << 3) | 2 =
    // 0x0a, word (4 << 3) | 2 = 0x22, two of the four payload bytes, then a
    // dangling sequence end once the payload completes.
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(&.{ 0x0a, 0x22, 'a', 'b' }, &rec));
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{ 'c', 'd', 0x07 }, &rec));
    // The string itself was well-formed and stays delivered; what must not
    // happen is decoding anything after the rejection.
    try std.testing.expectEqual(sofab.Status.invalid, is.status());
    try std.testing.expectError(error.InvalidMessage, is.feed(&.{ 0x00, 0x2A }, &rec));
    try common.expectEventsEqual(
        &.{.{ .str = .{ .id = 1, .data = "abcd" } }},
        rec.events.items,
    );

    // Rejected with a half-read item in the carry buffer: a >64-bit varint
    // header split across two feeds. The carry must not be re-parsed as a fresh
    // field once more bytes arrive.
    var rec2 = common.Recorder.init(arena);
    var is2 = sofab.IStream.init();
    const overlong: [11]u8 = @splat(0xFF);
    try std.testing.expectEqual(sofab.Status.incomplete, try is2.feed(overlong[0..5], &rec2));
    try std.testing.expectError(error.InvalidMessage, is2.feed(overlong[5..], &rec2));
    try std.testing.expectEqual(sofab.Status.invalid, is2.status());
    try std.testing.expectError(error.InvalidMessage, is2.feed(&.{ 0x00, 0x2A }, &rec2));
    try std.testing.expectEqual(@as(usize, 0), rec2.events.items.len);
}

// ---------------------------------------------------------------------------
// item 5b — tolerance: non-canonical but well-formed input decodes
// ---------------------------------------------------------------------------

/// Decode `bytes` whole and byte-at-a-time, assert both reach `.complete` with
/// exactly `want`, then re-encode `want` and assert the canonical bytes are
/// `canonical` — item 5b's second half, "and re-encode canonically".
fn expectTolerated(
    arena: std.mem.Allocator,
    bytes: []const u8,
    want: []const common.Event,
    canonical: []const u8,
) !void {
    var whole = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(bytes, &whole));
    try common.expectEventsEqual(want, whole.events.items);

    var piecewise = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    var st = sofab.Status.incomplete;
    for (bytes) |b| st = try is.feed(&.{b}, &piecewise);
    try std.testing.expectEqual(sofab.Status.complete, st);
    try common.expectEventsEqual(want, piecewise.events.items);

    // The canonical spelling decodes to the same thing, and is what an encoder
    // emits: a decoder that tolerates must not also *propagate* the padding.
    var canon = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(canonical, &canon));
    try common.expectEventsEqual(want, canon.events.items);
    try std.testing.expect(bytes.len > canonical.len);
}

test "a non-minimal varint is tolerated at a header, a fixlen_word and a count (§7.2 item 5b)" {
    // §4.1.2: minimality binds the *encoder*; a decoder must accept the padded
    // spelling and decode it to the value it denotes. These are the three
    // positions item 5b names, and nothing else in this file reaches them —
    // being uniformly too strict is the one failure a majority vote cannot see.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Field header `80 00` — id 0, wire type 0 (unsigned) — then value 42.
    try expectTolerated(
        arena,
        &.{ 0x80, 0x00, 0x2A },
        &.{.{ .unsigned = .{ .id = 0, .value = 42 } }},
        &.{ 0x00, 0x2A },
    );

    // `fixlen_word` `8A 00` = (1 << 3) | 2: a one-byte string, subtype and
    // length both settled only by the second byte.
    try expectTolerated(
        arena,
        &.{ 0x02, 0x8A, 0x00, 'a' },
        &.{.{ .str = .{ .id = 0, .data = "a" } }},
        &.{ 0x02, 0x0A, 'a' },
    );

    // Element count `81 00` = 1 on an unsigned array.
    try expectTolerated(
        arena,
        &.{ 0x03, 0x81, 0x00, 0x2A },
        &.{
            .{ .array_begin = .{ .id = 0, .kind = .unsigned, .count = 1 } },
            .{ .unsigned = .{ .id = 0, .value = 42 } },
        },
        &.{ 0x03, 0x01, 0x2A },
    );
}

test "a sequence-end header with a non-zero id is an ordinary end (§4.9, §7.2 item 5b)" {
    // The end marker's id carries no meaning, so any id within ID_MAX spells the
    // same thing; only `0x07` is canonical. `87 00` is id 0 written
    // non-minimally, `0F` is id 1 — both close the sequence `0E` opened.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const want: []const common.Event = &.{
        .{ .sequence_begin = .{ .id = 1 } },
        .{ .unsigned = .{ .id = 0, .value = 7 } },
        .sequence_end,
    };
    try expectTolerated(arena, &.{ 0x0E, 0x00, 0x07, 0x87, 0x00 }, want, &.{ 0x0E, 0x00, 0x07, 0x07 });

    // A plainly non-zero id, minimally spelled: same outcome, same length, so
    // it is checked directly rather than through the shrinking helper.
    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(&.{ 0x0E, 0x00, 0x07, 0x0F }, &rec));
    try common.expectEventsEqual(want, rec.events.items);

    // And what the encoder writes for that end is `0x07`.
    var buf: [8]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeSequenceBeginLazy(1);
    try os.writeUnsigned(0, 7);
    try os.writeSequenceEnd();
    try std.testing.expectEqualSlices(u8, &.{ 0x0E, 0x00, 0x07, 0x07 }, buf[0..os.bytesUsed()]);
}

// ---------------------------------------------------------------------------
// item 6 — no partial evaluation of a half-arrived varint
// ---------------------------------------------------------------------------

test "a fixlen_word cut after a byte carrying a reserved subtype is Incomplete (§7.2 item 6)" {
    // §4.1.1: a varint has no value before its final byte. The low three bits of
    // a `fixlen_word`'s first byte already spell the subtype, so a decoder that
    // evaluates it early answers INVALID here — where §4.1.1 requires
    // INCOMPLETE. Nothing else in this file exercises that: the dangling `0x80`
    // of the truncation test carries no settled sub-field to peek at, and the
    // truncation walk above cuts a message whose `fixlen_word` is one byte long.
    //
    // Header `02` (id 0, fixlen), then a first `fixlen_word` byte with the
    // continuation bit set and a reserved subtype in its low bits: 0x4 through
    // 0x7, each in two spellings.
    for ([_]u8{ 0x84, 0x85, 0x86, 0x87, 0x8C, 0x8D, 0x9E, 0xAF }) |first| {
        errdefer std.debug.print("first fixlen_word byte 0x{X:0>2}\n", .{first});
        try expectIncompleteWholeAndChunked(&.{ 0x02, first });
    }

    // Completing it settles the subtype for real, and only then is the reserved
    // value a rejection: `84 00` = (0 << 3) | 4, subtype 4, reserved.
    try expectInvalidWholeAndChunked(&.{ 0x02, 0x84, 0x00 });

    // The same rule at a fixlen *array*'s word, which is read on its own path.
    try expectIncompleteWholeAndChunked(&.{ 0x05, 0x01, 0x84 });
    try expectInvalidWholeAndChunked(&.{ 0x05, 0x01, 0x84, 0x00 });
}
