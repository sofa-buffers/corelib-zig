//! Base-128 varint and ZigZag codecs.
//!
//! The decode side here is the speed-critical core: a slice reader that
//! **advances a cursor over a contiguous buffer** (the technique shared with
//! `corelib-rs` and Protocol Buffers). When at least one full varint's worth of
//! bytes is guaranteed present, `readVarint` decodes through a raw many-item
//! pointer — no per-byte bounds checks in any build mode; only near the end of
//! the buffer does it fall back to a checked loop that can report "need more
//! bytes" for the streaming decoder.

const std = @import("std");
const types = @import("types.zig");

const Error = types.Error;
const Unsigned = types.Unsigned;
const Signed = types.Signed;

/// Maximum number of bytes an `Unsigned`-width varint can occupy (10 for u64).
pub const MAX_VARINT_LEN: usize = (@bitSizeOf(Unsigned) + 6) / 7;

/// Read one base-128 varint from `buf` starting at `pos.*`.
///
/// * a value — a full varint was decoded; `pos.*` advanced past it.
/// * `null` — `buf` ends mid-varint; `pos.*` is left unchanged so the caller
///   can carry the partial bytes to the next chunk.
/// * `error.InvalidMessage` — the varint is longer than `Unsigned` allows.
pub inline fn readVarint(buf: []const u8, pos: *usize) Error!?Unsigned {
    if (buf.len - pos.* >= MAX_VARINT_LEN) {
        // Fast path: a complete varint is guaranteed to fit, so read through
        // the raw pointer and just advance the cursor. The loop reads at most
        // MAX_VARINT_LEN bytes before terminating or erroring.
        return try readVarintUnchecked(buf.ptr, pos);
    }
    return readVarintChecked(buf, pos);
}

/// Fast-path decode: no bounds checks. `pos.*` must have at least
/// `MAX_VARINT_LEN` readable bytes at `base + pos.*`.
inline fn readVarintUnchecked(base: [*]const u8, pos: *usize) Error!Unsigned {
    var value: Unsigned = 0;
    var shift: u32 = 0;
    var i = pos.*;
    while (true) {
        const byte = base[i];
        i += 1;
        // On the final byte that can still fit, reject payload bits that would
        // not survive the shift (an overlong varint that overflows the value).
        if (shift + 7 >= 64 and (byte & 0x7F) >> @intCast(64 - shift) != 0) {
            return Error.InvalidMessage;
        }
        value |= @as(Unsigned, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) {
            pos.* = i;
            return value;
        }
        shift += 7;
        if (shift >= 64) return Error.InvalidMessage;
    }
}

/// Slow-path decode used within the last `MAX_VARINT_LEN` − 1 bytes of a
/// buffer, where the varint may legitimately be split across chunks.
fn readVarintChecked(buf: []const u8, pos: *usize) Error!?Unsigned {
    var value: Unsigned = 0;
    var shift: u32 = 0;
    var i = pos.*;
    while (i < buf.len) {
        const byte = buf[i];
        i += 1;
        if (shift + 7 >= 64 and (byte & 0x7F) >> @intCast(64 - shift) != 0) {
            return Error.InvalidMessage;
        }
        value |= @as(Unsigned, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) {
            pos.* = i;
            return value;
        }
        shift += 7;
        if (shift >= 64) return Error.InvalidMessage;
    }
    return null;
}

/// ZigZag encode a signed value to its unsigned varint representation.
pub inline fn zigzagEncode(v: Signed) Unsigned {
    // Shift in the unsigned domain (`<<` discards the sign bit) so `Signed`
    // minimum does not trap in safe builds.
    const uv: Unsigned = @bitCast(v);
    const sign: Unsigned = @bitCast(v >> 63); // arithmetic: all-ones for negatives
    return (uv << 1) ^ sign;
}

/// ZigZag decode an unsigned varint back to a signed value.
pub inline fn zigzagDecode(u: Unsigned) Signed {
    const half: Signed = @bitCast(u >> 1);
    const mask: Signed = -%@as(Signed, @intCast(u & 1));
    return half ^ mask;
}

// --- unit tests ---------------------------------------------------------------

const testing = std.testing;

test "zigzag mapping from the spec (§4.2)" {
    // 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4 ...
    try testing.expectEqual(@as(Unsigned, 0), zigzagEncode(0));
    try testing.expectEqual(@as(Unsigned, 1), zigzagEncode(-1));
    try testing.expectEqual(@as(Unsigned, 2), zigzagEncode(1));
    try testing.expectEqual(@as(Unsigned, 3), zigzagEncode(-2));
    try testing.expectEqual(@as(Unsigned, 4), zigzagEncode(2));
    try testing.expectEqual(@as(Unsigned, std.math.maxInt(u64)), zigzagEncode(std.math.minInt(i64)));

    var u: Unsigned = 0;
    while (u < 16) : (u += 1) {
        try testing.expectEqual(u, zigzagEncode(zigzagDecode(u)));
    }
    try testing.expectEqual(@as(Signed, std.math.minInt(i64)), zigzagDecode(std.math.maxInt(u64)));
}

test "varint decode: spec examples (§4.1)" {
    const cases = [_]struct { bytes: []const u8, value: Unsigned }{
        .{ .bytes = &.{0x00}, .value = 0 },
        .{ .bytes = &.{0x01}, .value = 1 },
        .{ .bytes = &.{0x7F}, .value = 127 },
        .{ .bytes = &.{ 0x80, 0x01 }, .value = 128 },
        .{ .bytes = &.{ 0xAC, 0x02 }, .value = 300 },
        .{ .bytes = &.{ 0x80, 0x80, 0x01 }, .value = 16384 },
    };
    for (cases) |c| {
        // Checked path (short buffer).
        var pos: usize = 0;
        try testing.expectEqual(c.value, (try readVarint(c.bytes, &pos)).?);
        try testing.expectEqual(c.bytes.len, pos);

        // Unchecked fast path (padding guarantees MAX_VARINT_LEN readable).
        var padded: [MAX_VARINT_LEN + 8]u8 = @splat(0);
        @memcpy(padded[0..c.bytes.len], c.bytes);
        pos = 0;
        try testing.expectEqual(c.value, (try readVarint(&padded, &pos)).?);
        try testing.expectEqual(c.bytes.len, pos);
    }
}

test "varint decode: split input reports null and keeps pos" {
    const bytes = [_]u8{0x80}; // continuation set, value byte missing
    var pos: usize = 0;
    try testing.expectEqual(@as(?Unsigned, null), try readVarint(&bytes, &pos));
    try testing.expectEqual(@as(usize, 0), pos);
}

test "varint decode: overlong / overflowing input is rejected" {
    // 12 continuation bytes: longer than any u64 varint.
    const overlong: [12]u8 = @splat(0xFF);
    var pos: usize = 0;
    try testing.expectError(Error.InvalidMessage, readVarint(&overlong, &pos));

    // Exactly 10 bytes whose top payload bits overflow 64 bits.
    const overflow = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
    var pos2: usize = 0;
    try testing.expectError(Error.InvalidMessage, readVarint(&overflow, &pos2));

    // Nine continuation bytes in a short buffer are merely incomplete, not yet
    // malformed — the checked path reports "need more bytes".
    var pos3: usize = 0;
    try testing.expectEqual(@as(?Unsigned, null), try readVarint(overlong[0..9], &pos3));
}

test "varint decode: u64 max round-trips" {
    // 0xFFFF_FFFF_FFFF_FFFF == 9 * 0xFF + final 0x01.
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var pos: usize = 0;
    try testing.expectEqual(std.math.maxInt(u64), (try readVarint(&bytes, &pos)).?);
    try testing.expectEqual(@as(usize, 10), pos);
}
