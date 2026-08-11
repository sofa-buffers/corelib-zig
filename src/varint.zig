//! Base-128 varint and ZigZag codecs.
//!
//! This is the speed-critical core of both directions, so the bulk paths are
//! **SWAR**: eight varint bytes are processed in one 64-bit word rather than
//! one at a time. A byte-at-a-time LEB128 loop costs a load, a variable shift,
//! an OR and a branch *per byte* — roughly 7 instructions — and the shift
//! amount changing every step is what stops it vectorising. Packing the eight
//! 7-bit groups with a three-round shift/mask cascade replaces all of that with
//! a fixed, branch-free sequence over the whole word (`spread7`/`gather7`).
//!
//! Both directions keep a **fast path and a boundary path**. The fast path
//! requires `MAX_VARINT_LEN` bytes of headroom so it can read/write a whole
//! 64-bit word without bounds checks; only near the end of a buffer — where a
//! varint may legitimately straddle a chunk boundary, or the output buffer may
//! need a flush mid-value — does it fall back to the checked byte loop that can
//! report "need more bytes". The boundary paths are unchanged and stay the
//! reference definition of the encoding; the SWAR paths are tested against them.

const std = @import("std");
const types = @import("types.zig");

const Error = types.Error;
const Unsigned = types.Unsigned;
const Signed = types.Signed;

/// Maximum number of bytes an `Unsigned`-width varint can occupy (10 for u64).
pub const MAX_VARINT_LEN: usize = (@bitSizeOf(Unsigned) + 6) / 7;

/// Low 56 bits — the seven-bit groups that fit in the first eight varint bytes.
const LOW56: Unsigned = 0x00FF_FFFF_FFFF_FFFF;
/// The continuation bit of every byte in a 64-bit word.
const CONT_BITS: Unsigned = 0x8080_8080_8080_8080;

/// Scatter the low 56 bits of `x` into eight 7-bit groups, one per byte, each
/// left-justified at its byte's bit 0 with the continuation bit clear.
///
/// Three doubling rounds: 28|28 bits into the two halves of the word, then
/// 14|14 within each half, then 7|7 within each 16-bit lane. `gather7` is the
/// exact inverse.
inline fn spread7(x56: Unsigned) Unsigned {
    // Round 1 splits the 56 bits into two 28-bit halves. Truncating the top
    // half to `u32` before re-widening expresses the move with no 64-bit mask
    // at all: x86-64 has no 64-bit immediate AND, so each wide constant costs a
    // `movabs` and — worse, inside a loop — a register to keep it live.
    const top: u32 = @truncate(x56 >> 28);
    var x = (x56 & 0x0FFF_FFFF) | (@as(Unsigned, top) << 32);
    x = (x & 0x0000_3FFF_0000_3FFF) | ((x & 0x0FFF_C000_0FFF_C000) << 2);
    x = (x & 0x007F_007F_007F_007F) | ((x & 0x3F80_3F80_3F80_3F80) << 1);
    return x;
}

/// Collect the eight 7-bit payload groups of `w` (one per byte, continuation
/// bits ignored) into a contiguous 56-bit value. Inverse of `spread7`.
inline fn gather7(w: Unsigned) Unsigned {
    // No leading `& 0x7F7F..` mask: round 1's two masks already exclude every
    // byte's continuation bit (0x007F keeps bits 0..6 of a lane, and after the
    // shift 0x3F80 keeps bits 7..13 — bit 14, where the odd byte's
    // continuation bit lands, falls outside both).
    const y = (w & 0x007F_007F_007F_007F) | ((w >> 1) & 0x3F80_3F80_3F80_3F80);
    // The remaining rounds run on the two 32-bit halves independently. Every
    // mask they need fits in 32 bits, so they assemble with ordinary immediate
    // ANDs — no `movabs`, and no live 64-bit constant competing for a register
    // with round 1's two masks, which do have to stay wide.
    const lo: u32 = @truncate(y);
    const hi: u32 = @truncate(y >> 32);
    const glo: u32 = (lo & 0x0000_3FFF) | ((lo >> 2) & 0x0FFF_C000);
    const ghi: u32 = (hi & 0x0000_3FFF) | ((hi >> 2) & 0x0FFF_C000);
    return @as(Unsigned, glo) | (@as(Unsigned, ghi) << 28);
}

/// Continuation bits for the first eight bytes of a varint of length `n`:
/// every byte but the last carries `0x80`, and a varint of 9 or 10 bytes has
/// all eight of them set. Indexed by length, so index 0 is unused.
const CONT_FOR_LEN = [MAX_VARINT_LEN + 1]Unsigned{
    0,
    0x0000_0000_0000_0000,
    0x0000_0000_0000_0080,
    0x0000_0000_0000_8080,
    0x0000_0000_0080_8080,
    0x0000_0000_8080_8080,
    0x0000_0080_8080_8080,
    0x0000_8080_8080_8080,
    0x0080_8080_8080_8080,
    0x8080_8080_8080_8080,
    0x8080_8080_8080_8080,
};

/// A varint decoded by `readVarintFast`: its value and its byte length.
pub const Decoded = struct { value: Unsigned, len: usize };

/// Varint byte length for each possible leading-zero count of `v | 1`, i.e.
/// `ceil(significant_bits / 7)`. Precomputed because the arithmetic form
/// (`(64 - clz + 6) / 7`) lowers to a multiply-shift chain — some seven
/// instructions — where a table is a single indexed load.
const LEN_FOR_CLZ = blk: {
    var t: [@bitSizeOf(Unsigned)]u8 = undefined;
    for (&t, 0..) |*e, clz| e.* = (@bitSizeOf(Unsigned) - clz + 6) / 7;
    break :blk t;
};

/// Number of bytes `v` occupies as a varint (1..`MAX_VARINT_LEN`).
pub inline fn varintLen(v: Unsigned) usize {
    // `v | 1` keeps zero at one byte and lets a single `clz` carry the whole
    // computation.
    return LEN_FOR_CLZ[@clz(v | 1)];
}

/// Read one base-128 varint from `buf` starting at `pos.*`.
///
/// * a value — a full varint was decoded; `pos.*` advanced past it.
/// * `null` — `buf` ends mid-varint; `pos.*` is left unchanged so the caller
///   can carry the partial bytes to the next chunk.
/// * `error.InvalidMessage` — the varint is longer than `Unsigned` allows.
pub inline fn readVarint(buf: []const u8, pos: *usize) Error!?Unsigned {
    const avail = buf.len - pos.*;
    if (avail >= MAX_VARINT_LEN) {
        // Fast path: a complete varint is guaranteed to fit, so the SWAR
        // decoder can read a whole word with no bounds checks.
        const d = try readVarintFast(buf.ptr + pos.*);
        pos.* += d.len;
        return d.value;
    }
    // Near the end of the buffer the SWAR path has no headroom, but a
    // single-byte varint is still self-contained — and the final bytes of a
    // message are mostly small ids, small values and sequence-end markers.
    // Peeling that case keeps them off the out-of-line byte loop.
    if (avail != 0) {
        const b = buf.ptr[pos.*];
        if (b < 0x80) {
            pos.* += 1;
            return b;
        }
    }
    const d = (try readVarintChecked(buf, pos.*)) orelse return null;
    pos.* += d.len;
    return d.value;
}

/// SWAR decode of one varint. `base` **must** have at least `MAX_VARINT_LEN`
/// readable bytes — callers guarantee this with a headroom check.
///
/// Non-minimal encodings decode to the value they denote (CORELIB_PLAN §4.1:
/// tolerate on decode, normalize on re-encode); only an encoding that overruns
/// the 64-bit value range is `InvalidMessage`.
pub inline fn readVarintFast(base: [*]const u8) Error!Decoded {
    // Peel the single-byte case off the *word* rather than loading its first
    // byte separately: small ids and small values make it by far the most
    // common varint in a real message, and the SWAR sequence below — worth
    // ~20 instructions — would all be overhead for it. Testing the low byte of
    // the word the slow path needs anyway makes the peel free for long varints.
    const w = std.mem.readInt(Unsigned, base[0..8], .little);
    if (w & 0x80 == 0) return .{ .value = w & 0x7F, .len = 1 };
    // A byte terminates the varint when its continuation bit is clear, so the
    // lowest set bit of `m` marks the end — one `ctz` instead of eight tests.
    const m = ~w & CONT_BITS;
    if (m != 0) {
        const n: u32 = @ctz(m); // 7, 15, ... 63 — bit index of the terminator
        // Drop every byte above the terminator before gathering.
        const all: Unsigned = std.math.maxInt(Unsigned);
        const keep = w & (all >> @intCast(63 - n));
        return .{ .value = gather7(keep), .len = (n >> 3) + 1 };
    }

    // All eight bytes continue: bits 0..55 come from the word, the remaining
    // bits from the ninth and tenth bytes.
    // Both remaining bytes come from one 16-bit load — the headroom contract
    // guarantees all ten are readable.
    var value = gather7(w);
    const tail = std.mem.readInt(u16, base[8..10], .little);
    value |= @as(Unsigned, tail & 0x7F) << 56;
    if (tail & 0x80 == 0) return .{ .value = value, .len = 9 };

    // A tenth byte may only carry the single bit that still fits (bit 63) and
    // must terminate: anything above `0x01` either overflows the value range or
    // announces an eleventh byte. Both are malformed regardless of what follows.
    // It is read independently of the ninth byte's continuation flag — a
    // non-minimal encoding may set that flag and still carry a zero here.
    const b9 = tail >> 8;
    if (b9 > 1) return Error.InvalidMessage;
    value |= @as(Unsigned, b9) << 63;
    return .{ .value = value, .len = 10 };
}

/// SWAR encode of one varint at `dst`, returning its byte length.
///
/// `dst` **must** have at least `MAX_VARINT_LEN` writable bytes: the whole
/// 64-bit word is stored unconditionally, so up to `MAX_VARINT_LEN` − 1 bytes
/// past the varint are clobbered with scratch. Callers advance the cursor by
/// the returned length, so the next write overwrites them.
pub inline fn writeVarintFast(dst: [*]u8, v: Unsigned) usize {
    // Peel the single-byte case, for the same reason `readVarintFast` does:
    // it is the common varint and skips the length computation, the spread and
    // the 64-bit store entirely.
    if (v < 0x80) {
        dst[0] = @intCast(v);
        return 1;
    }
    const len = varintLen(v);
    const lo = spread7(v & LOW56) | CONT_FOR_LEN[len];
    std.mem.writeInt(Unsigned, dst[0..8], lo, .little);
    if (len > 8) {
        // The ninth byte is simply the top eight bits of `v`: its payload is
        // bits 56..62, and its continuation bit — bit 7 — coincides exactly
        // with bit 63, which is set precisely when a tenth byte follows. The
        // tenth byte is then that same bit. When `len == 9` the tenth byte
        // comes out zero and is scratch the next write overwrites.
        const hi: u16 = @truncate((v >> 56) | ((v >> 63) << 8));
        std.mem.writeInt(u16, dst[8..10], hi, .little);
    }
    return len;
}

/// SWAR encode of a whole run of varints at `dst`, ZigZag-mapping the elements
/// first when `is_signed`. Returns the bytes written.
///
/// `dst` **must** have `MAX_VARINT_LEN` writable bytes per element: every
/// element goes through `writeVarintFast`, whose scratch the next one overwrites
/// (the last one's is overwritten by whatever the caller writes next).
///
/// **`noinline` for the same reason `istream.intArrayRun` is** — the mirror of
/// this loop on the decode side. `spread7`'s mask cascade needs four 64-bit
/// constants and x86-64 has no 64-bit immediate AND, so each one costs a
/// `movabs` unless it can stay in a register across the loop. Inlined into the
/// encoder, whose register pressure is set by the surrounding stream state, they
/// get rematerialized per element; in a function of its own the loop pays for
/// them once per run. The call is per run, not per element.
pub noinline fn writeVarintRunFast(dst: [*]u8, data: anytype, comptime is_signed: bool) usize {
    var off: usize = 0;
    for (data) |e| {
        const v: Unsigned = if (is_signed) zigzagEncode(e) else e;
        off += writeVarintFast(dst + off, v);
    }
    return off;
}

/// Slow-path decode used within the last `MAX_VARINT_LEN` − 1 bytes of a
/// buffer, where the varint may legitimately be split across chunks. Reads from
/// `start` and reports the value with its length, leaving the cursor to the
/// caller.
///
/// It takes the cursor **by value** on purpose. It is the one varint path that
/// is a real call, and handing it a `*usize` would make the caller's cursor
/// escape: `parse` keeps its position in a local, and a pointer to that local
/// crossing a call boundary forces it into memory for the whole function —
/// every `pos` read and write in the field loop becomes a load and a store,
/// including on the fast paths that never come here.
fn readVarintChecked(buf: []const u8, start: usize) Error!?Decoded {
    var value: Unsigned = 0;
    var shift: u32 = 0;
    var i = start;
    while (i < buf.len) {
        const byte = buf[i];
        i += 1;
        if (shift + 7 >= 64 and (byte & 0x7F) >> @intCast(64 - shift) != 0) {
            return Error.InvalidMessage;
        }
        value |= @as(Unsigned, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) return .{ .value = value, .len = i - start };
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

/// Reference encoder: the byte-at-a-time definition of the format, kept in the
/// tests as the thing the SWAR path must agree with.
fn refEncode(dst: []u8, value: Unsigned) usize {
    var v = value;
    var n: usize = 0;
    while (v >= 0x80) : (n += 1) {
        dst[n] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    dst[n] = @truncate(v);
    return n + 1;
}

/// Values that exercise every varint length plus both sides of each boundary.
fn swarProbeValues(out: *std.ArrayList(Unsigned), a: std.mem.Allocator) !void {
    try out.appendSlice(a, &.{ 0, 1, 2, 127, 128, 129, 300, 16383, 16384, std.math.maxInt(Unsigned) });
    // Both sides of every 7-bit length boundary.
    var shift: u6 = 7;
    while (true) : (shift += 7) {
        const b = @as(Unsigned, 1) << shift;
        try out.appendSlice(a, &.{ b - 1, b, b + 1 });
        if (shift >= 63) break;
    }
    // Deterministic pseudo-random spread, including the benchmark generator.
    var i: u64 = 0;
    while (i < 4000) : (i += 1) {
        try out.append(a, i *% 0x9E37_79B9_7F4A_7C15);
        try out.append(a, (i *% 0x0123_4567_89AB_CDEF) >> @intCast(i % 64));
    }
}

test "SWAR encode matches the byte-at-a-time reference" {
    var vals: std.ArrayList(Unsigned) = .empty;
    defer vals.deinit(testing.allocator);
    try swarProbeValues(&vals, testing.allocator);

    for (vals.items) |v| {
        var want: [MAX_VARINT_LEN]u8 = @splat(0);
        const want_len = refEncode(&want, v);
        try testing.expectEqual(want_len, varintLen(v));

        // The fast writer clobbers up to MAX_VARINT_LEN bytes, so give it the
        // headroom its contract requires and compare only the varint itself.
        var got: [MAX_VARINT_LEN]u8 = @splat(0xAA);
        const got_len = writeVarintFast(&got, v);
        try testing.expectEqual(want_len, got_len);
        try testing.expectEqualSlices(u8, want[0..want_len], got[0..got_len]);
    }
}

test "SWAR decode round-trips every encoded value" {
    var vals: std.ArrayList(Unsigned) = .empty;
    defer vals.deinit(testing.allocator);
    try swarProbeValues(&vals, testing.allocator);

    for (vals.items) |v| {
        // Pad past the varint so the fast path's headroom precondition holds
        // however short the encoding is.
        var buf: [MAX_VARINT_LEN * 2]u8 = @splat(0xFF);
        const len = refEncode(&buf, v);
        const d = try readVarintFast(&buf);
        try testing.expectEqual(v, d.value);
        try testing.expectEqual(len, d.len);

        // And through the public cursor API, on both of its paths: a padded
        // buffer takes the fast path, an exact-length one the checked path.
        var pos: usize = 0;
        try testing.expectEqual(v, (try readVarint(&buf, &pos)).?);
        try testing.expectEqual(len, pos);
        pos = 0;
        try testing.expectEqual(v, (try readVarint(buf[0..len], &pos)).?);
        try testing.expectEqual(len, pos);
    }
}

test "SWAR decode accepts non-minimal encodings and rejects over-range ones" {
    // Non-minimal: 5 padded out to nine bytes, then to the full ten. Both
    // denote 5 and must decode as such (CORELIB_PLAN §4.1).
    for ([_]usize{ 2, 5, 9, 10 }) |len| {
        var buf: [MAX_VARINT_LEN * 2]u8 = @splat(0x00);
        for (0..len - 1) |i| buf[i] = 0x80;
        buf[0] = 0x85;
        buf[len - 1] = 0x00;
        const d = try readVarintFast(&buf);
        try testing.expectEqual(@as(Unsigned, 5), d.value);
        try testing.expectEqual(len, d.len);
    }

    // A tenth byte may carry only bit 63: 0x01 is the largest legal one.
    var ok = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    try testing.expectEqual(std.math.maxInt(Unsigned), (try readVarintFast(&ok)).value);
    // Anything above it either overflows the value range or announces an
    // eleventh byte — malformed either way.
    for ([_]u8{ 0x02, 0x7F, 0x80, 0x81, 0xFF }) |bad| {
        var buf = ok;
        buf[9] = bad;
        try testing.expectError(Error.InvalidMessage, readVarintFast(&buf));
    }
}

test "varint decode: u64 max round-trips" {
    // 0xFFFF_FFFF_FFFF_FFFF == 9 * 0xFF + final 0x01.
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var pos: usize = 0;
    try testing.expectEqual(std.math.maxInt(u64), (try readVarint(&bytes, &pos)).?);
    try testing.expectEqual(@as(usize, 10), pos);
}
