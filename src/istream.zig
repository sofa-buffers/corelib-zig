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
//!     // Announced once per fixlen field (string/blob/fp32/fp64) after its
//!     // length word is read and validated and before any payload byte —
//!     // `total == 0` included. `subtype` is the *arrived* fixlen kind. Unlike
//!     // the other callbacks it may fail: raising rejects the field (INVALID),
//!     // which is how a `maxlen` bound is latched at the length word regardless
//!     // of where a chunk boundary falls. Optional, like every callback.
//!     pub fn fixlenBegin(self: *@This(), id: sofab.Id, subtype: sofab.FixlenType, total: usize) sofab.Error!void { ... }
//!     // string/blob chunks: `total` is the field length, `offset` the chunk
//!     // position; a contiguous decode delivers one whole-payload chunk.
//!     pub fn string(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void { ... }
//!     pub fn blob(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void { ... }
//!     // `kind` names the element category — for a fixlen array its *subtype*
//!     // (`.fp32` / `.fp64`), reported once the `fixlen_word` has been read.
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

/// Element count from which an integer array is worth handing to the bulk
/// decoder (`intArrayRun`) rather than decoding inline in the tail loop.
const BULK_MIN_ELEMS = 8;

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

/// The decode outcome at the point the caller has run out of input — the three
/// distinct outcomes of MESSAGE_SPEC §7 / CORELIB_PLAN §5.2.
///
/// `feed` and `decode` return only the two non-error outcomes: malformed bytes
/// are rejected eagerly with `error.InvalidMessage` while `feed`/`parse` is
/// still consuming them, which is how Zig spells a rejection. `.invalid` exists
/// so that the read-only `status` accessor can report that same terminal verdict
/// afterwards instead of claiming a stream the decoder has already rejected is
/// `.complete`.
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
    /// The bytes consumed so far are malformed regardless of what follows
    /// (INVALID) — the decoder rejected them with `error.InvalidMessage` and
    /// latched that verdict. Terminal: no continuation can clear it, only
    /// `IStream.reset`. Returned by `status`, never by `feed`/`decode`, which
    /// report this outcome as `error.InvalidMessage`.
    invalid,
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
    /// Latched INVALID verdict. §5.2 calls that outcome **terminal** ("can more
    /// bytes change it? — no"): once the consumed bytes are malformed, no
    /// continuation can make them well-formed, so the decoder must not
    /// resynchronize on whatever follows the malformed construct. `reset`
    /// clears it.
    invalid: bool = false,

    /// Create a fresh decoder ready to accept a new message.
    pub fn init() IStream {
        return .{};
    }

    /// Reset to the initial state so the decoder can be reused for a new
    /// message.
    ///
    /// This is also the **only** way out of a latched INVALID verdict (§5.2): a
    /// decoder that has rejected its input keeps rejecting — every further
    /// `feed` returns `error.InvalidMessage` and `status` reports `.invalid` —
    /// until it is reset.
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
    ///
    /// `error.InvalidMessage` is **terminal for this decoder** (§5.2, "can more
    /// bytes change it? — no"). Once a `feed` has reported it, every further
    /// `feed` reports it again — a whole valid message, an empty end-of-input
    /// probe and a truncated prefix alike — rather than resynchronizing on the
    /// bytes that follow the malformed construct, and `status` reports
    /// `.invalid`. Without that latch the verdict would depend on where the
    /// chunk boundaries fell, which MESSAGE_SPEC §7.2 item 4 forbids: the same
    /// bytes must decode to the same outcome fed whole or one byte at a time.
    /// `reset` clears the latch and readies the decoder for a new message.
    pub fn feed(self: *IStream, chunk: []const u8, visitor: anytype) Error!Status {
        if (self.invalid) return error.InvalidMessage;
        // Latches the terminal verdict on every path out of `feed` and `parse`,
        // including a visitor callback that rejects a field. (Spelled
        // `error.X` rather than `Error.X` throughout this function: an
        // `errdefer` with a payload capture only accepts the inferred form.)
        errdefer |e| self.latch(e);
        var input = chunk;
        // Finish a small item carried from the previous chunk: stitch input
        // bytes onto it until it completes, then fall through to the direct
        // zero-copy path for the rest of the chunk.
        while (self.carry_len > 0 and input.len > 0) {
            const n = @min(CARRY_CAP - self.carry_len, input.len);
            if (n == 0) return error.InvalidMessage; // cannot happen: items are < CARRY_CAP
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

    /// Record a terminal INVALID verdict, so every later `feed` repeats it.
    ///
    /// Only `error.InvalidMessage` latches: it is the one outcome §5.2 calls
    /// terminal. A receiver-side `error.LimitExceeded` raised by a visitor
    /// callback (§6.2.1) is a policy rejection about **well-formed** bytes and
    /// must not poison the decoder, and the other codes cannot reach a decode
    /// path at all.
    fn latch(self: *IStream, e: Error) void {
        @branchHint(.cold);
        if (e == Error.InvalidMessage) self.invalid = true;
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
    /// * `.invalid` once `feed` has rejected the consumed bytes with
    ///   `error.InvalidMessage`. That verdict is terminal (§5.2), so it
    ///   dominates the other two here as well: a decoder that has declared its
    ///   input malformed never reports `.complete` or `.incomplete` again until
    ///   `reset`.
    pub fn status(self: *const IStream) Status {
        if (self.invalid) return .invalid;
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
        // The resume check is the *outer* loop and the field loop is nested
        // inside it, so an ordinary scalar field never re-tests `self.state`:
        // it is only reachable on entry to `parse` and after a field that
        // actually starts a long item (a payload or an array). Each arm below
        // either returns — still hungry — or finishes, sets `.none`, and falls
        // through to the field loop.
        resume_loop: while (true) {
            // 1) Finish anything left in progress from a previous chunk.
            switch (self.state) {
                .none => {},
                .payload => {
                    pos = self.deliverPayload(buf, pos, visitor);
                    if (self.state == .payload) return pos; // still hungry
                },
                .array_int => |st| {
                    // Bulk run first, in its own function (see `intArrayRun`),
                    // then the tail — the last few elements of the chunk, any
                    // of which may be cut short by the end of the input.
                    // The bulk path exists to amortize its constant hoisting
                    // over many elements; below a handful its call setup costs
                    // more than it saves, so a short array goes straight to the
                    // tail loop.
                    var rem = st.remaining;
                    if (rem >= BULK_MIN_ELEMS) {
                        rem = if (st.signed)
                            try intArrayRun(buf, &pos, rem, st.id, true, visitor)
                        else
                            try intArrayRun(buf, &pos, rem, st.id, false, visitor);
                    }
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
                },
            }

            // 2) Field loop: read and dispatch fields back to back. Only a
            // field that starts a long item breaks out to the resume check.
            while (true) {
                if (pos >= buf.len) return pos;
                const field_start = pos;
                const header = (try varint.readVarint(buf, &pos)) orelse return field_start;
                const wire: u3 = @truncate(header);
                const id_raw = header >> 3;
                // §4.9/§6.2: `ID_MAX` binds the id of **every** field header
                // without exception — the value-bearing ones and the
                // sequence-end marker alike. That a sequence end's id is
                // discarded rather than used (§4.9) does not exempt it; the
                // ceiling is stated over headers, not over headers whose id a
                // decoder happens to consult. One unconditional comparison,
                // ahead of the wire-type dispatch, so no per-wire-type
                // exception has to be carried through the decode path (F-0054).
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
                        // Announce the field at its length word — before any
                        // payload byte, `total == 0` included — so a visitor
                        // enforcing a schema `maxlen` can latch INVALID here
                        // even when the message ends exactly at the length word.
                        // Without it the verdict would degrade to INCOMPLETE for
                        // that truncation while the same bytes read whole are
                        // INVALID — a chunk-boundary-dependent outcome §6.4/§7.2
                        // forbid; INVALID must dominate INCOMPLETE (§5.2).
                        // Raising from the callback is what rejects the field.
                        // This mirrors `arrayBegin` for arrays one field kind
                        // over; `@hasDecl` keeps it free for a visitor that does
                        // not declare it (no vtable, no runtime branch).
                        if (comptime @hasDecl(V, "fixlenBegin"))
                            try visitor.fixlenBegin(id, subtype, len);
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
                                    // Fully delivered: state is back to `.none`,
                                    // so the field loop simply carries on.
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
                            continue :resume_loop; // the elements are read there
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
                        // The hook fires only here — past the `fixlen_word` — and
                        // names the element subtype, so the receiver can decide
                        // whether this array is the declared field's value before
                        // applying any schema bound to `count` (§4.8 step 3).
                        if (comptime @hasDecl(V, "arrayBegin"))
                            visitor.arrayBegin(id, if (fp64) ArrayKind.fp64 else ArrayKind.fp32, @intCast(count));
                        if (count > 0) {
                            self.state = .{ .array_fix = .{
                                .id = id,
                                .fp64 = fp64,
                                .remaining = @intCast(count),
                            } };
                            continue :resume_loop; // the elements are read there
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

/// Decode the bulk of an integer array: elements from `buf[pos.*..]` for as
/// long as a maximum-length varint is guaranteed to be present, so no element
/// can straddle the end of the chunk and the SWAR decoder runs with no
/// per-element "is it all here?" bookkeeping. Returns the elements still
/// outstanding; `pos.*` is advanced past everything consumed.
///
/// **`noinline` on purpose.** The SWAR cascade needs five 64-bit mask
/// constants, and x86-64 has no 64-bit immediate AND — each one costs a
/// `movabs` unless it can live in a register across the loop. Inlined into
/// `parse`, whose register pressure is set by the whole field-dispatch switch,
/// they get rematerialized every single element. In a function of its own the
/// loop keeps them in registers and pays for them once per array. The call is
/// per array, not per element, so it costs nothing measurable.
///
/// `is_signed` is comptime so the ZigZag mapping and the visitor dispatch stay
/// off the per-element path.
noinline fn intArrayRun(
    buf: []const u8,
    pos: *usize,
    remaining: usize,
    id: Id,
    comptime is_signed: bool,
    visitor: anytype,
) Error!usize {
    const V = std.meta.Child(@TypeOf(visitor));
    // Exclusive cursor limit for the headroom guarantee — 0 when the chunk is
    // too short to give any element the full `MAX_VARINT_LEN` bytes.
    const fast_end: usize = if (buf.len >= varint.MAX_VARINT_LEN)
        buf.len - varint.MAX_VARINT_LEN + 1
    else
        0;
    var p = pos.*;
    var rem = remaining;
    while (rem > 0 and p < fast_end) : (rem -= 1) {
        const d = try varint.readVarintFast(buf.ptr + p);
        p += d.len;
        if (is_signed) {
            if (comptime @hasDecl(V, "signed")) visitor.signed(id, varint.zigzagDecode(d.value));
        } else {
            if (comptime @hasDecl(V, "unsigned")) visitor.unsigned(id, d.value);
        }
    }
    pos.* = p;
    return rem;
}

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
    os.writeSequenceBeginLazy(7) catch unreachable;
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

test "ID_MAX binds a sequence-end id like any other header (F-0054)" {
    // §4.9/§6.2: `ID_MAX` binds the id of *every* header, including the
    // sequence-end marker whose id is discarded. This is Option B — the id's
    // value is bounded, then discarded — not Option A, which exempted wire 7.
    //
    // Over-ceiling reproducer from the finding, which must be INVALID:
    //   76             — field id 14, wire 6 (SequenceStart): opens a sequence
    //   87 80 80 80 40 — wire 7 (SequenceEnd), id 2^31 (one past ID_MAX)
    var bad_end: Probe = .{};
    try testing.expectError(
        Error.InvalidMessage,
        decode(&.{ 0x76, 0x87, 0x80, 0x80, 0x80, 0x40 }, &bad_end),
    );

    // The same over-ID_MAX id on a value-bearing (unsigned, wire 0) header is
    // INVALID too — one unconditional rule, no per-wire-type branch. Header =
    // (2^31 << 3) | 0 = 2^34, then a 0x00 value byte.
    var bad_unsigned: Probe = .{};
    try testing.expectError(
        Error.InvalidMessage,
        decode(&.{ 0x80, 0x80, 0x80, 0x80, 0x40, 0x00 }, &bad_unsigned),
    );

    // Boundary, separating Option B from both A and C. Header = (id << 3) | 7.
    // id ID_MAX (2^31 - 1) accepts: ((2^31 - 1) << 3) | 7 = 2^34 - 1, encoded
    // 0xFF 0xFF 0xFF 0xFF 0x3F.
    var at_max: Probe = .{};
    try testing.expectEqual(
        Status.complete,
        try decode(&.{ 0x0E, 0xFF, 0xFF, 0xFF, 0xFF, 0x3F }, &at_max),
    );
    try testing.expectEqual(@as(u32, 1), at_max.ends);

    // A non-minimal spelling of an in-range id is still accepted and normalized
    // (§4.1 untouched) — this is what rules out Option C. id 0 spelled in two
    // bytes: 0x87 0x00 decodes to header 7 (wire 7, id 0). Opened by 0x0E.
    var noncanon: Probe = .{};
    try testing.expectEqual(Status.complete, try decode(&.{ 0x0E, 0x87, 0x00 }, &noncanon));
    try testing.expectEqual(@as(u32, 1), noncanon.begins);
    try testing.expectEqual(@as(u32, 1), noncanon.ends);
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

// Records every fixlenBegin call and, if `maxlen` is set, rejects a field whose
// declared length exceeds it — the schema-`maxlen` enforcement point.
const FixlenAnnounce = struct {
    calls: u32 = 0,
    last_id: Id = 0,
    last_subtype: FixlenType = .fp32,
    last_total: usize = 0,
    maxlen: usize = std.math.maxInt(usize),

    pub fn fixlenBegin(self: *FixlenAnnounce, id: Id, subtype: FixlenType, total: usize) Error!void {
        self.calls += 1;
        self.last_id = id;
        self.last_subtype = subtype;
        self.last_total = total;
        if (total > self.maxlen) return Error.InvalidMessage;
    }
};

test "fixlenBegin fires at the length word (id/subtype/total, total 0 included)" {
    // A zero-length string: header (3 << 3) | 2 = 0x1a, word (0 << 3) | 2 = 0x02.
    var s0: FixlenAnnounce = .{};
    try testing.expectEqual(Status.complete, try decode(&.{ 0x1a, 0x02 }, &s0));
    try testing.expectEqual(@as(u32, 1), s0.calls);
    try testing.expectEqual(@as(Id, 3), s0.last_id);
    try testing.expectEqual(FixlenType.string, s0.last_subtype);
    try testing.expectEqual(@as(usize, 0), s0.last_total);

    // A blob carrying its length: header 0x1a, word (5 << 3) | 3 = 0x2b, then 5
    // payload bytes. The subtype reported is what *arrived* (blob).
    var b5: FixlenAnnounce = .{};
    try testing.expectEqual(
        Status.complete,
        try decode(&.{ 0x1a, 0x2b, 1, 2, 3, 4, 5 }, &b5),
    );
    try testing.expectEqual(@as(u32, 1), b5.calls);
    try testing.expectEqual(FixlenType.blob, b5.last_subtype);
    try testing.expectEqual(@as(usize, 5), b5.last_total);
}

test "fixlenBegin latches maxlen INVALID at the length word, no payload byte needed" {
    // The finding's shape: a single over-maxlen string field truncated to end
    // exactly at its length word. header (3 << 3) | 2 = 0x1a, word (10 << 3) | 2
    // = 0x52 — length 10, no payload. With a maxlen of 4 the field is INVALID,
    // and that verdict must not depend on any payload byte arriving.
    const over = [_]u8{ 0x1a, 0x52 };

    // Whole, in one shot.
    var whole: FixlenAnnounce = .{ .maxlen = 4 };
    try testing.expectError(Error.InvalidMessage, decode(&over, &whole));
    try testing.expectEqual(@as(u32, 1), whole.calls);

    // One byte at a time — the length word only completes on the second feed,
    // and INVALID must be raised there, never degrading to INCOMPLETE.
    var chunked: FixlenAnnounce = .{ .maxlen = 4 };
    var is = IStream.init();
    try testing.expectEqual(Status.incomplete, try is.feed(over[0..1], &chunked));
    try testing.expectError(Error.InvalidMessage, is.feed(over[1..2], &chunked));

    // Control: the same truncation with a length inside the bound stays
    // INCOMPLETE — this is an ordering fix, not a blanket reject. The callback
    // still fires (the field was announced); it just does not raise.
    var in_bound: FixlenAnnounce = .{ .maxlen = 64 };
    try testing.expectEqual(Status.incomplete, try decode(&over, &in_bound));
    try testing.expectEqual(@as(u32, 1), in_bound.calls);
    try testing.expectEqual(@as(usize, 10), in_bound.last_total);
}

test "an INVALID verdict latches: later feeds repeat it and status reports it" {
    // §5.2 marks INVALID terminal ("can more bytes change it? — no"): after a
    // rejection the decoder must not resynchronize on the bytes that follow the
    // malformed construct, and `status` must not claim `.complete` for a stream
    // it has already declared malformed.
    var p: Probe = .{};
    var is = IStream.init();
    try testing.expectError(Error.InvalidMessage, is.feed(&.{0x07}, &p)); // dangling end
    try testing.expectEqual(Status.invalid, is.status());

    // A well-formed field after the rejection: neither decoded nor accepted.
    try testing.expectError(Error.InvalidMessage, is.feed(&.{ 0x00, 0x2A }, &p));
    try testing.expectEqual(Status.invalid, is.status());
    try testing.expectEqual(@as(u64, 0), p.unsigned_sum);

    // An empty end-of-input probe does not clear it either.
    try testing.expectError(Error.InvalidMessage, is.feed(&.{}, &p));
    try testing.expectEqual(Status.invalid, is.status());

    // `reset` is the documented way out.
    is.reset();
    try testing.expectEqual(Status.complete, try is.feed(&.{ 0x00, 0x2A }, &p));
    try testing.expectEqual(@as(u64, 42), p.unsigned_sum);
}

test "a receiver-side LimitExceeded is policy, not malformation: it does not latch" {
    // §6.2.1/§6.3: a receiver limit says nothing about the bytes' validity, so
    // it must not poison the decoder the way INVALID does. Only INVALID latches.
    const Limiter = struct {
        pub fn fixlenBegin(_: *@This(), _: Id, _: FixlenType, _: usize) Error!void {
            return Error.LimitExceeded;
        }
    };
    var lim: Limiter = .{};
    var is = IStream.init();
    // header (3 << 3) | 2 = 0x1a, word (10 << 3) | 2 = 0x52 — a 10-byte string.
    try testing.expectError(Error.LimitExceeded, is.feed(&.{ 0x1a, 0x52 }, &lim));
    try testing.expect(is.status() != .invalid);
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
