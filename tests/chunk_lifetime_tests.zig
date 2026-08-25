//! Chunk lifetime and no-foreign-memory (CORELIB_PLAN §7.2 item 4, §6.0, §6.7).
//!
//! Three properties this suite could otherwise not notice, because every other
//! test keeps the bytes it fed alive for as long as it looks at the result:
//!
//! * **`feed`** — once it returns, the chunk is the caller's again. Scrubbing or
//!   freeing it must not change what was decoded (§6.0, chunk lifetime).
//! * **`decode`** — the one-shot path has *no* exemption (§6.7.1). A port that
//!   hands out a slice into the buffer it was given and calls it retainable
//!   passes every other item on §7.2's list; only scrubbing that buffer after
//!   the call tells the two apart.
//! * **encode** — every byte a flush sink is handed lies inside the buffer the
//!   caller installed. Pass-through of a `string`/`blob` run is forbidden
//!   (§5.1.6), so this holds on every flush of every message, with no flag to
//!   set and no exemption to claim.
//!
//! The visitor here is `common.Recorder`, which copies each payload into its own
//! arena **during** the callback — the discipline §6.7 asks of every caller. It
//! is what makes the scrub a fair test rather than a use-after-free of the
//! test's own making.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");
const Event = common.Event;

const scrub_fill: u8 = 0xA5;

/// A message with every payload-bearing shape in it: scalars, a `string` and a
/// `blob` far longer than any chunk size used below, both array families, and a
/// nested sequence. Written into `buf`, which must be large enough.
fn buildMessage(buf: []u8) ![]const u8 {
    const text = "the quick brown fox jumps over the lazy dog, repeatedly and at length";
    var blob: [300]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);

    var os = sofab.OStream.init(buf);
    try os.writeUnsigned(1, 0xDEAD_BEEF);
    try os.writeSigned(2, -12345);
    try os.writeString(3, text);
    try os.writeBlob(4, &blob);
    try os.writeArrayUnsigned(5, &[_]u32{ 1, 2, 3, 4, 5 });
    try os.writeArrayFp64(6, &[_]f64{ 1.5, -2.25 });
    try os.writeSequenceBeginLazy(7);
    try os.writeString(1, "nested");
    try os.writeUnsigned(2, 9);
    try os.writeSequenceEnd();
    try os.writeBoolean(8, true);
    return buf[0..os.bytesUsed()];
}

/// Decode `message` in one call from a buffer that is *not* scrubbed, and
/// return the events — the reference every scrubbed run is compared against.
fn reference(arena: std.mem.Allocator, message: []const u8) ![]const Event {
    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &rec));
    return rec.events.items;
}

test "a fed chunk may be scrubbed the moment feed returns (§6.0)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msg_buf: [1024]u8 = undefined;
    const message = try buildMessage(&msg_buf);
    const want = try reference(arena, message);

    // Every chunk size that splits this message differently, including 1 (a
    // header, a length word and a payload each straddle) and sizes that fall
    // inside the long payloads.
    for ([_]usize{ 1, 2, 3, 5, 7, 13, 64, 128 }) |k| {
        var rec = common.Recorder.init(arena);
        var is = sofab.IStream.init();
        var st = sofab.Status.incomplete;
        var off: usize = 0;
        while (off < message.len) {
            const n = @min(k, message.len - off);
            // The chunk lives in memory of its own, handed over for exactly one
            // call and scrubbed the instant it comes back.
            const chunk = try std.testing.allocator.alloc(u8, n);
            @memcpy(chunk, message[off..][0..n]);
            st = try is.feed(chunk, &rec);
            @memset(chunk, scrub_fill);
            std.testing.allocator.free(chunk);
            off += n;
        }
        errdefer std.debug.print("chunk size {d}\n", .{k});
        try std.testing.expectEqual(sofab.Status.complete, st);
        try common.expectEventsEqual(want, rec.events.items);
    }
}

test "the one-shot buffer may be scrubbed the moment decode returns (§6.7.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msg_buf: [1024]u8 = undefined;
    const message = try buildMessage(&msg_buf);
    const want = try reference(arena, message);

    // `decode` over a buffer that is freed — not merely overwritten — before
    // anything is read back. A delivered slice that outlived its callback is a
    // dangling read here, and the recorded events are wrong even where the
    // allocator hands the pages straight back.
    const owned = try std.testing.allocator.alloc(u8, message.len);
    @memcpy(owned, message);
    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(owned, &rec));
    @memset(owned, scrub_fill);
    std.testing.allocator.free(owned);

    try common.expectEventsEqual(want, rec.events.items);
}

test "a value the visitor keeps past its callback is the caller's copy, never the codec's slice" {
    // The other half of §6.7: what the callback receives is *bytes the caller
    // fed*, and the copy is the caller's job. This visitor records, for each
    // payload, whether the slice it was handed pointed into the buffer it fed —
    // pinning that the codec asserts nothing about lifetime and hands back no
    // storage of its own that a caller could be tempted to retain.
    var msg_buf: [1024]u8 = undefined;
    const message = try buildMessage(&msg_buf);

    const Watcher = struct {
        input: []const u8,
        carry_slices: usize = 0,
        payloads: usize = 0,

        fn note(self: *@This(), chunk: []const u8) void {
            self.payloads += 1;
            const p = @intFromPtr(chunk.ptr);
            const lo = @intFromPtr(self.input.ptr);
            if (p < lo or p + chunk.len > lo + self.input.len) self.carry_slices += 1;
        }
        pub fn string(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
            _ = .{ id, total, offset };
            self.note(chunk);
        }
        pub fn blob(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
            _ = .{ id, total, offset };
            self.note(chunk);
        }
        // Declared so the nested scope is descended into rather than skipped
        // whole: the string inside it is a payload this test wants to see.
        pub fn sequenceBegin(self: *@This(), id: sofab.Id) void {
            _ = .{ self, id };
        }
        pub fn sequenceEnd(self: *@This()) void {
            _ = self;
        }
    };

    // One-shot: every payload is a slice of the caller's own input.
    var w: Watcher = .{ .input = message };
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &w));
    try std.testing.expect(w.payloads >= 3);
    try std.testing.expectEqual(@as(usize, 0), w.carry_slices);
}

test "a flush sink is only ever handed memory inside the installed buffer (§5.1.6)" {
    // A blob many times the buffer size: the divisible-run path has every
    // opportunity to hand the sink the caller's source slice directly, which is
    // exactly what §5.1.6 forbids. The assertion is a containment test on the
    // address range, not pointer identity — a pass-through of the *tail* of a
    // run would compare unequal to the buffer base and still be foreign memory.
    const buf_size = 8;
    var payload: [buf_size * 40]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 5);

    const Sink = struct {
        buffer: []u8,
        calls: usize = 0,
        foreign: usize = 0,
        seen: usize = 0,

        fn push(ctx: ?*anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.seen += chunk.len;
            const p = @intFromPtr(chunk.ptr);
            const lo = @intFromPtr(self.buffer.ptr);
            if (p < lo or p + chunk.len > lo + self.buffer.len) self.foreign += 1;
        }
    };

    var buf: [buf_size]u8 = undefined;
    var sink: Sink = .{ .buffer = &buf };
    var os = sofab.OStream.initFlush(&buf, 0, &sink, Sink.push);
    try os.writeBlob(1, &payload);
    try os.writeString(2, "and a string after it, also longer than the buffer");
    _ = os.flush();

    try std.testing.expect(sink.calls > payload.len / buf_size);
    try std.testing.expectEqual(@as(usize, 0), sink.foreign);
    // Everything the encoder produced went through the sink, so the byte count
    // it saw is the message length — no run took a shortcut around it.
    var one_shot: [payload.len + 128]u8 = undefined;
    var direct = sofab.OStream.init(&one_shot);
    try direct.writeBlob(1, &payload);
    try direct.writeString(2, "and a string after it, also longer than the buffer");
    try std.testing.expectEqual(direct.bytesUsed(), sink.seen);
}
