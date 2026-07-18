//! # SofaBuffers (`sofab`) — Zig core library (high-speed build)
//!
//! A compact, **streaming** implementation of the SofaBuffers (Sofab)
//! serialization format, tuned for **maximum throughput**. The decoder advances
//! a cursor over contiguous memory with zero copies (the Protocol-Buffers-style
//! fast path shared with `corelib-rs` and the C++ high-speed port), while still
//! supporting true chunked streaming on both sides. The wire format is
//! byte-identical to every other `corelib-*` port.
//!
//! The whole library is **allocation-free**: the encoder writes into a
//! caller-owned buffer (draining to a flush sink when it fills) and the decoder
//! pushes borrowed slices into a comptime-duck-typed visitor. The only state the
//! decoder owns is a small fixed carry buffer for the few bytes of an item that
//! straddles a chunk boundary.
//!
//! ## Example
//!
//! ```zig
//! const sofab = @import("sofab");
//!
//! // --- encode (into a caller buffer; add a flush sink to stream out) ---
//! var buf: [32]u8 = undefined;
//! var os = sofab.OStream.init(&buf);
//! try os.writeUnsigned(1, 42);
//! try os.writeSigned(2, -7);
//! const message = buf[0..os.bytesUsed()];
//!
//! // --- decode (one-shot, zero-copy) ---
//! const Sink = struct {
//!     a: u64 = 0,
//!     b: i64 = 0,
//!     pub fn unsigned(self: *@This(), id: sofab.Id, v: u64) void {
//!         if (id == 1) self.a = v;
//!     }
//!     pub fn signed(self: *@This(), id: sofab.Id, v: i64) void {
//!         if (id == 2) self.b = v;
//!     }
//! };
//! var sink: Sink = .{};
//! _ = try sofab.decode(message, &sink); // returns .complete / .incomplete
//! ```

const types = @import("types.zig");

pub const API_VERSION = types.API_VERSION;
pub const Id = types.Id;
pub const ID_MAX = types.ID_MAX;
pub const MAX_DEPTH = types.MAX_DEPTH;
pub const Unsigned = types.Unsigned;
pub const Signed = types.Signed;
pub const Error = types.Error;
pub const FixlenType = types.FixlenType;
pub const ArrayKind = types.ArrayKind;

pub const OStream = @import("ostream.zig").OStream;
pub const FlushFn = @import("ostream.zig").FlushFn;

pub const IStream = @import("istream.zig").IStream;
pub const Status = @import("istream.zig").Status;
pub const decode = @import("istream.zig").decode;

/// UTF-8 validation primitive for `string` fields (CORELIB_PLAN §6.4). The
/// generator emits an unconditional call to this on every materialized string;
/// the strict/non-strict gate lives inside the primitive (`STRICT_UTF8`).
pub const utf8_valid = @import("utf8.zig").utf8_valid;
/// Compile-time state of `SOFAB_STRICT_UTF8` (Zig build option `strict_utf8`,
/// default on). When off, `utf8_valid` folds to `true` and the encoder writes
/// `string` bytes verbatim.
pub const STRICT_UTF8 = @import("utf8.zig").STRICT_UTF8;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("varint.zig");
    _ = @import("ostream.zig");
    _ = @import("istream.zig");
    _ = @import("utf8.zig");
}
