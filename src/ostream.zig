//! Streaming output stream encoder.
//!
//! `OStream` writes Sofab fields into a caller-owned byte buffer. When the
//! buffer fills it hands the bytes to an optional flush sink and resumes at the
//! start of the buffer, so messages larger than the buffer can be streamed out
//! (ARCHITECTURE §5.1). With no sink, a full buffer yields `error.BufferFull`.
//!
//! For the common case where you just want the bytes in a growable list, drive
//! a small scratch buffer with a flush callback that appends to an
//! `std.ArrayList` — that is the back end of the generated-object `serialize()`
//! helper (ARCHITECTURE §6.1).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const varint = @import("varint.zig");
const utf8 = @import("utf8.zig");

const native_endian = builtin.cpu.arch.endian();

const Error = types.Error;
const Id = types.Id;
const Unsigned = types.Unsigned;
const Signed = types.Signed;
const FixlenType = types.FixlenType;

/// Sink that receives buffered bytes when the output buffer is flushed. Called
/// with the bytes accumulated since the last flush; `ctx` is the opaque pointer
/// registered alongside the callback (e.g. a transport or an output list).
pub const FlushFn = *const fn (ctx: ?*anyopaque, data: []const u8) void;

/// Streaming Sofab encoder writing into a caller-provided buffer.
pub const OStream = struct {
    buffer: []u8,
    offset: usize,
    /// Number of nested sequences currently open, capped at `MAX_DEPTH`.
    depth: u32 = 0,
    /// Ids of the innermost open sequences whose header has not been written
    /// yet (MESSAGE_SPEC §2 lazy framing). Always a contiguous suffix of the
    /// open sequences: writing any field commits the whole run at once, so
    /// `writeSequenceEnd` can drop the innermost by popping the last entry.
    ///
    /// The hold-back reaches the **full `MAX_DEPTH`** (CORELIB_PLAN §6, "How
    /// deep the hold-back reaches"), so this encoder is canonical at every
    /// depth the format allows: there is no window past which it falls back to
    /// eager framing and emits the empty frame §2 omits. Only a heap-free
    /// profile may bound the run, and any bound has to be documented — two
    /// encoders that disagree about it disagree about *bytes*. This port keeps
    /// its allocation-free contract instead and reserves the run inline,
    /// `MAX_DEPTH` entries, which is why an `OStream` is a kilobyte-sized value
    /// (1072 bytes on a 64-bit target). `depth` is checked against `MAX_DEPTH`
    /// before a push and `npending <= depth` always holds, so the array cannot
    /// overflow.
    pending: [types.MAX_DEPTH]Id = undefined,
    /// Number of valid entries in `pending`.
    npending: usize = 0,
    /// `null` means "no sink": a full buffer is an error rather than a flush.
    flush_fn: ?FlushFn = null,
    flush_ctx: ?*anyopaque = null,

    /// Create an encoder over `buffer` with no flush sink. Writing past the
    /// end of the buffer returns `error.BufferFull`.
    pub fn init(buffer: []u8) OStream {
        return .{ .buffer = buffer, .offset = 0 };
    }

    /// Like `init` but begin writing at `offset` bytes into the buffer,
    /// reserving space for a lower-layer protocol header.
    pub fn initOffset(buffer: []u8, offset: usize) OStream {
        return .{ .buffer = buffer, .offset = offset };
    }

    /// Create an encoder with a flush sink, starting at `offset`. When the
    /// buffer fills, the accumulated bytes are passed to `flush_fn` and
    /// writing resumes at the start of the buffer.
    pub fn initFlush(buffer: []u8, offset: usize, ctx: ?*anyopaque, flush_fn: FlushFn) OStream {
        return .{ .buffer = buffer, .offset = offset, .flush_fn = flush_fn, .flush_ctx = ctx };
    }

    /// Number of bytes written to the active buffer since the last flush.
    pub fn bytesUsed(self: *const OStream) usize {
        return self.offset;
    }

    /// Flush any pending bytes to the sink (if one is set) and report how many
    /// bytes were pending. With no sink the buffer is left intact.
    pub fn flush(self: *OStream) usize {
        const used = self.offset;
        if (used > 0) {
            if (self.flush_fn) |sink| {
                sink(self.flush_ctx, self.buffer[0..used]);
                self.offset = 0;
            }
        }
        return used;
    }

    /// Replace the active buffer (typically called from within a flush sink),
    /// resuming writes at `offset` in the new buffer.
    pub fn bufferSet(self: *OStream, buffer: []u8, offset: usize) void {
        self.buffer = buffer;
        self.offset = offset;
    }

    // --- primitives ---------------------------------------------------------

    /// Append a single byte, draining the buffer to the sink first if it is
    /// full. The store goes through the raw pointer: the bounds are guaranteed
    /// by the drain check, so no per-byte bounds check in any build mode.
    inline fn pushByte(self: *OStream, b: u8) Error!void {
        if (self.offset >= self.buffer.len) try self.drainFull();
        self.buffer.ptr[self.offset] = b;
        self.offset += 1;
    }

    /// Cold path: the buffer is full — flush it or report `BufferFull`.
    fn drainFull(self: *OStream) Error!void {
        @branchHint(.cold);
        const sink = self.flush_fn orelse return Error.BufferFull;
        sink(self.flush_ctx, self.buffer[0..self.offset]);
        self.offset = 0;
    }

    /// Copy a raw byte slice out, draining the buffer as needed. Uses a bulk
    /// `@memcpy` per buffer-sized run rather than a byte-at-a-time loop.
    fn pushRaw(self: *OStream, data: []const u8) Error!void {
        var rest = data;
        while (rest.len > 0) {
            if (self.offset >= self.buffer.len) try self.drainFull();
            const n = @min(self.buffer.len - self.offset, rest.len);
            @memcpy(self.buffer[self.offset..][0..n], rest[0..n]);
            self.offset += n;
            rest = rest[n..];
        }
    }

    /// Encode `value` as a base-128 (LEB128) varint: 7 payload bits per byte,
    /// low byte first, with the high bit set on every byte but the last.
    ///
    /// Fast path: when a maximum-length varint is guaranteed to fit in the
    /// remaining buffer, the bytes are stored through the raw pointer with no
    /// per-byte capacity check.
    inline fn writeVarint(self: *OStream, value: Unsigned) Error!void {
        if (self.buffer.len - self.offset >= varint.MAX_VARINT_LEN) {
            var v = value;
            var i = self.offset;
            while (v >= 0x80) {
                self.buffer.ptr[i] = @as(u8, @truncate(v)) | 0x80;
                v >>= 7;
                i += 1;
            }
            self.buffer.ptr[i] = @truncate(v);
            self.offset = i + 1;
            return;
        }
        return self.writeVarintSlow(value);
    }

    /// Byte-at-a-time varint encode used near the end of the buffer, where
    /// each byte may trigger a drain/flush.
    fn writeVarintSlow(self: *OStream, value: Unsigned) Error!void {
        var v = value;
        while (true) {
            var b: u8 = @as(u8, @truncate(v)) & 0x7F;
            v >>= 7;
            if (v != 0) b |= 0x80;
            try self.pushByte(b);
            if (v == 0) return;
        }
    }

    /// Write a field header: the `(id << 3) | wire_type` tag as a varint.
    /// Returns `error.InvalidArgument` for an `id` above `ID_MAX`.
    ///
    /// This is the single choke point every field write passes through — every
    /// scalar, fixlen, float, string, blob and both array kinds reach the wire
    /// through here — so it is also where a held-back sequence run is
    /// committed: the field about to be written is content, which means every
    /// enclosing sequence is non-default and must be framed after all.
    inline fn writeIdType(self: *OStream, id: Id, wire_type: u3) Error!void {
        if (id > types.ID_MAX) return Error.InvalidArgument;
        if (self.npending != 0 and
            wire_type != types.T_SEQUENCE_START and wire_type != types.T_SEQUENCE_END)
        {
            try self.commitPending();
        }
        try self.writeVarint((@as(Unsigned, id) << 3) | wire_type);
    }

    /// Write out the held-back sequence headers, outermost first.
    ///
    /// Cold and `noinline`: it runs at most once per non-default sequence,
    /// never per field, and keeping it out of line keeps the `writeIdType`
    /// choke point — which every single field write inlines — small.
    ///
    /// An entry is dropped from the run only once its header is on its way out,
    /// so a `BufferFull` partway through leaves `pending` describing exactly the
    /// sequences that are still open *and* still unframed. Zeroing `npending`
    /// up front instead would lose the rest of the run: a caller that recovers
    /// (`bufferSet` with a fresh buffer) would then emit end markers for
    /// sequences whose headers were never written — a structurally broken
    /// message rather than a truncated one.
    noinline fn commitPending(self: *OStream) Error!void {
        @branchHint(.cold);
        const n = self.npending;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.writeVarint((@as(Unsigned, self.pending[i]) << 3) | types.T_SEQUENCE_START) catch |err| {
                // Keep the unwritten suffix — including the entry that failed,
                // whose header may have made it out only in part — as the new
                // pending run, still a contiguous suffix of the open sequences.
                const rest = n - i;
                std.mem.copyForwards(Id, self.pending[0..rest], self.pending[i..n]);
                self.npending = rest;
                return err;
            };
        }
        self.npending = 0;
    }

    // --- scalar writers -----------------------------------------------------

    /// Write an unsigned-integer field.
    pub fn writeUnsigned(self: *OStream, id: Id, value: Unsigned) Error!void {
        try self.writeIdType(id, types.T_VARINT_UNSIGNED);
        try self.writeVarint(value);
    }

    /// Write a signed-integer field (ZigZag + varint).
    pub fn writeSigned(self: *OStream, id: Id, value: Signed) Error!void {
        try self.writeIdType(id, types.T_VARINT_SIGNED);
        try self.writeVarint(varint.zigzagEncode(value));
    }

    /// Write a boolean as an unsigned `0` / `1` (booleans have no wire type of
    /// their own, §4.4).
    pub fn writeBoolean(self: *OStream, id: Id, value: bool) Error!void {
        try self.writeUnsigned(id, @intFromBool(value));
    }

    // --- fixed-length writers ------------------------------------------------

    /// Write a fixed-length field: header, `(len << 3) | subtype` varint, then
    /// the raw `data` bytes (already in wire/little-endian order for floats).
    pub fn writeFixlen(self: *OStream, id: Id, data: []const u8, subtype: FixlenType) Error!void {
        if (data.len > types.FIXLEN_MAX) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_FIXLEN);
        try self.writeVarint((@as(Unsigned, data.len) << 3) | @intFromEnum(subtype));
        try self.pushRaw(data);
    }

    /// Write a 32-bit float field.
    pub fn writeFp32(self: *OStream, id: Id, value: f32) Error!void {
        const le = std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(value)));
        try self.writeFixlen(id, &le, .fp32);
    }

    /// Write a 64-bit float field.
    pub fn writeFp64(self: *OStream, id: Id, value: f64) Error!void {
        const le = std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(value)));
        try self.writeFixlen(id, &le, .fp64);
    }

    /// Write a string field (UTF-8 bytes, no NUL on the wire).
    ///
    /// Under `SOFAB_STRICT_UTF8` (on by default, CORELIB_PLAN §6.4) a `string`
    /// value that is not valid UTF-8 is refused with `error.InvalidArgument`:
    /// encode-side validation enforces MESSAGE_SPEC §8's producer-side MUST NOT,
    /// so a strict ecosystem's own encoders cannot emit bytes its decoders
    /// reject. When the option is compiled off the check folds away and the
    /// bytes are written verbatim.
    pub fn writeString(self: *OStream, id: Id, text: []const u8) Error!void {
        if (comptime utf8.STRICT_UTF8) {
            if (!utf8.utf8_valid(text)) return Error.InvalidArgument;
        }
        try self.writeFixlen(id, text, .string);
    }

    /// Write a binary blob field.
    pub fn writeBlob(self: *OStream, id: Id, data: []const u8) Error!void {
        try self.writeFixlen(id, data, .blob);
    }

    // --- array writers --------------------------------------------------------

    /// Write an array of unsigned integers. `data` is a slice (or pointer to
    /// array) of any unsigned integer type up to 64 bits — the declared element
    /// width affects only the API, not the wire bytes (§4.7).
    ///
    /// A zero-count array is a valid empty array on the wire — it encodes as
    /// exactly `[ header ][ element_count = 0 ]` with no elements.
    pub fn writeArrayUnsigned(self: *OStream, id: Id, data: anytype) Error!void {
        const E = std.meta.Elem(@TypeOf(data));
        comptime {
            const info = @typeInfo(E);
            if (info != .int or info.int.signedness != .unsigned or info.int.bits > 64)
                @compileError("writeArrayUnsigned expects elements of u8..u64, got " ++ @typeName(E));
        }
        if (data.len > types.ARRAY_MAX) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_VARINTARRAY_UNSIGNED);
        try self.writeVarint(@as(Unsigned, data.len));
        for (data) |e| try self.writeVarint(e);
    }

    /// Write an array of signed integers (`i8`/`i16`/`i32`/`i64` elements).
    ///
    /// A zero-count array encodes as exactly `[ header ][ element_count = 0 ]`
    /// with no elements (§4.7).
    pub fn writeArraySigned(self: *OStream, id: Id, data: anytype) Error!void {
        const E = std.meta.Elem(@TypeOf(data));
        comptime {
            const info = @typeInfo(E);
            if (info != .int or info.int.signedness != .signed or info.int.bits > 64)
                @compileError("writeArraySigned expects elements of i8..i64, got " ++ @typeName(E));
        }
        if (data.len > types.ARRAY_MAX) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_VARINTARRAY_SIGNED);
        try self.writeVarint(@as(Unsigned, data.len));
        for (data) |e| try self.writeVarint(varint.zigzagEncode(e));
    }

    /// Write an array of 32-bit floats.
    ///
    /// A fixlen array **always** carries its `fixlen_word` (the shared element
    /// subtype/width word), even when the array is empty — a zero-count fixlen
    /// array encodes as `[ header ][ element_count = 0 ][ fixlen_word ]` with
    /// no payload, so an empty fp32 array is distinguishable from an empty fp64
    /// array on the wire (§4.8).
    pub fn writeArrayFp32(self: *OStream, id: Id, data: []const f32) Error!void {
        if (data.len > types.ARRAY_MAX) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_FIXLENARRAY);
        try self.writeVarint(@as(Unsigned, data.len));
        try self.writeVarint((4 << 3) | @as(Unsigned, @intFromEnum(FixlenType.fp32)));
        if (comptime native_endian == .little) {
            // Little-endian host: the in-memory floats already are the wire
            // payload — one bulk copy for the whole array.
            try self.pushRaw(std.mem.sliceAsBytes(data));
        } else {
            for (data) |e| {
                const le = std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(e)));
                try self.pushRaw(&le);
            }
        }
    }

    /// Write an array of 64-bit floats. See `writeArrayFp32` for the empty-array
    /// `fixlen_word` rule.
    pub fn writeArrayFp64(self: *OStream, id: Id, data: []const f64) Error!void {
        if (data.len > types.ARRAY_MAX) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_FIXLENARRAY);
        try self.writeVarint(@as(Unsigned, data.len));
        try self.writeVarint((8 << 3) | @as(Unsigned, @intFromEnum(FixlenType.fp64)));
        if (comptime native_endian == .little) {
            try self.pushRaw(std.mem.sliceAsBytes(data));
        } else {
            for (data) |e| {
                const le = std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(e)));
                try self.pushRaw(&le);
            }
        }
    }

    // --- sequence writers -------------------------------------------------------

    /// Open a nested sequence whose header is **held back** until the sequence
    /// turns out to have content.
    ///
    /// MESSAGE_SPEC §2 omits a sequence-typed field whose value equals its
    /// declared default, and "not one child was written" is exactly that
    /// condition — evaluated per child field, recursively, for free. A sequence
    /// closed with nothing in it therefore emits **nothing** instead of a
    /// two-byte empty frame, and an all-default message becomes the empty byte
    /// string.
    ///
    /// The predicate is never a byte image of the object, so struct padding
    /// cannot influence it and a non-zero nested default is handled by the
    /// caller's ordinary per-field test.
    ///
    /// This is the only way to open a sequence. How it closes decides whether a
    /// contentless one survives: `writeSequenceEnd` drops it,
    /// `writeSequenceEndKeep` forces the frame out.
    ///
    /// The hold-back is **unbounded up to `MAX_DEPTH`** (CORELIB_PLAN §6): a
    /// sequence nested 255 deep and closed contentless still emits nothing, so
    /// the bytes are canonical at every depth the format permits.
    ///
    /// Returns `error.InvalidArgument` if more than `MAX_DEPTH` (255) sequences
    /// would be open at once (§4.9), or for an `id` above `ID_MAX`.
    pub fn writeSequenceBeginLazy(self: *OStream, id: Id) Error!void {
        if (self.depth >= types.MAX_DEPTH) return Error.InvalidArgument;
        if (id > types.ID_MAX) return Error.InvalidArgument;
        // `pending` holds `MAX_DEPTH` entries and the depth check above ran
        // first, so there is always room: the hold-back reaches every depth the
        // format allows and never falls back to eager framing.
        self.pending[self.npending] = id;
        self.npending += 1;
        self.depth += 1;
    }

    /// Close the most recently opened nested sequence, letting it **vanish** if
    /// it received no content.
    ///
    /// Use it wherever absence encodes the same value as an empty frame: a
    /// `struct`/`union` field, and an array field whose declared `default` is
    /// the empty collection (MESSAGE_SPEC §2). Where the frame must be visible,
    /// close with `writeSequenceEndKeep` instead.
    pub fn writeSequenceEnd(self: *OStream) Error!void {
        if (self.npending != 0) {
            // The innermost open sequence is the last held-back one: drop it,
            // header and end marker both.
            self.npending -= 1;
            self.depth -|= 1;
            return;
        }
        try self.writeIdType(0, types.T_SEQUENCE_END);
        self.depth -|= 1;
    }

    /// Close the most recently opened nested sequence, **keeping** its frame
    /// even when it received no content.
    ///
    /// Behaves like a write: it first emits any held-back headers — this
    /// frame's and every enclosing one's — and then the end marker, so an empty
    /// sequence reaches the wire as `begin` + `end`.
    ///
    /// Required wherever the frame carries information beyond its contents:
    /// - a **wrapper-array element** (`struct`/`union`/nested row): element
    ///   presence is what carries a dynamic array's length — *highest present
    ///   id + 1* (§5.1) — so dropping an all-default element would change the
    ///   decoded length, not just the bytes;
    /// - an array field already known to **differ from a non-empty declared
    ///   `default`**: absence would reconstruct that default, so the empty
    ///   frame is the only encoding of "explicitly empty" (§2, §3).
    ///
    /// The two failure directions are not symmetric, which is why this is the
    /// safe choice when in doubt: using it where `writeSequenceEnd` would do
    /// costs one non-canonical empty frame that a decoder normalizes away,
    /// while the reverse silently changes an array's length.
    pub fn writeSequenceEndKeep(self: *OStream) Error!void {
        if (self.npending != 0) try self.commitPending();
        try self.writeIdType(0, types.T_SEQUENCE_END);
        self.depth -|= 1;
    }
};

// --- unit tests -----------------------------------------------------------------

const testing = std.testing;

test "worked example from the spec (§4.10): unsigned 127 at id 0" {
    var buf: [8]u8 = undefined;
    var os = OStream.init(&buf);
    try os.writeUnsigned(0, 127);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x7F }, buf[0..os.bytesUsed()]);
}

test "boolean maps to unsigned 0/1 (§4.4)" {
    var buf: [8]u8 = undefined;
    var os = OStream.init(&buf);
    try os.writeBoolean(0, true);
    try os.writeBoolean(0, false);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x00, 0x00 }, buf[0..os.bytesUsed()]);
}

test "id above ID_MAX is an argument error" {
    var buf: [16]u8 = undefined;
    var os = OStream.init(&buf);
    try testing.expectError(Error.InvalidArgument, os.writeUnsigned(types.ID_MAX + 1, 1));
    try os.writeUnsigned(types.ID_MAX, 1); // boundary id is fine
}

test "buffer full without a sink" {
    var buf: [3]u8 = undefined;
    var os = OStream.init(&buf);
    try os.writeUnsigned(1, 1);
    try testing.expectError(Error.BufferFull, os.writeUnsigned(2, 300));
}

test "offset reserves framing space" {
    var buf: [8]u8 = @splat(0xAA);
    var os = OStream.initOffset(&buf, 2);
    try os.writeUnsigned(0, 127);
    try testing.expectEqual(@as(usize, 4), os.bytesUsed());
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xAA, 0x00, 0x7F }, buf[0..4]);
}

test "writeString: UTF-8 policy follows SOFAB_STRICT_UTF8 (§6.4)" {
    var buf: [16]u8 = undefined;
    var os = OStream.init(&buf);
    // A valid string is written unconditionally in both build configs.
    try os.writeString(1, "ok\xC2\xA2"); // "ok" + U+00A2
    if (comptime utf8.STRICT_UTF8) {
        // Strict on (default): invalid UTF-8 (overlong NUL) is refused with
        // InvalidArgument and writes nothing further.
        const before = os.bytesUsed();
        try testing.expectError(Error.InvalidArgument, os.writeString(2, &[_]u8{ 0xC0, 0x80 }));
        try testing.expectEqual(before, os.bytesUsed());
    } else {
        // Strict off: bytes are written verbatim, no validation.
        try os.writeString(2, &[_]u8{ 0xC0, 0x80 });
    }
}

test "sequence depth is capped at MAX_DEPTH on the encoder" {
    var buf: [1024]u8 = undefined;
    var os = OStream.init(&buf);
    // 255 nested sequences are allowed; the 256th must be rejected (§4.9).
    var i: u32 = 0;
    while (i < types.MAX_DEPTH) : (i += 1) try os.writeSequenceBeginLazy(1);
    try testing.expectError(Error.InvalidArgument, os.writeSequenceBeginLazy(1));
    // After closing one, opening one more is allowed again: both closers
    // decrement the depth, whether or not the frame reaches the wire.
    try os.writeSequenceEnd();
    try os.writeSequenceBeginLazy(1);
}

// --- lazy sequence framing (MESSAGE_SPEC §2) ------------------------------------

/// Encode via `body` into a scratch buffer and return the bytes written.
fn encoded(buf: []u8, body: anytype) Error![]const u8 {
    var os = OStream.init(buf);
    try body(&os);
    return buf[0..os.bytesUsed()];
}

test "lazy sequence without content emits nothing" {
    // An all-default sequence carries no information, so the field is omitted —
    // where the pre-§2 rule ("a sequence field is always framed") put the
    // two-byte empty frame `0E 07`.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceEnd();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{}, bytes);
}

test "endKeep frames a contentless sequence" {
    // `endKeep` forces a contentless frame onto the wire — the array element
    // and explicit-empty cases of §2/§5.1.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceEndKeep();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x07 }, bytes);
}

test "endKeep commits the enclosing run" {
    // Forcing a frame forces its ancestors too: the outer sequence got content
    // (the inner frame), so it is framed as well.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceBeginLazy(2);
            try os.writeSequenceEndKeep();
            try os.writeSequenceEnd();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x16, 0x07, 0x07 }, bytes);
}

test "endKeep matches end once content exists" {
    // With content it makes no difference — the headers are already out.
    var keep_buf: [16]u8 = undefined;
    const with_keep = try encoded(&keep_buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeUnsigned(0, 42);
            try os.writeSequenceEndKeep();
        }
    }.f);
    var end_buf: [16]u8 = undefined;
    const with_end = try encoded(&end_buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeUnsigned(0, 42);
            try os.writeSequenceEnd();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x00, 0x2A, 0x07 }, with_keep);
    try testing.expectEqualSlices(u8, with_keep, with_end);
}

test "lazy sequence commits the whole run on first content" {
    // One child field commits the whole held-back run, outermost header first,
    // so a non-default leaf deep inside brings every enclosing frame back in
    // wire order.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceBeginLazy(2);
            try os.writeUnsigned(0, 42);
            try os.writeSequenceEnd();
            try os.writeSequenceEnd();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x16, 0x00, 0x2A, 0x07, 0x07 }, bytes);
}

test "lazy sequence drops only the empty inner one" {
    // Only the empty inner sequence drops; the outer one has content (the leaf)
    // and is framed. This is the interleaving the naive "drop the whole run"
    // would get wrong.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceBeginLazy(2);
            try os.writeSequenceEnd();
            try os.writeUnsigned(0, 42);
            try os.writeSequenceEnd();
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x00, 0x2A, 0x07 }, bytes);
}

test "lazy sequence after content is independent" {
    // A lazily framed sequence *after* content in the same scope, and the
    // sibling order, stay intact.
    var buf: [16]u8 = undefined;
    const bytes = try encoded(&buf, struct {
        fn f(os: *OStream) Error!void {
            try os.writeUnsigned(0, 1);
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceEnd();
            try os.writeUnsigned(2, 3);
        }
    }.f);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x10, 0x03 }, bytes);
}

test "a run committed across flushes is byte-identical to the one-shot encode" {
    // What this proves: the same op sequence encoded through a 3-byte flush
    // buffer — so the committed run's own bytes straddle two flushes — yields
    // exactly the bytes of a one-shot encode into a buffer that holds the whole
    // message (CORELIB_PLAN §6).
    //
    // What it deliberately does NOT claim to exercise is a flush landing *while*
    // a header is still held back: that is unreachable by construction, not
    // merely untested. A held-back header occupies no buffer space (the ids are
    // encoder state, never buffer content), and the buffer can only fill through
    // a write — which passes `writeIdType` and therefore commits the run before
    // its first byte. So there is no state in which a pending run is open and a
    // flush occurs, and no test can construct one.
    const Sink = struct {
        out: [64]u8 = undefined,
        len: usize = 0,
        fn push(ctx: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.out[self.len..][0..data.len], data);
            self.len += data.len;
        }
    };
    // Three nested lazy opens: the committed run is three header bytes, so
    // through a 3-byte buffer it fills the buffer exactly and everything after
    // it lands in later flushes.
    const ops = struct {
        fn f(os: *OStream) Error!void {
            try os.writeSequenceBeginLazy(1);
            try os.writeSequenceBeginLazy(2);
            try os.writeSequenceBeginLazy(3);
            try os.writeSequenceBeginLazy(4);
            try os.writeSequenceEnd(); // contentless: dropped either way
            try os.writeUnsigned(0, 42); // commits the run of three
            try os.writeSequenceEnd();
            try os.writeSequenceEnd();
            try os.writeSequenceEnd();
        }
    }.f;

    var one_shot_buf: [32]u8 = undefined;
    const one_shot = try encoded(&one_shot_buf, ops);

    var sink: Sink = .{};
    var tiny: [3]u8 = undefined;
    var os = OStream.initFlush(&tiny, 0, &sink, Sink.push);
    try ops(&os);
    _ = os.flush();

    try testing.expectEqualSlices(u8, &.{ 0x0E, 0x16, 0x1E, 0x00, 0x2A, 0x07, 0x07, 0x07 }, one_shot);
    try testing.expectEqualSlices(u8, one_shot, sink.out[0..sink.len]);
}

test "every writer commits the pending run before its first byte" {
    // The choke point must be *complete*: a writer that composed its header
    // inline would silently drop the enclosing frame. Drive every public writer
    // — scalar, fixlen, float, string, blob, both array kinds — inside a lazily
    // opened sequence and assert the sequence header (id 1 → 0x0E) came out
    // first and the frame closes.
    const cases = .{
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeUnsigned(0, 1);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeSigned(0, -1);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeBoolean(0, true);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeFixlen(0, "x", .blob);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeFp32(0, 1.5);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeFp64(0, 1.5);
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeString(0, "s");
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeBlob(0, &[_]u8{0xAB});
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeArrayUnsigned(0, &[_]u16{ 1, 2 });
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeArraySigned(0, &[_]i16{ -1, 2 });
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeArrayFp32(0, &[_]f32{1.5});
            }
        },
        struct {
            fn f(os: *OStream) Error!void {
                try os.writeArrayFp64(0, &[_]f64{1.5});
            }
        },
    };
    inline for (cases) |case| {
        var buf: [64]u8 = undefined;
        var os = OStream.init(&buf);
        try os.writeSequenceBeginLazy(1);
        try case.f(&os);
        try testing.expectEqual(@as(usize, 0), os.npending); // the run is out
        try os.writeSequenceEnd();
        const bytes = buf[0..os.bytesUsed()];
        try testing.expectEqual(@as(u8, 0x0E), bytes[0]); // (1 << 3) | 0b110
        try testing.expectEqual(@as(u8, 0x07), bytes[bytes.len - 1]);
        try testing.expect(bytes.len > 2); // header + payload + end
    }
}

test "deep nesting closed contentless still emits nothing" {
    // The hold-back has no window (CORELIB_PLAN §6, "How deep the hold-back
    // reaches"): 40 levels — deeper than any bounded run this port ever had —
    // opened and closed without a single field write must produce ZERO bytes.
    // A bounded run would have framed the levels past its bound eagerly and
    // emitted their empty frames here, which is exactly the non-canonical
    // output §2 no longer wants from an implementation that need not bound.
    var buf: [512]u8 = undefined;
    var os = OStream.init(&buf);
    var i: usize = 0;
    while (i < 40) : (i += 1) try os.writeSequenceBeginLazy(@intCast(i + 1));
    try testing.expectEqual(@as(usize, 40), os.npending);
    i = 0;
    while (i < 40) : (i += 1) try os.writeSequenceEnd();
    try testing.expectEqual(@as(usize, 0), os.npending);
    try testing.expectEqual(@as(u32, 0), os.depth);
    try testing.expectEqualSlices(u8, &.{}, buf[0..os.bytesUsed()]);
}

test "the hold-back run reaches the full MAX_DEPTH" {
    // At the format's ceiling the run still holds every header, and one field
    // at the bottom commits all 255 of them in outermost-first order.
    var buf: [1024]u8 = undefined;
    var os = OStream.init(&buf);
    var i: usize = 0;
    while (i < types.MAX_DEPTH) : (i += 1) try os.writeSequenceBeginLazy(1);
    try testing.expectEqual(@as(usize, types.MAX_DEPTH), os.npending);
    try os.writeUnsigned(0, 7); // content: every enclosing frame is committed
    i = 0;
    while (i < types.MAX_DEPTH) : (i += 1) try os.writeSequenceEnd();
    const bytes = buf[0..os.bytesUsed()];
    try testing.expectEqual(@as(usize, 0), os.npending);
    try testing.expectEqual(@as(u32, 0), os.depth);
    // MAX_DEPTH begin headers (0x0E) + `00 07` + MAX_DEPTH end markers.
    try testing.expectEqual(2 * types.MAX_DEPTH + 2, bytes.len);
    for (bytes[0..types.MAX_DEPTH]) |b| try testing.expectEqual(@as(u8, 0x0E), b);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x07 }, bytes[types.MAX_DEPTH..][0..2]);
    for (bytes[types.MAX_DEPTH + 2 ..]) |b| try testing.expectEqual(@as(u8, 0x07), b);
}

test "a failed commit keeps the rest of the run pending" {
    // `commitPending` drops an entry only once its header is on its way out.
    // A 1-byte buffer with no sink fails on the second header; the two
    // sequences whose headers never made it must still be pending, so a
    // recovering caller frames them rather than emitting orphaned end markers.
    var buf: [1]u8 = undefined;
    var os = OStream.init(&buf);
    try os.writeSequenceBeginLazy(1);
    try os.writeSequenceBeginLazy(2);
    try os.writeSequenceBeginLazy(3);
    try testing.expectError(Error.BufferFull, os.writeUnsigned(0, 1));
    try testing.expectEqual(@as(usize, 2), os.npending);
    try testing.expectEqual(@as(Id, 2), os.pending[0]);
    try testing.expectEqual(@as(Id, 3), os.pending[1]);
}

test "flush drains pending bytes and mid-stream buffer swap works" {
    const Sink = struct {
        out: [64]u8 = undefined,
        len: usize = 0,
        fn push(ctx: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.out[self.len..][0..data.len], data);
            self.len += data.len;
        }
    };
    var sink: Sink = .{};
    var tiny: [2]u8 = undefined;
    var os = OStream.initFlush(&tiny, 0, &sink, Sink.push);
    try os.writeUnsigned(1, 300); // 3 bytes through a 2-byte buffer
    _ = os.flush();
    try testing.expectEqualSlices(u8, &.{ 0x08, 0xAC, 0x02 }, sink.out[0..sink.len]);

    // Swap in a fresh buffer mid-stream and keep writing.
    var tiny2: [4]u8 = undefined;
    os.bufferSet(&tiny2, 0);
    try os.writeUnsigned(0, 127);
    _ = os.flush();
    try testing.expectEqualSlices(u8, &.{ 0x08, 0xAC, 0x02, 0x00, 0x7F }, sink.out[0..sink.len]);
}
