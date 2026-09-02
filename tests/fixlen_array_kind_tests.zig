//! Fixlen-array header ordering (CORELIB_PLAN §4.8, MESSAGE_SPEC §7.3) —
//! Crucible finding F-0042.
//!
//! A fixlen array's `count` word precedes its `fixlen_word`, so a receiver
//! cannot know whether the array that arrived *is* the declared field's value
//! until the subtype is in hand. §4.8 therefore fixes the decode order:
//!
//!   1. read `element_count`, enforcing only the FORMAT ceiling `ARRAY_MAX`
//!      (nothing is allocated on the strength of it);
//!   2. read the `fixlen_word` — EOF before or inside it is INCOMPLETE;
//!   3. validate the word as a format matter (fp32/4 or fp64/8 only);
//!   4. only then report the header, naming the element **subtype**, so the
//!      receiver applies its schema `count` bound solely to a field that
//!      survived the subtype test.
//!
//! This corelib is schema-agnostic, so the accept/reject verdicts the finding
//! tabulates are produced by generated code from this hook. What is testable
//! here — and what these tests pin — is the hook's *contract*: it fires once
//! per array field, past the `fixlen_word`, carrying `.fp32` / `.fp64` (never a
//! collapsed "fixlen"), and never before the subtype is known.
//!
//! The vectors are the finding's, at `arrays` (id 100) → `nested` (id 10) →
//! id 0, declared `array<fp32, count 5>` by the schema Crucible fuzzes:
//! `20` is the fp32 `fixlen_word` (4 B elements), `41` the fp64 one (8 B).

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const Event = common.Event;

/// `arrays` (id 100) → `nested` (id 10), the two sequence starts every vector
/// below opens with; `07 07` closes them.
const OPEN = [_]u8{ 0xA6, 0x06, 0x56 };
const CLOSE = [_]u8{ 0x07, 0x07 };

const SEQ_OPEN_EVENTS = [_]Event{
    .{ .sequence_begin = .{ .id = 100 } },
    .{ .sequence_begin = .{ .id = 10 } },
};

fn fp32Ev(id: sofab.Id) Event {
    return .{ .fp32 = .{ .id = id, .bits = 0 } };
}
fn fp64Ev(id: sofab.Id) Event {
    return .{ .fp64 = .{ .id = id, .bits = 0 } };
}

/// Decode `bytes` whole *and* one byte at a time; both must yield `want_status`
/// and exactly `want` events. Chunking matters here: the hook's position is a
/// statement about ordering, and a split between the two words is precisely the
/// case a resumable decoder can get wrong.
fn expectDecode(
    arena: std.mem.Allocator,
    bytes: []const u8,
    want_status: sofab.Status,
    want: []const Event,
) !void {
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectEqual(want_status, try is.feed(bytes, &rec));
    try common.expectEventsEqual(want, rec.events.items);

    var rec2 = common.Recorder.init(arena);
    var is2 = sofab.IStream.init();
    var chunked_status: sofab.Status = .complete; // fed nothing: at a field boundary
    for (bytes) |b| chunked_status = try is2.feed(&.{b}, &rec2);
    try std.testing.expectEqual(want_status, chunked_status);
    try common.expectEventsEqual(want, rec2.events.items);
}

/// Decode `bytes` whole and byte-wise; both must reject with InvalidMessage.
fn expectInvalid(arena: std.mem.Allocator, bytes: []const u8) !void {
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(bytes, &rec));

    var rec2 = common.Recorder.init(arena);
    var is2 = sofab.IStream.init();
    const chunked: anyerror!sofab.Status = blk: {
        var st: sofab.Status = .complete; // a decoder fed nothing sits at a field boundary
        for (bytes) |b| st = is2.feed(&.{b}, &rec2) catch |e| break :blk e;
        break :blk st;
    };
    try std.testing.expectError(error.InvalidMessage, chunked);
}

// --- the finding's vectors -------------------------------------------------

test "F-0042 row 1: a contradicting subtype is reported as .fp64, not a collapsed fixlen kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count 3, fixlen_word 0x41 = fp64 / 8 B, 24 payload bytes.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x03, 0x41 } ++ [_]u8{0} ** 24 ++ CLOSE;
    try expectDecode(arena, &bytes, .complete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .fp64, .count = 3 } },
        fp64Ev(0),
        fp64Ev(0),
        fp64Ev(0),
        .sequence_end,
        .sequence_end,
    }));
}

test "F-0042 row 2: an over-count with a contradicting subtype still names .fp64" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count 8 (> the schema's declared 5) but subtype fp64: generated code must
    // be able to see the subtype contradiction *first* and skip the field, so
    // the kind reported here must be `.fp64` — the whole point of the finding.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x08, 0x41 } ++ [_]u8{0} ** 64 ++ CLOSE;
    var want: [2 + 1 + 8 + 2]Event = undefined;
    want[0] = SEQ_OPEN_EVENTS[0];
    want[1] = SEQ_OPEN_EVENTS[1];
    want[2] = .{ .array_begin = .{ .id = 0, .kind = .fp64, .count = 8 } };
    for (want[3..11]) |*e| e.* = fp64Ev(0);
    want[11] = .sequence_end;
    want[12] = .sequence_end;
    try expectDecode(arena, &bytes, .complete, &want);
}

test "F-0042 row 3 (control): a matching subtype is reported as .fp32 so the schema bound applies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count 8, fixlen_word 0x20 = fp32 / 4 B, 32 payload bytes. The corelib
    // knows no schema and accepts; generated code rejects this (`count` 8 > the
    // declared 5) *because* the kind matches the declared element type. The
    // bound is being reordered by this fix, never weakened — if this header
    // ever stopped reporting `.fp32`, that rejection would silently vanish.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x08, 0x20 } ++ [_]u8{0} ** 32 ++ CLOSE;
    var want: [2 + 1 + 8 + 2]Event = undefined;
    want[0] = SEQ_OPEN_EVENTS[0];
    want[1] = SEQ_OPEN_EVENTS[1];
    want[2] = .{ .array_begin = .{ .id = 0, .kind = .fp32, .count = 8 } };
    for (want[3..11]) |*e| e.* = fp32Ev(0);
    want[11] = .sequence_end;
    want[12] = .sequence_end;
    try expectDecode(arena, &bytes, .complete, &want);
}

test "F-0042 row 4: EOF between the count word and the fixlen_word is INCOMPLETE, with no header reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The decoder cannot yet know whether this field is one it must bound, so
    // §5.2's precedence does not reach INVALID — and, critically, `arrayBegin`
    // must NOT have fired: a receiver that saw a header here would be deciding
    // on a subtype it has not read.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x08 };
    try expectDecode(arena, &bytes, .incomplete, &SEQ_OPEN_EVENTS);
}

test "F-0042 row 5 (control): the header is reported as soon as the fixlen_word lands, before any payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count 8, matching fp32 word, then EOF. The corelib's own verdict is
    // INCOMPLETE (bytes are missing), but the header has already been
    // delivered with kind `.fp32` and count 8 — which is exactly what lets
    // generated code return INVALID here without waiting for an element that
    // never arrives. Deferring the hook to the first element would regress this
    // row (the reason two generator-only workarounds were rejected upstream).
    const bytes = OPEN ++ [_]u8{ 0x05, 0x08, 0x20 };
    try expectDecode(arena, &bytes, .incomplete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .fp32, .count = 8 } },
    }));
}

test "F-0042 row 6 (control): the valid vector round-trips byte-identically" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = OPEN ++ [_]u8{ 0x05, 0x03, 0x20 } ++ [_]u8{0} ** 12 ++ CLOSE;
    try expectDecode(arena, &bytes, .complete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .fp32, .count = 3 } },
        fp32Ev(0),
        fp32Ev(0),
        fp32Ev(0),
        .sequence_end,
        .sequence_end,
    }));

    // Re-encoding what was decoded reproduces the input byte for byte.
    var buf: [64]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeSequenceBeginLazy(100);
    try os.writeSequenceBeginLazy(10);
    try os.writeArrayFp32(0, &[_]f32{ 0, 0, 0 });
    try os.writeSequenceEnd();
    try os.writeSequenceEnd();
    try std.testing.expectEqualSlices(u8, &bytes, buf[0..os.bytesUsed()]);
}

// --- regression vectors required by the family-wide fix contract -----------

test "F-0042: a zero-count fixlen array still reports its subtype, exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `[header][count = 0][fixlen_word]` — the empty array carries its word
    // (§4.8), so the header must still fire, past that word, with the right
    // kind and no payload. Moving the call site is most likely to break here.
    const empty_fp64 = OPEN ++ [_]u8{ 0x05, 0x00, 0x41 } ++ CLOSE;
    try expectDecode(arena, &empty_fp64, .complete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .fp64, .count = 0 } },
        .sequence_end,
        .sequence_end,
    }));

    // An empty fp32 array stays distinguishable from an empty fp64 one, both on
    // the wire and at the hook.
    const empty_fp32 = OPEN ++ [_]u8{ 0x05, 0x00, 0x20 } ++ CLOSE;
    try expectDecode(arena, &empty_fp32, .complete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .fp32, .count = 0 } },
        .sequence_end,
        .sequence_end,
    }));

    // Both survive an encode round-trip.
    var buf: [16]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeSequenceBeginLazy(100);
    try os.writeSequenceBeginLazy(10);
    try os.writeArrayFp64(0, &[_]f64{});
    try os.writeSequenceEnd();
    try os.writeSequenceEnd();
    try std.testing.expectEqualSlices(u8, &empty_fp64, buf[0..os.bytesUsed()]);
}

test "F-0042: an illegal fixlen_word stays INVALID and is never routed to the skip path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 0x22 = subtype 2 (string) with elem_len 4. §4.8 admits only fp32 and
    // fp64 as fixlen-array elements, so this is a FORMAT violation, judged
    // before the header is reported — it must not become a §7.3 skip merely
    // because the subtype also contradicts the declared fp32.
    try expectInvalid(arena, &(OPEN ++ [_]u8{ 0x05, 0x03, 0x22 } ++ [_]u8{0} ** 12 ++ CLOSE));
    // blob subtype (3), same reasoning.
    try expectInvalid(arena, &(OPEN ++ [_]u8{ 0x05, 0x03, 0x23 } ++ [_]u8{0} ** 12 ++ CLOSE));
    // Width mismatches: fp32 declared 8 B, fp64 declared 4 B.
    try expectInvalid(arena, &(OPEN ++ [_]u8{ 0x05, 0x01, 0x40 } ++ [_]u8{0} ** 8 ++ CLOSE));
    try expectInvalid(arena, &(OPEN ++ [_]u8{ 0x05, 0x01, 0x21 } ++ [_]u8{0} ** 4 ++ CLOSE));
}

test "F-0042: the ARRAY_MAX format ceiling still fires on the count word, before the fixlen_word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count = 2^31 (> ARRAY_MAX) as a 5-byte varint, with no `fixlen_word` at
    // all: the ceiling is a format bound on the count word and must reject
    // here — INVALID, never INCOMPLETE — without waiting for the subtype and
    // without the header ever firing.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x80, 0x80, 0x80, 0x80, 0x08 };
    try expectInvalid(arena, &bytes);

    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(&bytes, &rec));
    try common.expectEventsEqual(&SEQ_OPEN_EVENTS, rec.events.items);
}

test "F-0042: integer arrays are untouched — the header still fires right after the count word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `03` = ARRAY_UNSIGNED at id 0 (whose declared type is `array<fp32,
    // count 5>`): a wire type that contradicts the schema, one step earlier on
    // the wire. There is no second word, so the kind — `.unsigned` — is known
    // at the count word and the header keeps firing there.
    const bytes = OPEN ++ [_]u8{ 0x03, 0x08 } ++ [_]u8{0} ** 8 ++ CLOSE;
    var want: [2 + 1 + 8 + 2]Event = undefined;
    want[0] = SEQ_OPEN_EVENTS[0];
    want[1] = SEQ_OPEN_EVENTS[1];
    want[2] = .{ .array_begin = .{ .id = 0, .kind = .unsigned, .count = 8 } };
    for (want[3..11]) |*e| e.* = .{ .unsigned = .{ .id = 0, .value = 0 } };
    want[11] = .sequence_end;
    want[12] = .sequence_end;
    try expectDecode(arena, &bytes, .complete, &want);

    // Truncation right after an integer array's count word leaves the header
    // already reported — unlike the fixlen case, nothing more is needed to know
    // the kind.
    const trunc = OPEN ++ [_]u8{ 0x04, 0x02 };
    try expectDecode(arena, &trunc, .incomplete, &(SEQ_OPEN_EVENTS ++ [_]Event{
        .{ .array_begin = .{ .id = 0, .kind = .signed, .count = 2 } },
    }));
}

test "F-0042: ArrayKind names subtypes with the family's fixed ordinals" {
    // The kind domain is this family's decision (no clause mandates an
    // array-header hook at all), so the ordinals are pinned here and shared
    // across the eight push-API corelibs. A collapsed `fixlen` member is gone:
    // it could not answer the one question §4.8 step 3 turns on.
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(sofab.ArrayKind.unsigned));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(sofab.ArrayKind.signed));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(sofab.ArrayKind.fp32));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(sofab.ArrayKind.fp64));
    try std.testing.expectEqual(4, @typeInfo(sofab.ArrayKind).@"enum".fields.len);
}

test "F-0042: the header fires once per array field, never per element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Fed one byte at a time, a 40-element fp64 array must still produce
    // exactly one `arrayBegin` — the resume path must not re-report the header
    // when the payload straddles chunk boundaries.
    const bytes = OPEN ++ [_]u8{ 0x05, 0x28, 0x41 } ++ [_]u8{0} ** 320 ++ CLOSE;
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    var st: sofab.Status = .complete; // a decoder fed nothing sits at a field boundary
    for (bytes) |b| st = try is.feed(&.{b}, &rec);
    try std.testing.expectEqual(sofab.Status.complete, st);

    var headers: usize = 0;
    for (rec.events.items) |e| switch (e) {
        .array_begin => |a| {
            headers += 1;
            try std.testing.expectEqual(sofab.ArrayKind.fp64, a.kind);
            try std.testing.expectEqual(@as(usize, 40), a.count);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), headers);
}
