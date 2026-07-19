//! Streaming input stream decoder.
//!
//! Two ways in, one visitor:
//!
//! * `decode` — the **fast contiguous path**. Hand it a complete message and it
//!   advances a cursor over the buffer, decoding every field with no copies;
//!   string/blob payloads are delivered as a single borrowed slice straight out
//!   of your buffer. This is the 90 % case on a server and the speed showcase.
//! * `IStream` — the **streaming path** (ARCHITECTURE §5.2). Feed it bytes in
//!   arbitrarily small chunks with `feed`; a single field header or payload may
//!   be split across any number of `feed` calls and the decoder
//!   suspends/resumes at any byte boundary. When the whole message is fed in
//!   one call it takes the same zero-copy fast path internally; only the few
//!   bytes of a small item that genuinely straddles a chunk boundary are ever
//!   copied (into a fixed carry buffer — the decoder never allocates).
//!
//! Both drive the same **visitor**: any pointer to a struct implementing the
//! callbacks it cares about. Dispatch is comptime duck typing — monomorphized,
//! no vtable — and a missing method is a no-op, so unhandled fields (and whole
//! sub-sequences) are skipped automatically:
//!
//! ```zig
//! const Sink = struct {
//!     total: u64 = 0,
//!     pub fn unsigned(self: *@This(), id: sofab.Id, v: u64) void { ... }
//!     pub fn signed(self: *@This(), id: sofab.Id, v: i64) void { ... }
//!     pub fn fp32(self: *@This(), id: sofab.Id, v: f32) void { ... }
//!     pub fn fp64(self: *@This(), id: sofab.Id, v: f64) void { ... }
//!     // string/blob chunks: `total` is the field length, `offset` the chunk
//!     // position; a contiguous decode delivers one whole-payload chunk.
//!     pub fn string(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void { ... }
//!     pub fn blob(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void { ... }
//!     pub fn arrayBegin(self: *@This(), id: sofab.Id, kind: sofab.ArrayKind, count: usize) void { ... }
//!     pub fn sequenceBegin(self: *@This(), id: sofab.Id) void { ... }
//!     pub fn sequenceEnd(self: *@This()) void { ... }
//! };
//! ```

const std = @import("std");
const types = @import("types.zig");
const varint = @import("varint.zig");

const Error = types.Error;
const Id = types.Id;
const Unsigned = types.Unsigned;
const Signed = types.Signed;
const FixlenType = types.FixlenType;
const ArrayKind = types.ArrayKind;

/// Upper bound for the bytes of a single small wire item (field header +
/// length/count words + a partial fixed-width payload) that can straddle a
/// chunk boundary. Anything larger — string/blob payloads, array elements — is
/// streamed via `Resume`, never buffered.
const CARRY_CAP = 64;

/// What the decoder was in the middle of when the previous chunk ran out.
///
/// Small items (a split varint or float) are not represented here — they are
/// carried as raw bytes and re-parsed; this union captures only the
/// coarse-grained "I am partway through a long thing" states whose progress
/// must survive across chunks without re-delivery.
const Resume = union(enum) {
    none,
    /// Mid string/blob payload (delivered incrementally).
    payload: struct { id: Id, is_blob: bool, total: usize, remaining: usize },
    /// Mid integer array: `remaining` elements still to read.
    array_int: struct { id: Id, signed: bool, remaining: usize },
    /// Mid fixlen (float) array: `remaining` elements of 4/8 bytes each.
    array_fix: struct { id: Id, fp64: bool, remaining: usize },
};

/// The decode outcome at the point the caller has run out of input, per the
/// three distinct outcomes of MESSAGE_SPEC §7. The third outcome, INVALID, is
/// not represented here: malformed bytes are rejected eagerly with
/// `error.InvalidMessage` while `feed`/`parse` is still consuming them, so a
/// `Status` is only ever produced for input that is well-formed so far.
pub const Status = enum {
    /// The bytes fed so far end exactly at a field boundary — a valid whole
    /// message (COMPLETE).
    complete,
    /// A field is half-read, a long payload/array is still in progress, or a
    /// sequence is still open — more bytes could complete the message
    /// (INCOMPLETE). This is **never** an error: the caller owns end-of-input
    /// and decides, from its own framing, whether a trailing `.incomplete` is a
    /// truncation failure or simply a short read.
    incomplete,
};

/// Streaming Sofab decoder. Reusable across messages via `reset`. Owns no
/// heap memory — all state lives inline in the struct.
pub const IStream = struct {
    /// Bytes of an item that straddled a chunk boundary, carried to the next
    /// `feed`. Only ever holds a partial small item (header / varint / float);
    /// large payloads are streamed, not buffered.
    carry: [CARRY_CAP]u8 = undefined,
    carry_len: usize = 0,
    state: Resume = .none,
    /// Nested sequence depth, for balanced start/end validation.
    depth: u32 = 0,

    /// Create a fresh decoder ready to accept a new message.
    pub fn init() IStream {
        return .{};
    }

    /// Reset to the initial state so the decoder can be reused for a new
    /// message.
    pub fn reset(self: *IStream) void {
        self.* = .{};
    }

    /// Feed a chunk of encoded bytes, pushing decoded fields to `visitor` (a
    /// pointer to any struct implementing the callbacks it cares about).
    ///
    /// Returns the decode `Status` reached after consuming the chunk —
    /// `.complete` if the bytes so far end at a field boundary, `.incomplete`
    /// if an item is still in progress (the plan's `feed(chunk)→status` shape,
    /// so no separate finalization call is needed). Malformed input is rejected
    /// eagerly with `error.InvalidMessage`. Decoding can continue across any
    /// number of `feed` calls; the decoder keeps all state internally and
    /// suspends/resumes at any byte boundary. `status` re-queries the same value
    /// without feeding more bytes.
    pub fn feed(self: *IStream, chunk: []const u8, visitor: anytype) Error!Status {
        var input = chunk;
        // Finish a small item carried from the previous chunk: stitch input
        // bytes onto it until it completes, then fall through to the direct
        // zero-copy path for the rest of the chunk.
        while (self.carry_len > 0 and input.len > 0) {
            const n = @min(CARRY_CAP - self.carry_len, input.len);
            if (n == 0) return Error.InvalidMessage; // cannot happen: items are < CARRY_CAP
            @memcpy(self.carry[self.carry_len..][0..n], input[0..n]);
            self.carry_len += n;
            input = input[n..];
            const consumed = try self.parse(self.carry[0..self.carry_len], visitor);
            if (consumed > 0) {
                std.mem.copyForwards(
                    u8,
                    self.carry[0 .. self.carry_len - consumed],
                    self.carry[consumed..self.carry_len],
                );
                self.carry_len -= consumed;
            }
        }
        if (self.carry_len > 0) return self.status(); // chunk exhausted, item still incomplete

        // Fast path: parse straight from the caller's slice, no copy.
        const consumed = try self.parse(input, visitor);
        if (consumed < input.len) {
            const rest = input[consumed..];
            @memcpy(self.carry[0..rest.len], rest);
            self.carry_len = rest.len;
        }
        return self.status();
    }

    /// Report the decoder's outcome at the point the caller has run out of
    /// input (MESSAGE_SPEC §7), as a pure read-only accessor — it never mutates
    /// the decoder and never turns an incomplete decode into an error. `feed`
    /// already returns this value after each chunk; `status` lets a caller
    /// re-query it at end-of-input without feeding more bytes. There is
    /// deliberately no `finish()`/`finalize()` call: the plan's streaming
    /// contract (§5, §6.1) surfaces the outcome through `feed(chunk)→status`
    /// with no finalization step.
    ///
    /// * `.complete` when the bytes fed so far end exactly at a field boundary —
    ///   a valid whole message;
    /// * `.incomplete` when a field is half-read (`carry_len != 0`), a long
    ///   payload/array is still in progress (`state != .none`), or a sequence is
    ///   still open (`depth != 0`). The caller — which owns end-of-input —
    ///   decides from its own framing whether a trailing `.incomplete` is a
    ///   truncation error or simply a short read.
    ///
    /// Genuinely-malformed input never reaches here: it is rejected with
    /// `error.InvalidMessage` while `feed`/`parse` is still consuming bytes.
    pub fn status(self: *const IStream) Status {
        return if (self.carry_len != 0 or self.state != .none or self.depth != 0)
            .incomplete
        else
            .complete;
    }

    /// Parse as many complete fields as possible from `buf`, returning the
    /// number of bytes fully consumed. Whatever follows the returned offset is
    /// an incomplete small item the caller must carry to the next chunk. Long
    /// payloads (string/blob) and array progress are committed via
    /// `self.state`, so they are never re-delivered.
    fn parse(self: *IStream, buf: []const u8, visitor: anytype) Error!usize {
        const V = std.meta.Child(@TypeOf(visitor));
        var pos: usize = 0;
        while (true) {
            // 1) Finish anything left in progress from a previous chunk.
            switch (self.state) {
                .none => {},
                .payload => {
                    pos = self.deliverPayload(buf, pos, visitor);
                    if (self.state == .payload) return pos; // still hungry
                    continue;
                },
                .array_int => |st| {
                    var rem = st.remaining;
                    while (rem > 0) {
                        const elem_start = pos;
                        if (try varint.readVarint(buf, &pos)) |val| {
                            if (st.signed) {
                                if (comptime @hasDecl(V, "signed"))
                                    visitor.signed(st.id, varint.zigzagDecode(val));
                            } else {
                                if (comptime @hasDecl(V, "unsigned"))
                                    visitor.unsigned(st.id, val);
                            }
                            rem -= 1;
                        } else {
                            self.state = .{ .array_int = .{
                                .id = st.id,
                                .signed = st.signed,
                                .remaining = rem,
                            } };
                            return elem_start;
                        }
                    }
                    self.state = .none;
                    continue;
                },
                .array_fix => |st| {
                    const elem_len: usize = if (st.fp64) 8 else 4;
                    var rem = st.remaining;
                    while (rem > 0) {
                        if (buf.len - pos < elem_len) {
                            self.state = .{ .array_fix = .{
                                .id = st.id,
                                .fp64 = st.fp64,
                                .remaining = rem,
                            } };
                            return pos;
                        }
                        emitFixlenValue(buf, pos, st.fp64, st.id, visitor);
                        pos += elem_len;
                        rem -= 1;
                    }
                    self.state = .none;
                    continue;
                },
            }

            // 2) Read the next field header.
            if (pos >= buf.len) return pos;
            const field_start = pos;
            const header = (try varint.readVarint(buf, &pos)) orelse return field_start;
            const wire: u3 = @truncate(header);
            const id_raw = header >> 3;
            if (id_raw > types.ID_MAX) return Error.InvalidMessage;
            const id: Id = @intCast(id_raw);

            switch (wire) {
                types.T_VARINT_UNSIGNED => {
                    const val = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    if (comptime @hasDecl(V, "unsigned")) visitor.unsigned(id, val);
                },
                types.T_VARINT_SIGNED => {
                    const zz = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    if (comptime @hasDecl(V, "signed")) visitor.signed(id, varint.zigzagDecode(zz));
                },

                types.T_FIXLEN => {
                    const word = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    const subtype = try FixlenType.fromRaw(@truncate(word));
                    if (word >> 3 > types.FIXLEN_MAX) return Error.InvalidMessage;
                    const len: usize = @intCast(word >> 3);
                    switch (subtype) {
                        .fp32, .fp64 => {
                            const want: usize = if (subtype == .fp64) 8 else 4;
                            if (len != want) return Error.InvalidMessage;
                            if (buf.len - pos < want) return field_start; // carry header+word+partial
                            emitFixlenValue(buf, pos, subtype == .fp64, id, visitor);
                            pos += want;
                        },
                        .string, .blob => {
                            const is_blob = subtype == .blob;
                            if (len == 0) {
                                if (is_blob) {
                                    if (comptime @hasDecl(V, "blob")) visitor.blob(id, 0, 0, &.{});
                                } else {
                                    if (comptime @hasDecl(V, "string")) visitor.string(id, 0, 0, &.{});
                                }
                            } else {
                                self.state = .{ .payload = .{
                                    .id = id,
                                    .is_blob = is_blob,
                                    .total = len,
                                    .remaining = len,
                                } };
                                pos = self.deliverPayload(buf, pos, visitor);
                                if (self.state == .payload) return pos;
                            }
                        },
                    }
                },

                types.T_VARINTARRAY_UNSIGNED, types.T_VARINTARRAY_SIGNED => {
                    const count = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    if (count > types.ARRAY_MAX) return Error.InvalidMessage;
                    const is_signed = wire == types.T_VARINTARRAY_SIGNED;
                    if (comptime @hasDecl(V, "arrayBegin"))
                        visitor.arrayBegin(id, if (is_signed) ArrayKind.signed else ArrayKind.unsigned, @intCast(count));
                    if (count > 0) {
                        self.state = .{ .array_int = .{
                            .id = id,
                            .signed = is_signed,
                            .remaining = @intCast(count),
                        } };
                    }
                },
                types.T_FIXLENARRAY => {
                    const count = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    if (count > types.ARRAY_MAX) return Error.InvalidMessage;
                    // A fixlen array **always** carries its `fixlen_word`, even
                    // when empty (count == 0) — this is what distinguishes an
                    // empty fp32 array from an empty fp64 array on the wire
                    // (§4.8).
                    const word = (try varint.readVarint(buf, &pos)) orelse return field_start;
                    const subtype = try FixlenType.fromRaw(@truncate(word));
                    const elem_len: usize = @intCast(word >> 3);
                    // Only fixed-width float subtypes are valid in a fixlen
                    // array; string/blob must use a sequence instead.
                    const fp64 = switch (subtype) {
                        .fp32 => if (elem_len != 4) return Error.InvalidMessage else false,
                        .fp64 => if (elem_len != 8) return Error.InvalidMessage else true,
                        else => return Error.InvalidMessage,
                    };
                    if (comptime @hasDecl(V, "arrayBegin"))
                        visitor.arrayBegin(id, .fixlen, @intCast(count));
                    if (count > 0) {
                        self.state = .{ .array_fix = .{
                            .id = id,
                            .fp64 = fp64,
                            .remaining = @intCast(count),
                        } };
                    }
                },

                types.T_SEQUENCE_START => {
                    // Reject nesting beyond MAX_DEPTH (255) rather than risk
                    // unbounded recursion / stack growth (§4.9, §6.2).
                    if (self.depth >= types.MAX_DEPTH) return Error.InvalidMessage;
                    self.depth += 1;
                    if (comptime @hasDecl(V, "sequenceBegin")) visitor.sequenceBegin(id);
                },
                types.T_SEQUENCE_END => {
                    if (self.depth == 0) return Error.InvalidMessage;
                    self.depth -= 1;
                    if (comptime @hasDecl(V, "sequenceEnd")) visitor.sequenceEnd();
                },
            }
        }
    }

    /// Deliver as much of an in-progress string/blob payload as `buf` holds,
    /// updating `self.state`. Returns the new cursor position.
    fn deliverPayload(self: *IStream, buf: []const u8, pos_in: usize, visitor: anytype) usize {
        const V = std.meta.Child(@TypeOf(visitor));
        var pos = pos_in;
        const st = self.state.payload;
        const avail = @min(buf.len - pos, st.remaining);
        if (avail > 0) {
            const offset = st.total - st.remaining;
            const chunk = buf[pos .. pos + avail];
            if (st.is_blob) {
                if (comptime @hasDecl(V, "blob")) visitor.blob(st.id, st.total, offset, chunk);
            } else {
                if (comptime @hasDecl(V, "string")) visitor.string(st.id, st.total, offset, chunk);
            }
            pos += avail;
            const rem = st.remaining - avail;
            self.state = if (rem == 0) .none else .{ .payload = .{
                .id = st.id,
                .is_blob = st.is_blob,
                .total = st.total,
                .remaining = rem,
            } };
        }
        return pos;
    }
};

/// Decode 4 or 8 little-endian float bytes at `buf[pos..]` and push them to the
/// visitor. Caller guarantees the bytes are present; the loads go through the
/// raw pointer, so no bounds checks in any build mode.
inline fn emitFixlenValue(buf: []const u8, pos: usize, fp64: bool, id: Id, visitor: anytype) void {
    const V = std.meta.Child(@TypeOf(visitor));
    if (fp64) {
        const bits = std.mem.readInt(u64, (buf.ptr + pos)[0..8], .little);
        if (comptime @hasDecl(V, "fp64")) visitor.fp64(id, @bitCast(bits));
    } else {
        const bits = std.mem.readInt(u32, (buf.ptr + pos)[0..4], .little);
        if (comptime @hasDecl(V, "fp32")) visitor.fp32(id, @bitCast(bits));
    }
}

/// Decode a contiguous message in one shot — the fast zero-copy path.
///
/// Every field is pushed to `visitor`; string/blob payloads are delivered as a
/// single borrowed slice with no copy. Surfaces the three-valued outcome of
/// MESSAGE_SPEC §7, identically to the streaming path:
///
/// * returns `.complete` (COMPLETE) — `buf` is a valid whole message ending at
///   a field boundary;
/// * returns `.incomplete` (INCOMPLETE) — `buf` ends inside a field or with a
///   sequence still open; more bytes could complete it. This is **not** a
///   rejection — the caller owns end-of-input and decides whether a truncated
///   trailing item is an error for its framing;
/// * `error.InvalidMessage` (INVALID) — `buf` is malformed regardless of what
///   might follow (bad tag, >64-bit varint, oversized length/count, dangling
///   sequence end, nesting past `MAX_DEPTH`, …).
pub fn decode(buf: []const u8, visitor: anytype) Error!Status {
    var is = IStream.init();
    return is.feed(buf, visitor);
}

// --- unit tests -----------------------------------------------------------------

const testing = std.testing;
const OStream = @import("ostream.zig").OStream;

const Probe = struct {
    unsigned_sum: u64 = 0,
    signed_sum: i64 = 0,
    fp32_bits: u32 = 0,
    fp64_bits: u64 = 0,
    str: [64]u8 = undefined,
    str_len: usize = 0,
    begins: u32 = 0,
    ends: u32 = 0,
    array_count: usize = 0,

    pub fn unsigned(self: *Probe, id: Id, v: Unsigned) void {
        self.unsigned_sum +%= v +% id;
    }
    pub fn signed(self: *Probe, id: Id, v: Signed) void {
        self.signed_sum +%= v +% id;
    }
    pub fn fp32(self: *Probe, _: Id, v: f32) void {
        self.fp32_bits = @bitCast(v);
    }
    pub fn fp64(self: *Probe, _: Id, v: f64) void {
        self.fp64_bits = @bitCast(v);
    }
    pub fn string(self: *Probe, _: Id, _: usize, offset: usize, chunk: []const u8) void {
        @memcpy(self.str[offset..][0..chunk.len], chunk);
        self.str_len = offset + chunk.len;
    }
    pub fn arrayBegin(self: *Probe, _: Id, _: ArrayKind, count: usize) void {
        self.array_count = count;
    }
    pub fn sequenceBegin(self: *Probe, _: Id) void {
        self.begins += 1;
    }
    pub fn sequenceEnd(self: *Probe) void {
        self.ends += 1;
    }
};

fn encodeSample(buf: []u8) usize {
    var os = OStream.init(buf);
    os.writeUnsigned(1, 42) catch unreachable;
    os.writeSigned(2, -7) catch unreachable;
    os.writeFp32(3, 1.5) catch unreachable;
    os.writeFp64(4, -2.5) catch unreachable;
    os.writeString(5, "hello") catch unreachable;
    os.writeArrayUnsigned(6, &[_]u16{ 10, 20, 30 }) catch unreachable;
    os.writeSequenceBegin(7) catch unreachable;
    os.writeUnsigned(1, 99) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
    return os.bytesUsed();
}

test "one-shot decode delivers every field" {
    var buf: [128]u8 = undefined;
    const used = encodeSample(&buf);

    var p: Probe = .{};
    try testing.expectEqual(Status.complete, try decode(buf[0..used], &p));
    try testing.expectEqual(@as(u64, 42 + 1 + (10 + 20 + 30) + 6 * 3 + 99 + 1), p.unsigned_sum);
    try testing.expectEqual(@as(i64, -7 + 2), p.signed_sum);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), p.fp32_bits);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -2.5))), p.fp64_bits);
    try testing.expectEqualStrings("hello", p.str[0..p.str_len]);
    try testing.expectEqual(@as(usize, 3), p.array_count);
    try testing.expectEqual(@as(u32, 1), p.begins);
    try testing.expectEqual(@as(u32, 1), p.ends);
}

test "one-byte-at-a-time feed matches one-shot decode" {
    var buf: [128]u8 = undefined;
    const used = encodeSample(&buf);

    var whole: Probe = .{};
    try testing.expectEqual(Status.complete, try decode(buf[0..used], &whole));

    var chunked: Probe = .{};
    var is = IStream.init();
    for (buf[0..used]) |b| _ = try is.feed(&.{b}, &chunked);
    try testing.expectEqual(Status.complete, is.status());

    try testing.expectEqual(whole.unsigned_sum, chunked.unsigned_sum);
    try testing.expectEqual(whole.signed_sum, chunked.signed_sum);
    try testing.expectEqual(whole.fp32_bits, chunked.fp32_bits);
    try testing.expectEqual(whole.fp64_bits, chunked.fp64_bits);
    try testing.expectEqualStrings("hello", chunked.str[0..chunked.str_len]);
}

test "visitor with no callbacks skips everything (auto-skip)" {
    var buf: [128]u8 = undefined;
    const used = encodeSample(&buf);
    const Nothing = struct {};
    var sink: Nothing = .{};
    _ = try decode(buf[0..used], &sink);
}

test "truncated message reports Incomplete, not rejection" {
    // The sample ends with a sequence-end byte; dropping it leaves a sequence
    // open at end-of-input. Per MESSAGE_SPEC §7 that is INCOMPLETE (more bytes
    // could close it), distinct from both COMPLETE and INVALID — never promoted
    // to error.InvalidMessage.
    var buf: [128]u8 = undefined;
    const used = encodeSample(&buf);
    const Nothing = struct {};
    var sink: Nothing = .{};
    try testing.expectEqual(Status.incomplete, try decode(buf[0 .. used - 1], &sink));
}

test "lone dangling 0x80 is Incomplete; a >64-bit varint is InvalidMessage" {
    const Nothing = struct {};
    // A single 0x80 (continuation bit set, no terminating byte) ends inside a
    // varint: INCOMPLETE, not INVALID.
    var sink: Nothing = .{};
    try testing.expectEqual(Status.incomplete, try decode(&.{0x80}, &sink));

    // Eleven continuation bytes overflow any u64 varint: malformed regardless
    // of what follows, so INVALID.
    var sink2: Nothing = .{};
    const all_continuation: [11]u8 = @splat(0x80);
    try testing.expectError(Error.InvalidMessage, decode(&all_continuation, &sink2));
}

test "dangling sequence end is rejected" {
    const Nothing = struct {};
    var sink: Nothing = .{};
    try testing.expectError(Error.InvalidMessage, decode(&.{0x07}, &sink));
}

test "nesting past MAX_DEPTH is rejected" {
    var buf: [512]u8 = undefined;
    // 256 nested sequence starts at id 1: header (1 << 3) | 6 = 0x0E each.
    for (0..256) |i| buf[i] = 0x0E;
    const Nothing = struct {};
    var sink: Nothing = .{};
    var is = IStream.init();
    try testing.expectError(Error.InvalidMessage, is.feed(buf[0..256], &sink));
}

test "field id above ID_MAX is rejected" {
    // header = (2^31 << 3) | 0 — a valid varint whose id exceeds ID_MAX.
    const bytes = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x00 };
    const Nothing = struct {};
    var sink: Nothing = .{};
    try testing.expectError(Error.InvalidMessage, decode(&bytes, &sink));
}

test "reserved fixlen subtypes and bad float lengths are rejected" {
    const Nothing = struct {};
    var sink: Nothing = .{};
    // fixlen subtype 0x4 (reserved): header 0x02, word (1 << 3) | 4.
    try testing.expectError(Error.InvalidMessage, decode(&.{ 0x02, 0x0C, 0x00 }, &sink));
    // fp32 with length 5: word (5 << 3) | 0.
    try testing.expectError(Error.InvalidMessage, decode(&.{ 0x02, 0x28, 0, 0, 0, 0, 0 }, &sink));
    // string/blob subtype in a fixlen array: count 1, word (1 << 3) | 2.
    try testing.expectError(Error.InvalidMessage, decode(&.{ 0x05, 0x01, 0x0A, 0x61 }, &sink));
}

test "decoder reuse via reset" {
    var buf: [128]u8 = undefined;
    const used = encodeSample(&buf);
    const Nothing = struct {};
    var sink: Nothing = .{};
    var is = IStream.init();
    try testing.expectError(Error.InvalidMessage, is.feed(&.{0x07}, &sink));
    is.reset();
    _ = try is.feed(buf[0..used], &sink);
    try testing.expectEqual(Status.complete, is.status());
}
