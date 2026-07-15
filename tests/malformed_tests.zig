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

    // One byte at a time: the same error must surface, at whichever feed
    // completes (or ends) the malformed item.
    var sink2: Nothing = .{};
    var is2 = sofab.IStream.init();
    const chunked: anyerror!sofab.Status = blk: {
        for (bytes) |b| _ = is2.feed(&.{b}, &sink2) catch |e| break :blk e;
        break :blk is2.status();
    };
    try std.testing.expectError(error.InvalidMessage, chunked);
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
    try os.writeSequenceBegin(1);
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
    try expectInvalidWholeAndChunked(&[_]u8{0xFF} ** 12);

    // Value varint of field id 0 (header 0x00) that overflows 64 bits.
    try expectInvalidWholeAndChunked(&[_]u8{0x00} ++ [_]u8{0xFF} ** 9 ++ [_]u8{0x7F});
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
    const bytes = [_]u8{0x0E} ** 256; // 256 nested sequence starts
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
    bad.appendSlice(arena, &[_]u8{0xFF} ** 12) catch @panic("oom");

    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    try std.testing.expectError(error.InvalidMessage, is.feed(bad.items, &rec));
    // The valid field before the garbage was still delivered.
    try common.expectEventsEqual(
        &.{.{ .unsigned = .{ .id = 1, .value = 42 } }},
        rec.events.items,
    );
}
