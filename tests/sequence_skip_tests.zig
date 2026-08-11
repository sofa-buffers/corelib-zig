//! Auto-skip of whole sub-sequences (CORELIB_PLAN §5.2/§6, MESSAGE_SPEC §4).
//!
//! A sequence opens a **fresh id namespace** (CORELIB_PLAN §3), so a child id
//! carries no meaning in the enclosing scope. A visitor that declares no
//! `sequenceBegin` is never told a scope was entered — it cannot descend — so
//! the decoder must consume and discard the **entire sub-sequence** rather than
//! deliver its children as if they were the enclosing scope's fields ("Skip —
//! do nothing; the field's remaining bytes, *or the entire sub-sequence*, are
//! consumed and discarded automatically", §5.2).
//!
//! Skipping is a byte walk, not a shortcut: everything inside the skipped scope
//! is still parsed and validated, so `MAX_DEPTH`, the malformed-input verdicts
//! and the resync onto the field after the scope are unaffected — and the
//! outcome does not depend on where the chunk boundaries fall (§7.2 item 4).

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const Event = common.Event;
const Id = sofab.Id;

/// The finding's reproducer: a receiver that only knows flat unsigned fields.
/// Without auto-skip the nested `id 0 = 99` overwrites the top-level `id 0 = 1`
/// — a wrong value, silently.
const FlatOnly = struct {
    hits: [8]u64 = @splat(0),

    pub fn unsigned(self: *FlatOnly, id: Id, v: u64) void {
        if (id < 8) self.hits[id] = v;
    }
};

test "a visitor that cannot descend skips the sub-sequence (issue #44)" {
    // 00 01    unsigned id 0 = 1     (top level)
    // 0E       sequence start id 1
    // 00 63    unsigned id 0 = 99    (child scope — a *different* id 0)
    // 07       sequence end
    const bytes = [_]u8{ 0x00, 0x01, 0x0E, 0x00, 0x63, 0x07 };

    var whole: FlatOnly = .{};
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(&bytes, &whole));
    try std.testing.expectEqual(@as(u64, 1), whole.hits[0]);

    // Same verdict, same values, one byte at a time.
    var chunked: FlatOnly = .{};
    var is = sofab.IStream.init();
    for (bytes) |b| _ = try is.feed(&.{b}, &chunked);
    try std.testing.expectEqual(sofab.Status.complete, is.status());
    try std.testing.expectEqual(@as(u64, 1), chunked.hits[0]);

    // A visitor that *does* declare `sequenceBegin` opted into the scope and
    // still receives every child, unchanged.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(&bytes, &rec));
    try common.expectEventsEqual(&.{
        .{ .unsigned = .{ .id = 0, .value = 1 } },
        .{ .sequence_begin = .{ .id = 1 } },
        .{ .unsigned = .{ .id = 0, .value = 99 } },
        .sequence_end,
    }, rec.events.items);
}

/// A message whose skipped scope contains one of every payload shape: a
/// scalar, a string, a blob, an integer array long enough to take the bulk
/// decode path, a fixlen (float) array, a float scalar and a nested scope.
/// Every one of them uses an id that also occurs at the top level.
fn encodeNestedSample(buf: []u8) ![]const u8 {
    var os = sofab.OStream.init(buf);
    try os.writeUnsigned(1, 7);
    try os.writeString(2, "outer");

    try os.writeSequenceBeginLazy(3);
    try os.writeUnsigned(1, 99);
    try os.writeSigned(2, -99);
    try os.writeString(2, "inner");
    try os.writeBlob(4, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    try os.writeArrayUnsigned(1, &[_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    try os.writeArrayFp32(5, &[_]f32{ 1.5, 2.5, 3.5 });
    try os.writeFp64(6, -2.5);
    try os.writeSequenceBeginLazy(1); // a scope inside the skipped scope
    try os.writeUnsigned(1, 1234);
    try os.writeString(2, "deep");
    try os.writeSequenceEnd();
    try os.writeSequenceEnd();

    try os.writeUnsigned(1, 8); // resync target: the field after the scope
    return buf[0..os.bytesUsed()];
}

/// Only the top-level fields survive the skip, in order.
const want_flat: []const Event = &.{
    .{ .unsigned = .{ .id = 1, .value = 7 } },
    .{ .str = .{ .id = 2, .data = "outer" } },
    .{ .unsigned = .{ .id = 1, .value = 8 } },
};

test "every payload shape inside a skipped scope is discarded, and the next field resyncs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [256]u8 = undefined;
    const message = try encodeNestedSample(&buf);

    var whole = common.FlatRecorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &whole));
    try common.expectEventsEqual(want_flat, whole.events());

    // Chunk-independence: the same events one byte at a time, including the
    // payloads and arrays that straddle every possible boundary.
    var chunked = common.FlatRecorder.init(arena);
    var is = sofab.IStream.init();
    for (message) |b| _ = try is.feed(&.{b}, &chunked);
    try std.testing.expectEqual(sofab.Status.complete, is.status());
    try common.expectEventsEqual(want_flat, chunked.events());

    // …and in a few odd chunk sizes, where a boundary can fall mid-array.
    for ([_]usize{ 2, 3, 5, 7, 13 }) |n| {
        var rec = common.FlatRecorder.init(arena);
        var s = sofab.IStream.init();
        var i: usize = 0;
        while (i < message.len) : (i += n) {
            _ = try s.feed(message[i..@min(i + n, message.len)], &rec);
        }
        try std.testing.expectEqual(sofab.Status.complete, s.status());
        try common.expectEventsEqual(want_flat, rec.events());
    }

    // Control: a descending visitor still sees all 31 events of the message —
    // the skip is a property of the visitor, never of the bytes.
    var full = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &full));
    try std.testing.expectEqual(@as(usize, 31), full.events.items.len);
}

test "a skipped scope is walked, not jumped: malformed bytes inside it are still INVALID" {
    const Flat = struct {
        pub fn unsigned(_: *@This(), _: Id, _: u64) void {}
    };

    // A reserved fixlen subtype (0x4) inside the skipped scope: skipping must
    // not turn a malformed message into a valid one.
    var v1: Flat = .{};
    try std.testing.expectError(
        error.InvalidMessage,
        sofab.decode(&.{ 0x0E, 0x02, 0x24, 0, 0, 0, 0, 0x07 }, &v1),
    );

    // Nesting past MAX_DEPTH is still rejected while skipping.
    var v2: Flat = .{};
    const deep: [256]u8 = @splat(0x0E);
    try std.testing.expectError(error.InvalidMessage, sofab.decode(&deep, &v2));

    // A scope left open is still INCOMPLETE, never COMPLETE: the skip does not
    // close anything on the visitor's behalf.
    var v3: Flat = .{};
    try std.testing.expectEqual(
        sofab.Status.incomplete,
        try sofab.decode(&.{ 0x00, 0x01, 0x0E, 0x00, 0x63 }, &v3),
    );
}

test "a skipped field is never announced: fixlenBegin does not fire inside the scope" {
    // §6.4/§7.1: a skipped field is never validated and no schema bound applies
    // to it — there is no destination it could be bound to. A visitor whose
    // `fixlenBegin` rejects everything must therefore see nothing inside a scope
    // it cannot descend into.
    const Rejector = struct {
        calls: u32 = 0,
        pub fn fixlenBegin(self: *@This(), _: Id, _: sofab.FixlenType, _: usize) sofab.Error!void {
            self.calls += 1;
            return error.InvalidMessage;
        }
    };

    // header (1 << 3) | 2 = 0x0A, word (2 << 3) | 2 = 0x12, "hi" — inside a
    // sequence (0x0E … 0x07).
    var nested: Rejector = .{};
    try std.testing.expectEqual(
        sofab.Status.complete,
        try sofab.decode(&.{ 0x0E, 0x0A, 0x12, 'h', 'i', 0x07 }, &nested),
    );
    try std.testing.expectEqual(@as(u32, 0), nested.calls);

    // Control: the same field at the top level is announced, and rejected.
    var top: Rejector = .{};
    try std.testing.expectError(
        error.InvalidMessage,
        sofab.decode(&.{ 0x0A, 0x12, 'h', 'i' }, &top),
    );
    try std.testing.expectEqual(@as(u32, 1), top.calls);
}
