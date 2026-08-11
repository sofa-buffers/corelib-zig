//! Roundtrip and chunked-streaming tests (ARCHITECTURE §7.2, items 3–4):
//! encode → decode → compare, one-shot vs. streamed, on representative
//! messages including one far larger than the streaming buffers.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const Event = common.Event;

/// Encode a large composite message mixing every wire type, nested three deep.
fn writeBigMessage(os: *sofab.OStream) !void {
    try os.writeUnsigned(1, 0);
    try os.writeUnsigned(2, std.math.maxInt(u64));
    try os.writeSigned(3, std.math.minInt(i64));
    try os.writeSigned(4, std.math.maxInt(i64));
    try os.writeBoolean(5, true);
    try os.writeFp32(6, 3.14159);
    try os.writeFp64(7, -2.718281828459045);
    try os.writeString(8, "a string that is longer than the tiny streaming buffers used below");
    try os.writeBlob(9, &[_]u8{ 0x00, 0xFF, 0x10, 0x20, 0x30, 0x40, 0x50 });
    try os.writeArrayUnsigned(10, &[_]u64{ 0, 1, 127, 128, 300, 1 << 62 });
    try os.writeArraySigned(11, &[_]i64{ 0, -1, 1, -300, 1 << 60, -(1 << 60) });
    try os.writeArrayFp32(12, &[_]f32{ 0.0, -0.0, std.math.inf(f32), -std.math.inf(f32) });
    try os.writeArrayFp64(13, &[_]f64{ 1.5, -1.5, std.math.inf(f64) });
    try os.writeSequenceBeginLazy(14);
    {
        try os.writeUnsigned(1, 99);
        try os.writeString(2, "nested");
        try os.writeSequenceBeginLazy(3);
        {
            try os.writeSigned(1, -7);
            // Empty innermost sequence, closed with `writeSequenceEndKeep` so
            // the empty frame still reaches the wire — the wrapper-array
            // *element* position (MESSAGE_SPEC §5.1), the one place a
            // contentless sequence must stay visible. In the *field* position
            // `writeSequenceEnd` would drop it instead (covered by the ostream
            // unit tests); keeping it here preserves this suite's coverage of
            // the empty-sequence wire form through the decoder.
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceEndKeep();
        }
        try os.writeSequenceEnd();
    }
    try os.writeSequenceEnd();
    try os.writeArrayUnsigned(15, &[_]u8{}); // explicit empty integer array
    try os.writeArrayFp64(16, &[_]f64{}); // empty fixlen array keeps its word
    try os.writeString(17, ""); // empty string
}

/// Feed `message` in `cs`-byte chunks and assert the decoder reaches COMPLETE
/// having delivered exactly `want` — the event stream of the same bytes decoded
/// whole (MESSAGE_SPEC §7.2 item 4: the outcome cannot depend on where the
/// chunk boundaries fall).
fn expectChunkedEquals(arena: std.mem.Allocator, message: []const u8, want: []const Event, cs: usize) !void {
    var rec = common.Recorder.init(arena);
    var is = sofab.IStream.init();
    var pos: usize = 0;
    while (pos < message.len) : (pos += cs) {
        _ = try is.feed(message[pos..@min(pos + cs, message.len)], &rec);
    }
    try std.testing.expectEqual(sofab.Status.complete, is.status());
    try common.expectEventsEqual(want, rec.events.items);
}

test "roundtrip: one-shot encode equals chunked encode, one-shot decode equals chunked decode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One-shot encode.
    var big: [1024]u8 = undefined;
    var os = sofab.OStream.init(&big);
    try writeBigMessage(&os);
    const message = big[0..os.bytesUsed()];
    try std.testing.expect(message.len > 100);

    // Chunked encode through buffers far smaller than the message: the
    // concatenated flush output must be byte-identical (§7.2 item 4). The first
    // size is the port's own declared `MIN_OUTPUT_BUFFER` — the size that proves
    // the constant is real — and the message carries a string far longer than
    // any of these buffers, so the divisible-run path is exercised too (§5.1).
    for ([_]usize{ sofab.MIN_OUTPUT_BUFFER, 2, 5, 16 }) |bs| {
        var out: common.Collector(1024) = .{};
        var scratch: [16]u8 = undefined;
        var cos = sofab.OStream.initFlush(scratch[0..bs], 0, &out, @TypeOf(out).push);
        try writeBigMessage(&cos);
        _ = cos.flush();
        try std.testing.expectEqualSlices(u8, message, out.bytes());
    }

    // One-shot decode.
    var whole = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &whole));

    // Chunked decode at several odd chunk sizes, incl. one byte at a time, and
    // several past the decoder's internal carry window — the sizes at which a
    // chunk that completes a carried item still holds whole fields of its own,
    // which the decoder has to go on parsing in place rather than through the
    // carry buffer.
    for ([_]usize{ 1, 3, 7, 13, 63, 64, 65, 100 }) |cs| {
        try expectChunkedEquals(arena, message, whole.events.items, cs);
    }
}

test "integer arrays survive every encode-buffer and decode-chunk boundary" {
    // Targets the seam between the bulk codec paths — which require a whole
    // maximum-length varint of headroom — and the byte-at-a-time paths that
    // take over near the end of a buffer. Every buffer size from 1 up to past
    // that headroom puts the transition at a different element, and every chunk
    // size does the same on the way back in, so an element split across the
    // seam (or an element the bulk loop wrongly claimed it could fit) shows up
    // as a byte difference rather than as luck.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Values spanning all ten varint lengths, both sides of each boundary, plus
    // the full-width spread the benchmark generator produces — the encodings
    // most likely to straddle a seam.
    var u_vals: std.ArrayList(u64) = .empty;
    var i_vals: std.ArrayList(i64) = .empty;
    var shift: u6 = 0;
    while (true) : (shift += 7) {
        const b = @as(u64, 1) << shift;
        try u_vals.appendSlice(arena, &.{ b -| 1, b, b + 1 });
        try i_vals.appendSlice(arena, &.{ @bitCast(b), -%@as(i64, @bitCast(b)), @intCast(shift) });
        if (shift >= 63) break;
    }
    for (0..64) |k| {
        try u_vals.append(arena, @as(u64, k) *% 0x9E37_79B9_7F4A_7C15);
        try i_vals.append(arena, @bitCast(@as(u64, k) *% 0xC2B2_AE3D_27D4_EB4F));
    }
    try u_vals.appendSlice(arena, &.{ 0, std.math.maxInt(u64) });
    try i_vals.appendSlice(arena, &.{ 0, std.math.minInt(i64), std.math.maxInt(i64) });

    // One-shot reference bytes.
    var big: [8192]u8 = undefined;
    var os = sofab.OStream.init(&big);
    try os.writeArrayUnsigned(1, u_vals.items);
    try os.writeArraySigned(2, i_vals.items);
    const message = big[0..os.bytesUsed()];

    // Encode through every buffer size across the headroom threshold.
    var bs: usize = 1;
    while (bs <= 24) : (bs += 1) {
        var out: common.Collector(8192) = .{};
        var scratch: [24]u8 = undefined;
        var cos = sofab.OStream.initFlush(scratch[0..bs], 0, &out, @TypeOf(out).push);
        try cos.writeArrayUnsigned(1, u_vals.items);
        try cos.writeArraySigned(2, i_vals.items);
        _ = cos.flush();
        try std.testing.expectEqualSlices(u8, message, out.bytes());
    }

    // Decode at every chunk size across the same threshold.
    var whole = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &whole));
    var cs: usize = 1;
    while (cs <= 24) : (cs += 1) try expectChunkedEquals(arena, message, whole.events.items, cs);
    // …and past the decoder's carry window, where the chunk that completes a
    // carried element still holds whole elements of its own: those must be
    // decoded in place, and the bulk element loop picks up mid-chunk.
    for ([_]usize{ 63, 64, 65, 127, 128, 1000 }) |wide| {
        try expectChunkedEquals(arena, message, whole.events.items, wide);
    }
}

test "roundtrip: values survive bit-exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try writeBigMessage(&os);

    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(buf[0..os.bytesUsed()], &rec));
    const ev = rec.events.items;

    // Spot-check boundary values recovered exactly.
    try std.testing.expect(ev[0].eql(.{ .unsigned = .{ .id = 1, .value = 0 } }));
    try std.testing.expect(ev[1].eql(.{ .unsigned = .{ .id = 2, .value = std.math.maxInt(u64) } }));
    try std.testing.expect(ev[2].eql(.{ .signed = .{ .id = 3, .value = std.math.minInt(i64) } }));
    try std.testing.expect(ev[3].eql(.{ .signed = .{ .id = 4, .value = std.math.maxInt(i64) } }));
    // Boolean arrives as unsigned 1.
    try std.testing.expect(ev[4].eql(.{ .unsigned = .{ .id = 5, .value = 1 } }));
    // -0.0 must keep its sign bit (bit-pattern comparison, §4.6).
    const neg_zero: Event = .{ .fp32 = .{ .id = 12, .bits = @bitCast(@as(f32, -0.0)) } };
    var found_neg_zero = false;
    for (ev) |e| {
        if (e.eql(neg_zero)) found_neg_zero = true;
    }
    try std.testing.expect(found_neg_zero);
}

test "NaN payloads round-trip bit-for-bit (not representable in the shared JSON)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A quiet NaN with a distinctive payload — must come back identical.
    const nan_bits: u64 = 0x7FF8_0000_DEAD_BEEF;
    var buf: [32]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeFp64(1, @bitCast(nan_bits));

    var rec = common.Recorder.init(arena);
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(buf[0..os.bytesUsed()], &rec));
    try common.expectEventsEqual(
        &.{.{ .fp64 = .{ .id = 1, .bits = nan_bits } }},
        rec.events.items,
    );
}
