//! UTF-8 validation primitive for `string` fields (CORELIB_PLAN §6.4,
//! MESSAGE_SPEC §8).
//!
//! A `string` payload is UTF-8; `blob` is the type for opaque bytes and is
//! never validated. This corelib is a **byte-container** target — a Zig string
//! is `[]const u8` and the borrowed wire slice is materialized by *generated*
//! code, not the corelib. Per the plan, the corelib therefore exposes a
//! `utf8_valid(bytes) -> bool` primitive that the generator calls
//! **unconditionally** on every materialized string, and the strict/non-strict
//! gate lives **inside** the primitive. Flipping the gate never regenerates
//! code and generated code is identical across build configurations.
//!
//! The gate is the compile-time build option `SOFAB_STRICT_UTF8` (Zig build
//! option `strict_utf8`, default **on**):
//!
//!   * **ON**  — `utf8_valid` runs a real validator and the encoder rejects a
//!     non-UTF-8 `string` with `error.InvalidArgument`.
//!   * **OFF** — `utf8_valid` folds to `return true` (zero validation cost, no
//!     validator code compiled in) and the encoder writes bytes verbatim.

const std = @import("std");
const build_options = @import("build_options");

/// Compile-time state of `SOFAB_STRICT_UTF8` (CORELIB_PLAN §6.4). `true` is the
/// default build; a build with `-Dstrict_utf8=false` compiles the validation
/// out entirely — a documented non-strict build.
pub const STRICT_UTF8: bool = build_options.strict_utf8;

/// Return whether `bytes` is well-formed UTF-8.
///
/// When `SOFAB_STRICT_UTF8` is compiled **off** this folds to `true` at compile
/// time (the branch and the validator are dead-code-eliminated), so a
/// generator's unconditional call has zero runtime cost.
///
/// When **on** it is a real validator, not a byte-range shortcut (this is a
/// security surface, CORELIB_PLAN §6.4): it rejects overlong encodings
/// (including `C0 80`, Java "Modified UTF-8" NUL), UTF-16 surrogate code points
/// `U+D800`–`U+DFFF`, and code points above `U+10FFFF`, and a truncated or bare
/// continuation byte. Embedded `U+0000` (a plain `0x00` byte) is valid UTF-8
/// and is accepted; only its overlong form `C0 80` is rejected. The check is
/// on the borrowed slice — zero-copy, never mutating.
pub fn utf8_valid(bytes: []const u8) bool {
    if (comptime !STRICT_UTF8) return true;
    // std.unicode.utf8ValidateSlice is a real DFA-style validator: it rejects
    // overlong forms, surrogates and > U+10FFFF, and accepts embedded NUL —
    // exactly the CORELIB_PLAN §6.4 requirements (asserted by the tests below).
    return std.unicode.utf8ValidateSlice(bytes);
}

// --- unit tests -----------------------------------------------------------------

const testing = std.testing;

test "valid: empty, ASCII, embedded NUL, and multibyte code points" {
    try testing.expect(utf8_valid(""));
    try testing.expect(utf8_valid("hello, world"));
    // Embedded U+0000 is valid UTF-8 and MUST be accepted (CORELIB_PLAN §6.4).
    try testing.expect(utf8_valid("a\x00b"));
    try testing.expect(utf8_valid(&[_]u8{0x00}));
    // 2-byte (¢ U+00A2), 3-byte (€ U+20AC), 4-byte (𐍈 U+10348), and the
    // maximum scalar U+10FFFF (F4 8F BF BF).
    try testing.expect(utf8_valid("\xC2\xA2"));
    try testing.expect(utf8_valid("\xE2\x82\xAC"));
    try testing.expect(utf8_valid("\xF0\x90\x8D\x88"));
    try testing.expect(utf8_valid("\xF4\x8F\xBF\xBF"));
}

test "invalid: overlong encodings (including C0 80)" {
    // These rejections only hold in a strict build; a non-strict build accepts
    // every byte sequence verbatim (asserted separately below).
    if (comptime !STRICT_UTF8) return;
    // Overlong NUL — Java "Modified UTF-8". MUST be rejected (C0 80), while the
    // proper NUL (0x00) above is accepted.
    try testing.expect(!utf8_valid(&[_]u8{ 0xC0, 0x80 }));
    // Overlong '/' as 2 bytes (C0 AF) and as 3 bytes (E0 80 AF).
    try testing.expect(!utf8_valid(&[_]u8{ 0xC0, 0xAF }));
    try testing.expect(!utf8_valid(&[_]u8{ 0xE0, 0x80, 0xAF }));
    // Overlong U+0000 as 4 bytes (F0 80 80 80).
    try testing.expect(!utf8_valid(&[_]u8{ 0xF0, 0x80, 0x80, 0x80 }));
}

test "invalid: surrogate code points U+D800..U+DFFF" {
    if (comptime !STRICT_UTF8) return;
    // U+D800 (lone high surrogate) encoded as ED A0 80.
    try testing.expect(!utf8_valid(&[_]u8{ 0xED, 0xA0, 0x80 }));
    // U+DFFF (low surrogate) encoded as ED BF BF.
    try testing.expect(!utf8_valid(&[_]u8{ 0xED, 0xBF, 0xBF }));
}

test "invalid: code points above U+10FFFF" {
    if (comptime !STRICT_UTF8) return;
    // U+110000 encoded as F4 90 80 80 — the first scalar past the Unicode max.
    try testing.expect(!utf8_valid(&[_]u8{ 0xF4, 0x90, 0x80, 0x80 }));
    // F5.. and FF are never valid lead bytes.
    try testing.expect(!utf8_valid(&[_]u8{ 0xF5, 0x80, 0x80, 0x80 }));
    try testing.expect(!utf8_valid(&[_]u8{0xFF}));
}

test "invalid: truncated multibyte and bare continuation byte" {
    if (comptime !STRICT_UTF8) return;
    // 3-byte lead with only one continuation byte present (truncated at
    // end-of-payload → not a well-formed prefix here, MUST reject).
    try testing.expect(!utf8_valid(&[_]u8{ 0xE2, 0x82 }));
    // 2-byte lead with no continuation.
    try testing.expect(!utf8_valid(&[_]u8{0xC2}));
    // Bare continuation byte with no lead.
    try testing.expect(!utf8_valid(&[_]u8{0x80}));
    // Valid text followed by a stray continuation byte.
    try testing.expect(!utf8_valid("ok\x80"));
}

test "strict-off build folds utf8_valid to accept-verbatim" {
    // Under -Dstrict_utf8=false the validator is compiled out and every byte
    // sequence — even the overlong NUL — is accepted verbatim. Under the
    // default (on) build the same bytes are rejected (asserted above).
    if (comptime !STRICT_UTF8) {
        try testing.expect(utf8_valid(&[_]u8{ 0xC0, 0x80 }));
        try testing.expect(utf8_valid(&[_]u8{0xFF}));
    }
}
