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
//! passes each payload through a comptime-duck-typed visitor as a slice that is
//! valid only until the callback returns — on the one-shot path exactly as on
//! the streaming one. The only state the decoder owns is a small fixed carry
//! buffer, sized once in the struct, for the few bytes of an item that straddles
//! a chunk boundary.
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
pub const MIN_OUTPUT_BUFFER = types.MIN_OUTPUT_BUFFER;
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
pub const utf8Valid = @import("utf8.zig").utf8Valid;
/// Compile-time state of `SOFAB_STRICT_UTF8` (Zig build option `strict_utf8`,
/// default on). When off, `utf8Valid` folds to `true` and the encoder writes
/// `string` bytes verbatim.
pub const STRICT_UTF8 = @import("utf8.zig").STRICT_UTF8;

/// Array helpers the generated **decode** path needs for array fields (bounded
/// element stores, growth of a decode-owned destination, wrapper-array element
/// placement). They carry no schema knowledge — the bound, the element default
/// and the allocator are passed in, the element type is a type parameter.
/// Encoding an array needs no helper: it is written linearly and gap-free,
/// trailing default elements included (MESSAGE_SPEC §3).
///
/// Three signatures cover every wrapper-array shape: `placeElem` puts a string
/// or blob element at its wire id, `reserveElem` reserves the slot a struct,
/// union or nested-array element is routed into, and `reserveRow` reserves a
/// matrix row and sizes it at its announced count. `allocCounted` is the
/// count-prefixed native array beside them.
///
/// Each takes the field's bound as a `comptime` `arrays.Bound`:
/// `.{ .schema = n }` for a declared `count:`, whose breach is
/// `error.InvalidMessage` (MESSAGE_SPEC §7.1), or `.{ .receiver = n }` for the
/// caller's `max_dyn_array_count` on a field the schema leaves unbounded, whose
/// breach is `error.LimitExceeded` (CORELIB_PLAN §6.2.1). Never both, and never
/// neither — the bound has no unset state and no unlimited mode — so the rule
/// has one implementation here and generated code emits no copy of it. No limit
/// is held, defaulted or retained. The bound being *comptime* is what makes it
/// fold to the same constant an emitted literal produced.
pub const arrays = @import("arrays.zig");

/// Storage for a `count: N` native array field: `N` elements of inline capacity
/// plus the length actually carried, because a schema `count` is a capacity and
/// the wire count is the length (MESSAGE_SPEC §3). The capacity is a type
/// parameter, so the type is schema-free like everything else here.
pub const FixedArray = @import("support.zig").FixedArray;
/// Flush sink behind a generated one-shot `encode()`: it collects the drained
/// bytes into a list allocated from the caller's allocator. The corelib
/// allocates no output buffer of its own — CORELIB_PLAN §5.1 assigns that to
/// the generated layer, and this is the mechanism it drives, not a policy.
pub const CollectingSink = @import("support.zig").CollectingSink;
/// Payload materialization a generated decoder holds for its `string`/`blob`
/// fields: `take` hands back one contiguous payload however it arrived —
/// borrowed whole on the contiguous path, copied whole on the streaming one,
/// stitched from the pieces when a feed boundary split it — and `takeCapped`
/// is the same for a field the schema leaves unbounded, comparing the caller's
/// `max_dyn_string_len` / `max_dyn_blob_len` against the announced length
/// before any of that happens (CORELIB_PLAN §6.2.1). `beginCapped` is that
/// comparison alone, for a generated `fixlenBegin` to make at the **length
/// header** — the enforcement point §6.2.1 names, and the only one that still
/// answers when the message ends at the length word and no payload chunk ever
/// reaches `takeCapped`. No limit is held, defaulted or retained here.
pub const PayloadAcc = @import("support.zig").PayloadAcc;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("varint.zig");
    _ = @import("ostream.zig");
    _ = @import("istream.zig");
    _ = @import("arrays.zig");
    _ = @import("utf8.zig");
    _ = @import("support.zig");
}
