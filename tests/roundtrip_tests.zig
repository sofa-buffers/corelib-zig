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
    try os.writeSequenceBegin(14);
    {
        try os.writeUnsigned(1, 99);
        try os.writeString(2, "nested");
        try os.writeSequenceBegin(3);
        {
            try os.writeSigned(1, -7);
            try os.writeSequenceBegin(1); // empty innermost sequence
            try os.writeSequenceEnd();
        }
        try os.writeSequenceEnd();
    }
    try os.writeSequenceEnd();
    try os.writeArrayUnsigned(15, &[_]u8{}); // explicit empty integer array
    try os.writeArrayFp64(16, &[_]f64{}); // empty fixlen array keeps its word
    try os.writeString(17, ""); // empty string
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
    // concatenated flush output must be byte-identical (§7.2 item 4).
    for ([_]usize{ 1, 2, 5, 16 }) |bs| {
        const Collector = struct {
            data: [1024]u8 = undefined,
            len: usize = 0,
            fn push(ctx: ?*anyopaque, chunk: []const u8) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                @memcpy(self.data[self.len..][0..chunk.len], chunk);
                self.len += chunk.len;
            }
        };
        var out: Collector = .{};
        var scratch: [16]u8 = undefined;
        var cos = sofab.OStream.initFlush(scratch[0..bs], 0, &out, Collector.push);
        try writeBigMessage(&cos);
        _ = cos.flush();
        try std.testing.expectEqualSlices(u8, message, out.data[0..out.len]);
    }

    // One-shot decode.
    var whole = common.Recorder.init(arena);
    try sofab.decode(message, &whole);

    // Chunked decode at several odd chunk sizes, incl. one byte at a time.
    for ([_]usize{ 1, 3, 7, 13 }) |cs| {
        var rec = common.Recorder.init(arena);
        var is = sofab.IStream.init();
        var pos: usize = 0;
        while (pos < message.len) : (pos += cs) {
            try is.feed(message[pos..@min(pos + cs, message.len)], &rec);
        }
        try is.finish();
        try common.expectEventsEqual(whole.events.items, rec.events.items);
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
    try sofab.decode(buf[0..os.bytesUsed()], &rec);
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
    try sofab.decode(buf[0..os.bytesUsed()], &rec);
    try common.expectEventsEqual(
        &.{.{ .fp64 = .{ .id = 1, .bits = nan_bits } }},
        rec.events.items,
    );
}
