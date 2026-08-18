//! Cross-chunk UTF-8 semantics (CORELIB_PLAN §6.4, "Cross-chunk semantics",
//! normative) — the decode side of the shared `invalid_utf8` list.
//!
//! UTF-8 validity is a property of a `string` field's **complete payload**, and
//! a chunk boundary MUST NOT affect the outcome. Zig is a byte-container
//! target: the corelib delivers the payload and *generated* code calls
//! `sofab.utf8Valid` on the materialized string (README, §6.4 "the
//! `utf8Valid` primitive"). So the obligation this suite pins on the corelib
//! is the half it owns — **delivery**:
//!
//!   * every payload byte is delivered exactly once, in order, at its
//!     **absolute** offset within the field, however the input is chunked;
//!   * the payload's completion (`offset + chunk.len == total`) lands at the
//!     same byte whatever the chunking, so a validator that runs *at payload
//!     completion* — the timing §6.4 makes normative — reaches the same verdict
//!     as the one-shot decode;
//!   * a byte that can never be part of a valid sequence is **not** pulled
//!     forward into a mid-payload rejection: the decoder keeps reporting
//!     INCOMPLETE until the declared length is reached;
//!   * a `string` inside a skipped sub-sequence is never delivered at all, so
//!     it is never validated (§6.4 "Skipped fields are never validated").
//!
//! The shared `invalid_utf8` vectors alone cannot reach this: every one of them
//! is a 1–4 byte payload, so the invalid sequence always starts at payload
//! offset 0 and always lies inside the first chunk that carries any payload
//! byte at all. The tests below re-host each vector behind a long valid ASCII
//! prefix and split the feed **at** the prefix, so the invalid sequence starts
//! at an offset at or beyond every byte fed so far — the case a decoder that
//! reports chunk-relative offsets, or that validates per chunk, gets wrong and
//! the shared corpus never catches.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const vectors_json = @embedFile("test_vectors");

/// Valid ASCII prefix placed in front of each vector's bytes. Longer than the
/// decoder's carry window (64) so the prefix cannot be buffered whole and the
/// payload is genuinely delivered in pieces, and long enough that the invalid
/// sequence starts well past any plausible chunk-relative offset.
const PREFIX_LEN = 100;

/// A visitor modelling what generated decode code does with a `string` field:
/// assemble the delivered chunks and run `sofab.utf8Valid` **once, at payload
/// completion** — never per chunk, never mid-payload (§6.4).
///
/// It also records what the corelib promised about delivery, so a wrong
/// `offset` shows up as a failed assertion rather than as a silently
/// mis-assembled buffer.
const StringSink = struct {
    /// Room for the longest payload this suite builds.
    data: [PREFIX_LEN + 128]u8 = undefined,
    /// Bytes assembled so far — also the offset the next chunk must carry.
    len: usize = 0,
    total: usize = 0,
    /// Number of chunk callbacks received.
    chunks: usize = 0,
    /// Number of times a payload reached its declared length.
    completions: usize = 0,
    /// `utf8Valid` of the whole payload, recorded at completion. `null` while
    /// no payload has completed — the state in which §6.4 forbids a verdict.
    verdict: ?bool = null,
    /// Cleared if a chunk arrived at an offset other than the running total,
    /// with a `total` that changed mid-payload, or past the declared length.
    contiguous: bool = true,

    pub fn string(self: *StringSink, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        _ = id;
        self.chunks += 1;
        if (offset != self.len or offset + chunk.len > total) {
            self.contiguous = false;
            return;
        }
        if (offset != 0 and total != self.total) self.contiguous = false;
        self.total = total;
        @memcpy(self.data[offset..][0..chunk.len], chunk);
        self.len = offset + chunk.len;
        if (self.len == total) {
            self.completions += 1;
            self.verdict = sofab.utf8Valid(self.data[0..total]);
        }
    }

    fn payload(self: *const StringSink) []const u8 {
        return self.data[0..self.len];
    }
};

/// The shared `invalid_utf8` list — the payloads no strict decoder may accept.
fn invalidUtf8Vectors(arena: std.mem.Allocator) []const std.json.Value {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, vectors_json, .{}) catch
        @panic("failed to parse test_vectors.json");
    return doc.object.get("invalid_utf8").?.array.items;
}

/// Serialize a `string` field (id 0) carrying `payload` verbatim, bypassing the
/// encoder — a strict build refuses to put these bytes on the wire at all
/// (that is the encode-side obligation, covered in `vectors_tests.zig`), yet a
/// decoder must still be able to receive them from a hostile peer.
fn stringField(arena: std.mem.Allocator, payload: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    common.pushVarint(&out, arena, (0 << 3) | 0x2); // id 0, wire type fixlen
    common.pushVarint(&out, arena, (@as(u64, payload.len) << 3) | 0x2); // len, subtype string
    out.appendSlice(arena, payload) catch @panic("oom");
    return out.items;
}

/// Byte offset at which the payload of `stringField(payload)` starts.
fn payloadStart(message: []const u8, payload_len: usize) usize {
    return message.len - payload_len;
}

/// `PREFIX_LEN` bytes of plain ASCII — valid UTF-8 whatever follows it.
fn asciiPrefix(arena: std.mem.Allocator) []const u8 {
    const p = arena.alloc(u8, PREFIX_LEN) catch @panic("oom");
    for (p, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    return p;
}

test "invalid UTF-8 starting at a chunk offset at or beyond every byte fed so far" {
    // The gap in the shared corpus: its `invalid_utf8` payloads are 1–4 bytes,
    // so the malformed sequence is always at offset 0 and always inside the
    // first chunk carrying payload. Here the split falls exactly on the
    // boundary between the valid prefix and the vector's bytes, so the
    // malformed sequence begins at offset PREFIX_LEN — at or beyond the total
    // fed so far — and the decoder must report it there, at its absolute
    // position in the field, not relative to the chunk that carries it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = asciiPrefix(arena);

    var ran: usize = 0;
    for (invalidUtf8Vectors(arena)) |vec| {
        const name = vec.object.get("name").?.string;
        errdefer std.debug.print("invalid_utf8 vector [{s}] failed\n", .{name});
        ran += 1;

        const bad = common.hexToBytes(arena, vec.object.get("string_hex").?.string);
        const payload = std.mem.concat(arena, u8, &.{ prefix, bad }) catch @panic("oom");
        const message = stringField(arena, payload);
        const split = payloadStart(message, payload.len) + PREFIX_LEN;

        var sink: StringSink = .{};
        var is = sofab.IStream.init();

        // First feed: header, length word and the whole valid prefix. The
        // payload is not finished, so the field is INCOMPLETE and — §6.4 — no
        // verdict has been reached yet, not even a provisional one.
        try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(message[0..split], &sink));
        try std.testing.expect(sink.contiguous);
        try std.testing.expectEqual(@as(?bool, null), sink.verdict);
        try std.testing.expectEqual(@as(usize, 0), sink.completions);
        try std.testing.expectEqualSlices(u8, prefix, sink.payload());

        // Second feed: the malformed sequence alone. It starts at offset
        // PREFIX_LEN — the number of payload bytes already delivered — and the
        // corelib must say so, since the receiver assembles by absolute offset.
        const before = sink.chunks;
        try std.testing.expectEqual(sofab.Status.complete, try is.feed(message[split..], &sink));
        try std.testing.expect(sink.chunks > before);
        try std.testing.expect(sink.contiguous);
        try std.testing.expectEqual(@as(usize, 1), sink.completions);
        try std.testing.expectEqualSlices(u8, payload, sink.payload());

        // The verdict is reached exactly once, at payload completion, and it is
        // the strict build's rejection of the vector's bytes.
        try std.testing.expectEqual(@as(?bool, !sofab.STRICT_UTF8), sink.verdict);
    }
    // An empty run would mean this suite silently stopped covering the gap.
    try std.testing.expect(ran >= 8);
}

test "the UTF-8 verdict of a prefixed vector is the same at every chunk split" {
    // §6.4: "a chunk boundary MUST NOT affect the outcome". Every split point of
    // the message is tried — inside the header varint, inside the fixlen word,
    // inside the ASCII prefix, and inside the multi-byte sequence itself — plus
    // the pathological one-byte-at-a-time feed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = asciiPrefix(arena);

    for (invalidUtf8Vectors(arena)) |vec| {
        const name = vec.object.get("name").?.string;
        errdefer std.debug.print("invalid_utf8 vector [{s}] failed\n", .{name});

        const bad = common.hexToBytes(arena, vec.object.get("string_hex").?.string);
        const payload = std.mem.concat(arena, u8, &.{ prefix, bad }) catch @panic("oom");
        const message = stringField(arena, payload);

        // Reference: the same bytes decoded whole.
        var whole: StringSink = .{};
        try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &whole));
        try std.testing.expectEqual(@as(usize, 1), whole.completions);
        try std.testing.expectEqual(@as(?bool, !sofab.STRICT_UTF8), whole.verdict);

        var split: usize = 1;
        while (split < message.len) : (split += 1) {
            var sink: StringSink = .{};
            var is = sofab.IStream.init();
            _ = try is.feed(message[0..split], &sink);
            try std.testing.expectEqual(sofab.Status.complete, try is.feed(message[split..], &sink));
            try std.testing.expect(sink.contiguous);
            try std.testing.expectEqual(@as(usize, 1), sink.completions);
            try std.testing.expectEqual(whole.verdict, sink.verdict);
            try std.testing.expectEqualSlices(u8, payload, sink.payload());
        }

        // One byte at a time: every payload byte arrives in its own callback,
        // each at its own absolute offset, and the verdict is unchanged.
        var sink: StringSink = .{};
        var is = sofab.IStream.init();
        for (message) |b| _ = try is.feed(&.{b}, &sink);
        try std.testing.expectEqual(sofab.Status.complete, is.status());
        try std.testing.expect(sink.contiguous);
        try std.testing.expectEqual(payload.len, sink.chunks);
        try std.testing.expectEqual(@as(usize, 1), sink.completions);
        try std.testing.expectEqual(whole.verdict, sink.verdict);
        try std.testing.expectEqualSlices(u8, payload, sink.payload());
    }
}

test "a multi-byte sequence split at end-of-chunk stays a well-formed prefix" {
    // §6.4, first outcome: a multi-byte sequence cut by a *chunk* boundary is a
    // well-formed prefix — INCOMPLETE, never INVALID and never dropped. The
    // payload mixes 2-, 3- and 4-byte code points so a split falls inside each
    // width, and the same bytes cut by the *payload* boundary instead are the
    // rejection asserted above (`utf8_truncated_*`).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "¢ ¢ € € 𐍈 𐍈 ¢€𐍈 the last code point: \u{10FFFF}";
    const payload = std.mem.concat(arena, u8, &.{ asciiPrefix(arena), text }) catch @panic("oom");
    const message = stringField(arena, payload);
    const first_payload_byte = payloadStart(message, payload.len);

    var split: usize = 1;
    while (split < message.len) : (split += 1) {
        var sink: StringSink = .{};
        var is = sofab.IStream.init();
        // Every split short of the last byte leaves the field unfinished, and an
        // unfinished multi-byte sequence must not be turned into a verdict.
        const first = try is.feed(message[0..split], &sink);
        try std.testing.expectEqual(sofab.Status.incomplete, first);
        if (split > first_payload_byte) {
            try std.testing.expectEqual(@as(?bool, null), sink.verdict);
        }
        try std.testing.expectEqual(sofab.Status.complete, try is.feed(message[split..], &sink));
        try std.testing.expect(sink.contiguous);
        try std.testing.expectEqual(@as(usize, 1), sink.completions);
        try std.testing.expectEqual(@as(?bool, true), sink.verdict);
        try std.testing.expectEqualSlices(u8, payload, sink.payload());
    }
}

test "a byte that can never be valid is not pulled forward into a mid-payload verdict" {
    // §6.4: a byte that cannot begin or continue any sequence (0xFF, a bare
    // continuation byte) is malformed regardless of what follows — "but the
    // verdict is still reported at payload completion, not before". So the feed
    // that carries it, with the declared length not yet reached, must return
    // INCOMPLETE and must not error: this is the one place where INVALID does
    // *not* dominate INCOMPLETE.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = asciiPrefix(arena);

    for ([_][1]u8{ .{0xFF}, .{0x80}, .{0xC0} }) |lead| {
        // The malformed byte sits mid-payload with valid ASCII behind it, so the
        // field goes on for many more bytes after the point of no return.
        const payload = std.mem.concat(arena, u8, &.{ prefix, &lead, "tail bytes that keep the payload going" }) catch
            @panic("oom");
        const message = stringField(arena, payload);
        const bad_at = payloadStart(message, payload.len) + PREFIX_LEN;

        var sink: StringSink = .{};
        var is = sofab.IStream.init();
        // Feed up to and including the malformed byte: still INCOMPLETE, no
        // verdict, no error.
        try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(message[0 .. bad_at + 1], &sink));
        try std.testing.expectEqual(@as(?bool, null), sink.verdict);
        try std.testing.expectEqual(@as(usize, PREFIX_LEN + 1), sink.len);
        // …and one more byte still does not settle it.
        try std.testing.expectEqual(sofab.Status.incomplete, try is.feed(message[bad_at + 1 ..][0..1], &sink));
        try std.testing.expectEqual(@as(?bool, null), sink.verdict);
        // The rest completes the payload, and only then is the verdict reached.
        try std.testing.expectEqual(sofab.Status.complete, try is.feed(message[bad_at + 2 ..], &sink));
        try std.testing.expect(sink.contiguous);
        try std.testing.expectEqual(@as(usize, 1), sink.completions);
        try std.testing.expectEqual(@as(?bool, !sofab.STRICT_UTF8), sink.verdict);
        try std.testing.expectEqualSlices(u8, payload, sink.payload());
    }
}

test "an invalid-UTF-8 string inside a skipped sub-sequence is never delivered" {
    // §6.4 "Skipped fields are never validated": validation runs only where a
    // string is *materialized*. A visitor that declares no `sequenceBegin`
    // cannot descend, so the corelib consumes the whole sub-sequence itself —
    // the string payload inside it must never reach the visitor, and the
    // message must decode COMPLETE even though it carries bytes a strict
    // decoder would reject had they been read.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = asciiPrefix(arena);

    for (invalidUtf8Vectors(arena)) |vec| {
        const name = vec.object.get("name").?.string;
        errdefer std.debug.print("invalid_utf8 vector [{s}] failed\n", .{name});

        const bad = common.hexToBytes(arena, vec.object.get("string_hex").?.string);
        const payload = std.mem.concat(arena, u8, &.{ prefix, bad }) catch @panic("oom");
        // 0x0E = sequence start (id 1), 0x07 = sequence end.
        const message = std.mem.concat(arena, u8, &.{
            &[_]u8{0x0E},
            stringField(arena, payload),
            &[_]u8{0x07},
        }) catch @panic("oom");

        // One-shot: the sub-sequence is walked and discarded.
        var whole: StringSink = .{};
        try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(message, &whole));
        try std.testing.expectEqual(@as(usize, 0), whole.chunks);
        try std.testing.expectEqual(@as(?bool, null), whole.verdict);

        // …and the same walking one byte at a time, where the skipped payload
        // crosses every chunk boundary there is.
        var sink: StringSink = .{};
        var is = sofab.IStream.init();
        for (message) |b| _ = try is.feed(&.{b}, &sink);
        try std.testing.expectEqual(sofab.Status.complete, is.status());
        try std.testing.expectEqual(@as(usize, 0), sink.chunks);
        try std.testing.expectEqual(@as(?bool, null), sink.verdict);
    }
}
