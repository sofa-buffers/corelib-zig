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
    inline fn writeIdType(self: *OStream, id: Id, wire_type: u3) Error!void {
        if (id > types.ID_MAX) return Error.InvalidArgument;
        try self.writeVarint((@as(Unsigned, id) << 3) | wire_type);
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

    /// Write a string field (raw UTF-8 bytes, no NUL on the wire).
    pub fn writeString(self: *OStream, id: Id, text: []const u8) Error!void {
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

    /// Open a nested sequence with the given field `id`.
    ///
    /// Returns `error.InvalidArgument` if more than `MAX_DEPTH` (255) sequences
    /// would be open at once (§4.9).
    pub fn writeSequenceBegin(self: *OStream, id: Id) Error!void {
        if (self.depth >= types.MAX_DEPTH) return Error.InvalidArgument;
        try self.writeIdType(id, types.T_SEQUENCE_START);
        self.depth += 1;
    }

    /// Close the most recently opened nested sequence (the single byte `0x07`).
    pub fn writeSequenceEnd(self: *OStream) Error!void {
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

test "sequence depth is capped at MAX_DEPTH on the encoder" {
    var buf: [1024]u8 = undefined;
    var os = OStream.init(&buf);
    var i: u32 = 0;
    while (i < types.MAX_DEPTH) : (i += 1) try os.writeSequenceBegin(1);
    try testing.expectError(Error.InvalidArgument, os.writeSequenceBegin(1));
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
