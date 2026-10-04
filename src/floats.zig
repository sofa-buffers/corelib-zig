//! Float-array helpers the generated **encode** path needs: the bit-exact
//! "does this field still hold its default" test.
//!
//! The encoder omits a field iff its value equals its declared default
//! (MESSAGE_SPEC §2), and floats round-trip bit for bit (CORELIB_PLAN §4.6), so
//! the equality that decides omission must be a *bit-pattern* equality: an array
//! `[-0.0, 1.5]` is not the default `[0.0, 1.5]`, and a NaN equals another NaN
//! exactly when every bit, payload included, matches. An IEEE `==` (which is
//! what `std.mem.eql` does on a float element type) gets both wrong.
//!
//! The helper carries no schema knowledge — the element type is a type
//! parameter and both operands are passed in — so it lives here rather than
//! being emitted into every generated module (SofaBuffers ARCHITECTURE §8).

const std = @import("std");

/// True iff `a` and `b` have the same length and every element has the same
/// IEEE-754 bit pattern (32 bits for `f32`, 64 for `f64`).
///
/// `+0.0` and `-0.0` differ; two NaNs are equal only when their bit patterns are
/// identical; there is no IEEE `==` anywhere. The lengths are compared first, so
/// a mismatch costs no element read. The elements are contiguous, so the rest is
/// one block compare over their bytes — byte equality is bit equality on any
/// endianness. No allocation, no mutation.
///
/// Both operands are plain slices, so a call site passes the field's storage on
/// one side and a literal default (`&.{ 0.0, 1.5 }`) on the other, exactly as it
/// passed them to `std.mem.eql`.
pub fn bitsEqual(comptime T: type, a: []const T, b: []const T) bool {
    comptime if (T != f32 and T != f64) @compileError("bitsEqual: element type must be f32 or f64");
    if (a.len != b.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

const testing = std.testing;

/// The reference the tests cross-check against: a plain integer bit loop.
fn refEqual(comptime T: type, a: []const T, b: []const T) bool {
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (@as(U, @bitCast(x)) != @as(U, @bitCast(y))) return false;
    }
    return true;
}

fn bits(comptime T: type, v: std.meta.Int(.unsigned, @bitSizeOf(T))) T {
    return @bitCast(v);
}

const types = .{ f32, f64 };

test "bitsEqual: empty arrays are equal, a length mismatch is not" {
    inline for (types) |T| {
        try testing.expect(bitsEqual(T, &.{}, &.{}));
        try testing.expect(!bitsEqual(T, &.{}, &.{0.0}));
        try testing.expect(!bitsEqual(T, &.{0.0}, &.{}));
        try testing.expect(!bitsEqual(T, &.{ 1.0, 2.0 }, &.{1.0}));
        try testing.expect(!bitsEqual(T, &.{1.0}, &.{ 1.0, 2.0 }));
    }
}

test "bitsEqual: one element and equal arrays" {
    inline for (types) |T| {
        try testing.expect(bitsEqual(T, &.{1.5}, &.{1.5}));
        try testing.expect(!bitsEqual(T, &.{1.5}, &.{2.5}));
        try testing.expect(bitsEqual(T, &.{ 0.0, 1.5, -3.25 }, &.{ 0.0, 1.5, -3.25 }));
        const same = [_]T{ 1.0, 2.0, 3.0 };
        try testing.expect(bitsEqual(T, &same, &same));
        try testing.expect(bitsEqual(T, same[0..], same[0..]));
    }
}

test "bitsEqual: -0.0 differs from +0.0 at the first, a middle and the last index" {
    inline for (types) |T| {
        const neg: T = -0.0;
        try testing.expect(!bitsEqual(T, &.{ neg, 1.5, 2.5 }, &.{ 0.0, 1.5, 2.5 }));
        try testing.expect(!bitsEqual(T, &.{ 0.0, neg, 2.5 }, &.{ 0.0, 0.0, 2.5 }));
        try testing.expect(!bitsEqual(T, &.{ 0.0, 1.5, neg }, &.{ 0.0, 1.5, 0.0 }));
        try testing.expect(!bitsEqual(T, &.{neg}, &.{0.0}));
        try testing.expect(bitsEqual(T, &.{neg}, &.{neg}));
        // IEEE equality says these are equal; that is the bug this replaces.
        try testing.expect(std.mem.eql(T, &.{neg}, &.{0.0}));
    }
}

test "bitsEqual: NaN is equal to itself only bit for bit" {
    inline for (types) |T| {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        const qnan: U = if (T == f32) 0x7FC00000 else 0x7FF8000000000000;
        const snan: U = if (T == f32) 0x7F800000 else 0x7FF0000000000000;
        const sign: U = @as(U, 1) << (@bitSizeOf(T) - 1);
        const quiet = bits(T, qnan);
        const quiet_again = bits(T, qnan);
        // Another payload: one low mantissa bit set.
        const payload = bits(T, qnan | 1);
        // Signaling pattern (quiet bit clear, a payload bit set).
        const signaling = bits(T, snan | 1);
        // Sign bit differs only.
        const neg_quiet = bits(T, sign | qnan);
        try testing.expect(std.math.isNan(quiet) and std.math.isNan(payload) and std.math.isNan(signaling));
        try testing.expect(bitsEqual(T, &.{quiet}, &.{quiet_again}));
        try testing.expect(bitsEqual(T, &.{signaling}, &.{signaling}));
        try testing.expect(!bitsEqual(T, &.{quiet}, &.{payload}));
        try testing.expect(!bitsEqual(T, &.{quiet}, &.{signaling}));
        try testing.expect(!bitsEqual(T, &.{quiet}, &.{neg_quiet}));
        try testing.expect(!bitsEqual(T, &.{ 1.0, quiet }, &.{ 1.0, payload }));
    }
}

test "bitsEqual: infinities and subnormals" {
    inline for (types) |T| {
        const inf = std.math.inf(T);
        const tiny = std.math.floatTrueMin(T);
        try testing.expect(bitsEqual(T, &.{ inf, -inf }, &.{ inf, -inf }));
        try testing.expect(!bitsEqual(T, &.{inf}, &.{-inf}));
        try testing.expect(!bitsEqual(T, &.{inf}, &.{std.math.floatMax(T)}));
        try testing.expect(bitsEqual(T, &.{ tiny, -tiny }, &.{ tiny, -tiny }));
        try testing.expect(!bitsEqual(T, &.{tiny}, &.{0.0}));
        try testing.expect(!bitsEqual(T, &.{tiny}, &.{-tiny}));
        try testing.expect(!bitsEqual(T, &.{tiny}, &.{tiny * 2}));
    }
}

test "bitsEqual: long arrays with exactly one differing element" {
    inline for (types) |T| {
        var a: [200]T = undefined;
        for (&a, 0..) |*e, i| e.* = @floatFromInt(i);
        var b = a;
        try testing.expect(bitsEqual(T, &a, &b));
        for ([_]usize{ 0, 1, 63, 64, 65, 100, 198, 199 }) |at| {
            var c = a;
            c[at] = if (a[at] == 0.0) -0.0 else a[at] + 1;
            try testing.expect(!bitsEqual(T, &a, &c));
            try testing.expect(!bitsEqual(T, &c, &a));
            // Only a signed zero differs.
            b = a;
            b[at] = -0.0;
            try testing.expectEqual(refEqual(T, &a, &b), bitsEqual(T, &a, &b));
        }
        // Length mismatch on a long array, both directions.
        try testing.expect(!bitsEqual(T, a[0..199], a[0..200]));
        try testing.expect(!bitsEqual(T, a[0..200], a[0..199]));
    }
}

test "bitsEqual: a pseudo-random cross-check against a plain bit loop" {
    inline for (types) |T| {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        var prng = std.Random.DefaultPrng.init(0x636);
        const rnd = prng.random();
        var a: [130]T = undefined;
        var b: [130]T = undefined;
        for (0..400) |round| {
            const n = rnd.uintLessThan(usize, a.len + 1);
            for (0..n) |i| {
                // Draw from raw bit patterns, so NaNs, zeros and subnormals all occur.
                a[i] = bits(T, rnd.int(U));
                b[i] = a[i];
            }
            if (n > 0 and round % 2 == 1) {
                const at = rnd.uintLessThan(usize, n);
                b[at] = bits(T, rnd.int(U));
                if (round % 4 == 1) b[at] = bits(T, @as(U, @bitCast(a[at])) ^ (@as(U, 1) << @intCast(rnd.uintLessThan(usize, @bitSizeOf(T)))));
            }
            const m = if (round % 8 == 7 and n > 0) n - 1 else n;
            try testing.expectEqual(refEqual(T, a[0..n], b[0..m]), bitsEqual(T, a[0..n], b[0..m]));
        }
    }
}
