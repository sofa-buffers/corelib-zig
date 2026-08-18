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
    /// (1080 bytes on a 64-bit target). `depth` is checked against `MAX_DEPTH`
    /// before a push and `npending <= depth` always holds, so the array cannot
    /// overflow.
    pending: [types.MAX_DEPTH]Id = undefined,
    /// Number of valid entries in `pending`.
    npending: usize = 0,
    /// `null` means "no sink": a full buffer is an error rather than a flush.
    flush_fn: ?FlushFn = null,
    flush_ctx: ?*anyopaque = null,
    /// Set when an installation was **refused** (CORELIB_PLAN §5.1): an offset
    /// outside the buffer, or fewer than `MIN_OUTPUT_BUFFER` usable bytes behind
    /// a flush sink. The stream is then inert — it holds an empty slice of the
    /// buffer it refused, so no write can reach memory, and every write reports
    /// `error.InvalidArgument` instead. Reading it costs nothing on the hot
    /// path: the only place that consults it is the cold drain, which every
    /// write on an inert stream reaches because its buffer has no capacity.
    dead: bool = false,

    /// Set by `bufferSetChecked`, cleared around every sink call: whether the
    /// callback **installed** a buffer before it returned (CORELIB_PLAN §5.1).
    ///
    /// This is what separates the copy-and-continue shape from
    /// take-and-replace, and §5.1 has the callback state it rather than the
    /// encoder infer it: returning *without* installing means the sink copied,
    /// so the active buffer stays active and its cursor resumes at 0;
    /// installing means the sink took the buffer, and the replacement's cursor
    /// starts at *that call's* offset — the start offset belongs to the
    /// installation, not to the buffer. A pointer comparison would not do:
    /// passing the **same** buffer to `bufferSet` is a new installation like any
    /// other, which is how a sink re-arms its header room in every flushed unit.
    installed: bool = false,

    /// Whether `offset` names a position **in** `buffer`, which every
    /// installation requires, with a sink or without one. `offset == len` is in
    /// range — that is a buffer of capacity zero, which a sinkless stream may
    /// hold (the first write reports `error.BufferFull`). Past the end it names
    /// no installation at all, and §5.1's minimum — waived without a sink — has
    /// nothing to say about it either way.
    fn offsetInRange(len: usize, offset: usize) bool {
        return offset <= len;
    }

    /// Whether `buffer` may be installed **with a sink**: its usable capacity
    /// must reach `MIN_OUTPUT_BUFFER` (CORELIB_PLAN §5.1). An offset past the
    /// end is folded in — it leaves no capacity at all.
    fn streamingCapacityOk(len: usize, offset: usize) bool {
        return offsetInRange(len, offset) and len - offset >= types.MIN_OUTPUT_BUFFER;
    }

    /// The stream a refused installation leaves behind: no capacity, nothing
    /// written, every write `error.InvalidArgument`.
    fn refused(buffer: []u8, ctx: ?*anyopaque, flush_fn: ?FlushFn) OStream {
        return .{ .buffer = buffer[0..0], .offset = 0, .flush_fn = flush_fn, .flush_ctx = ctx, .dead = true };
    }

    /// Create an encoder over `buffer` with no flush sink. Writing past the
    /// end of the buffer returns `error.BufferFull`.
    ///
    /// No sink, and the cursor starts at `0`, so there is nothing to refuse:
    /// `MIN_OUTPUT_BUFFER` does not bind a buffer installed without a sink
    /// (§5.1) and even an empty buffer is a legal installation — the first
    /// write reports `error.BufferFull`.
    pub fn init(buffer: []u8) OStream {
        return .{ .buffer = buffer, .offset = 0 };
    }

    /// Like `init` but begin writing at `offset` bytes into the buffer,
    /// reserving space for a lower-layer protocol header.
    ///
    /// `offset` must name a position in `buffer` (`offset <= buffer.len`); an
    /// offset past the end names no installation and is **refused where it is
    /// handed over** (§5.1), leaving an inert stream whose every write reports
    /// `error.InvalidArgument` and whose `bytesUsed()` is `0`. No sink is
    /// attached, so `MIN_OUTPUT_BUFFER` does not bind here — the waiver is of
    /// the *minimum*, not of the offset's range. Use `initOffsetChecked` to
    /// take the refusal as an error status where the offset is computed.
    pub fn initOffset(buffer: []u8, offset: usize) OStream {
        return initOffsetChecked(buffer, offset) catch refused(buffer, null, null);
    }

    /// `initOffset`, reporting the range precondition as an error status.
    pub fn initOffsetChecked(buffer: []u8, offset: usize) Error!OStream {
        if (!offsetInRange(buffer.len, offset)) return Error.InvalidArgument;
        return .{ .buffer = buffer, .offset = offset };
    }

    /// Create an encoder with a flush sink, starting at `offset`. When the
    /// buffer fills, the accumulated bytes are passed to `flush_fn` and
    /// writing resumes at the start of the buffer.
    ///
    /// A buffer installed **with** a sink must offer at least
    /// `MIN_OUTPUT_BUFFER` usable bytes (`buffer.len - offset`, which an offset
    /// past the end makes nonexistent). A smaller one is **refused here**, where
    /// it is handed over, and never partway through a message (§5.1): the
    /// returned stream is inert — it writes nothing and reports
    /// `error.InvalidArgument` from every write. Use `initFlushChecked` to take
    /// that refusal as an error status instead.
    pub fn initFlush(buffer: []u8, offset: usize, ctx: ?*anyopaque, flush_fn: FlushFn) OStream {
        return initFlushChecked(buffer, offset, ctx, flush_fn) catch refused(buffer, ctx, flush_fn);
    }

    /// `initFlush`, reporting the capacity precondition as an error status.
    pub fn initFlushChecked(buffer: []u8, offset: usize, ctx: ?*anyopaque, flush_fn: FlushFn) Error!OStream {
        if (!streamingCapacityOk(buffer.len, offset)) return Error.InvalidArgument;
        return .{ .buffer = buffer, .offset = offset, .flush_fn = flush_fn, .flush_ctx = ctx };
    }

    /// Number of bytes written to the active buffer since the last flush.
    pub fn bytesUsed(self: *const OStream) usize {
        return self.offset;
    }

    /// Flush any pending bytes to the sink (if one is set) and report how many
    /// bytes were pending. With no sink the buffer is left intact.
    ///
    /// The sink may **take** the buffer instead of copying it, in which case it
    /// installs a replacement before returning and the stream resumes in that
    /// replacement, at the offset it was installed with (§5.1); see `callSink`.
    pub fn flush(self: *OStream) usize {
        const used = self.offset;
        if (used > 0) {
            if (self.flush_fn) |sink| {
                self.callSink(sink, used);
            }
        }
        return used;
    }

    /// Hand `used` buffered bytes to `sink` and resolve where the stream
    /// continues (CORELIB_PLAN §5.1, "what a returning flush callback leaves
    /// behind").
    ///
    /// The callback may install a buffer while it runs — that is how a taking
    /// sink hands the storage on — so the installation it leaves behind is the
    /// one that survives: only a sink that installed **nothing** copied, and
    /// only for it does the cursor go back to 0. Installing consumes the
    /// offset, so a later bare return still resumes at 0.
    fn callSink(self: *OStream, sink: FlushFn, used: usize) void {
        self.installed = false;
        sink(self.flush_ctx, self.buffer[0..used]);
        if (!self.installed) self.offset = 0;
    }

    /// Replace the active buffer (typically called from within a flush sink),
    /// resuming writes at `offset` in the new buffer.
    ///
    /// A mid-stream buffer-set is an installation like any other, judged by the
    /// same rule (§5.1): `offset` must name a position in `buffer`, and on a
    /// stream **with** a sink the usable capacity must reach
    /// `MIN_OUTPUT_BUFFER`. A replacement that fails either test is refused
    /// **here**, at the hand-over, and leaves the stream inert rather than
    /// writing on past the end of it: every later write reports
    /// `error.InvalidArgument`. That is the only outcome a sink can be told
    /// about, since a `FlushFn` returns no status; outside a sink,
    /// `bufferSetChecked` reports the same refusal as an error status.
    pub fn bufferSet(self: *OStream, buffer: []u8, offset: usize) void {
        self.bufferSetChecked(buffer, offset) catch {
            self.buffer = buffer[0..0];
            self.offset = 0;
            self.dead = true;
        };
    }

    /// `bufferSet`, reporting the installation preconditions as an error status.
    /// A refused replacement is not installed and leaves the stream untouched.
    ///
    /// An inert stream — one a refused installation already killed — stays
    /// inert: it is missing the writes it refused, so resuming it into a fresh
    /// buffer would hand back a truncated message as if it were whole. Build a
    /// new `OStream` instead.
    pub fn bufferSetChecked(self: *OStream, buffer: []u8, offset: usize) Error!void {
        if (self.dead) return Error.InvalidArgument;
        const ok = if (self.flush_fn != null)
            streamingCapacityOk(buffer.len, offset)
        else
            offsetInRange(buffer.len, offset);
        if (!ok) return Error.InvalidArgument;
        self.buffer = buffer;
        self.offset = offset;
        // The installation is what a sink call reads back to tell take-and-
        // replace from copy-and-continue; outside a sink call nothing reads it,
        // and the next call clears it before the callback runs.
        self.installed = true;
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
    ///
    /// Also where an inert stream (a refused installation, §5.1) surfaces: it
    /// holds a zero-capacity buffer, so every write lands here before it can
    /// store anything, and `InvalidArgument` is reported instead of a flush.
    /// A sink that refuses its own replacement kills the stream from inside the
    /// callback, so the check is repeated on the way out: the caller must not
    /// go on to store into the empty buffer a refusal leaves behind.
    fn drainFull(self: *OStream) Error!void {
        @branchHint(.cold);
        if (self.dead) return Error.InvalidArgument;
        const sink = self.flush_fn orelse return Error.BufferFull;
        self.callSink(sink, self.offset);
        if (self.dead) return Error.InvalidArgument;
    }

    /// Copy a raw byte slice out, draining the buffer as needed: a bulk
    /// `@memcpy` per buffer-sized run rather than a byte-at-a-time loop, and an
    /// inline copy for payloads short enough that the call would dominate.
    fn pushRaw(self: *OStream, data: []const u8) Error!void {
        // Fast path: the whole payload fits in the buffer as it stands, so no
        // drain can intervene. Short payloads — a float, a small string — are
        // the common case, and at those sizes the `memcpy` *call* costs several
        // times the copy itself, so they are copied inline instead.
        if (data.len <= self.buffer.len - self.offset) {
            const dst = self.buffer.ptr + self.offset;
            self.offset += data.len;
            if (data.len <= 8) {
                for (data, 0..) |b, i| dst[i] = b;
            } else {
                @memcpy(dst[0..data.len], data);
            }
            return;
        }
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
            // The headroom check is exactly `writeVarintFast`'s precondition:
            // it stores a whole 64-bit word, so the scratch it leaves past the
            // varint stays inside the buffer and the next write overwrites it.
            self.offset += varint.writeVarintFast(self.buffer.ptr + self.offset, value);
            return;
        }
        return self.writeVarintSlow(value);
    }

    /// Element count from which a varint run is worth handing to the bulk
    /// writer (`varint.writeVarintRunFast`) rather than encoding inline. Below
    /// a handful of elements its call setup costs more than the register
    /// pressure it relieves — the encode-side twin of `istream.BULK_MIN_ELEMS`.
    const BULK_MIN_ELEMS = 8;

    /// Encode every element of `data` as a varint back to back, ZigZag-mapping
    /// them first when `is_signed`.
    ///
    /// The cursor lives in **locals** for the whole run. Going through
    /// `writeVarint` per element would reload `self.offset` and `self.buffer`
    /// every time: the stores go through the buffer pointer, which the
    /// optimizer cannot prove does not alias the stream itself, so the state
    /// has to be re-read after each one. Hoisting it leaves one headroom test
    /// per element against a register, and the state is written back once.
    ///
    /// Only the element that runs out of headroom can need a flush mid-value,
    /// so it alone takes the checked byte-at-a-time writer; the loop then
    /// re-reads the (possibly swapped) buffer and continues.
    inline fn writeVarintRun(self: *OStream, data: anytype, comptime is_signed: bool) Error!void {
        var i: usize = 0;
        while (i < data.len) {
            const base = self.buffer.ptr;
            var off = self.offset;
            // How many elements are certain to fit without re-testing capacity:
            // the worst case is `MAX_VARINT_LEN` bytes each, so this many can be
            // written back to back. Bounding the run up front leaves the inner
            // loop with a single induction-variable compare instead of a
            // capacity test and an element test per element.
            const run = @min((self.buffer.len - off) / varint.MAX_VARINT_LEN, data.len - i);
            if (run >= BULK_MIN_ELEMS) {
                // Long enough to amortize the out-of-line call that keeps the
                // SWAR masks in registers for the whole run.
                off += varint.writeVarintRunFast(base + off, data[i..][0..run], is_signed);
                i += run;
            } else {
                const end = i + run;
                while (i < end) : (i += 1) {
                    const v: Unsigned = if (is_signed) varint.zigzagEncode(data[i]) else data[i];
                    off += varint.writeVarintFast(base + off, v);
                }
            }
            self.offset = off;
            // `run == 0` is the only case the fast path cannot make progress on:
            // there is not enough headroom left for even one worst-case varint,
            // so this element is the one that may need a flush partway through.
            // Otherwise loop back and re-measure — the elements just written
            // were usually shorter than the worst case, so more headroom remains
            // than the conservative `run` assumed.
            if (run == 0) {
                const v: Unsigned = if (is_signed) varint.zigzagEncode(data[i]) else data[i];
                try self.writeVarintSlow(v);
                i += 1;
            }
        }
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

    /// Headroom that guarantees a field header *and* one following varint fit
    /// without re-testing capacity between them.
    const PAIR_HEADROOM = 2 * varint.MAX_VARINT_LEN;

    /// Write a field header immediately followed by `word` — the shape of every
    /// non-sequence field: a scalar's value, a fixlen's length/subtype word, an
    /// array's element count.
    ///
    /// The point is the **single** capacity test. Writing the two through
    /// `writeIdType` + `writeVarint` re-reads `self.offset` and `self.buffer`
    /// between them, because the first store goes through the buffer pointer
    /// and the optimizer cannot prove it does not alias the stream itself.
    /// With the headroom established once, both go out through a local cursor
    /// and the state is written back a single time.
    ///
    /// Every condition the general path enforces is a condition for taking the
    /// fast one, so the fallback preserves semantics exactly: an out-of-range
    /// `id` still reaches `writeIdType`'s `InvalidArgument`, a held-back
    /// sequence run still reaches `commitPending`, and a buffer too full still
    /// reaches the drain/flush path.
    inline fn writeHeaderAnd(self: *OStream, id: Id, wire_type: u3, word: Unsigned) Error!void {
        if (self.npending == 0 and id <= types.ID_MAX and
            self.buffer.len - self.offset >= PAIR_HEADROOM)
        {
            const base = self.buffer.ptr;
            var off = self.offset;
            off += varint.writeVarintFast(base + off, (@as(Unsigned, id) << 3) | wire_type);
            off += varint.writeVarintFast(base + off, word);
            self.offset = off;
            return;
        }
        try self.writeIdType(id, wire_type);
        try self.writeVarint(word);
    }

    // --- scalar writers -----------------------------------------------------
    //
    // The value writers below are `inline`, which on this profile is not a
    // style choice: a generated `serialize()` is a straight run of these calls,
    // and out of line each one costs a call, a frame and an error-union return
    // around a dozen instructions of actual work — a third of what writing the
    // measured `typical` message costs. Inlined, the header/value pair also
    // sees the field's `id` as the constant the call site passed, so the
    // `ID_MAX` bound folds away with it. The bodies stay one line each:
    // everything that would make inlining expensive — the held-back sequence
    // run, the drain, the UTF-8 gate, the array element runs — sits behind an
    // out-of-line call already.

    /// Write an unsigned-integer field.
    pub inline fn writeUnsigned(self: *OStream, id: Id, value: Unsigned) Error!void {
        return self.writeHeaderAnd(id, types.T_VARINT_UNSIGNED, value);
    }

    /// Write a signed-integer field (ZigZag + varint).
    pub inline fn writeSigned(self: *OStream, id: Id, value: Signed) Error!void {
        return self.writeHeaderAnd(id, types.T_VARINT_SIGNED, varint.zigzagEncode(value));
    }

    /// Write a boolean as an unsigned `0` / `1` (booleans have no wire type of
    /// their own, §4.4).
    pub inline fn writeBoolean(self: *OStream, id: Id, value: bool) Error!void {
        try self.writeUnsigned(id, @intFromBool(value));
    }

    // --- fixed-length writers ------------------------------------------------

    /// Write a fixed-length field: header, `(len << 3) | subtype` varint, then
    /// the raw `data` bytes (already in wire/little-endian order for floats).
    ///
    /// This is the one entry point that names the subtype from a value, so it
    /// is also where the `string` UTF-8 policy has to live (CORELIB_PLAN §6.4):
    /// `writeString` is just the convenience spelling of `writeFixlen(id, text,
    /// .string)`, and a check that sat only there would leave the generic call
    /// — public API for direct corelib use, §6.1 — able to emit a `string`
    /// field the family's decoders are required to reject.
    ///
    /// The subtype test costs nothing on the `blob`/`fp*` paths: every in-tree
    /// caller passes a compile-time-known subtype, so it folds away there, and
    /// the whole gate folds away in a `-Dstrict_utf8=false` build.
    pub fn writeFixlen(self: *OStream, id: Id, data: []const u8, subtype: FixlenType) Error!void {
        if (comptime utf8.STRICT_UTF8) {
            if (subtype == .string and !utf8.utf8Valid(data)) return Error.InvalidArgument;
        }
        if (data.len > types.FIXLEN_MAX) return Error.InvalidArgument;
        try self.writeHeaderAnd(id, types.T_FIXLEN, (@as(Unsigned, data.len) << 3) | @intFromEnum(subtype));
        try self.pushRaw(data);
    }

    /// Write a fixlen field whose payload width is known at compile time.
    ///
    /// The payload arrives as its raw **bit pattern**, never as a float value,
    /// so nothing in this path can quiet a signaling NaN (CORELIB_PLAN §6.5);
    /// and because the width is comptime, the payload is a single store instead
    /// of a stack temporary handed to the slice-copying `pushRaw`.
    inline fn writeFixedFixlen(
        self: *OStream,
        id: Id,
        comptime T: type,
        bits: T,
        comptime subtype: FixlenType,
    ) Error!void {
        const N = @sizeOf(T);
        try self.writeHeaderAnd(id, types.T_FIXLEN, (@as(Unsigned, N) << 3) | @intFromEnum(subtype));
        if (self.buffer.len - self.offset >= N) {
            std.mem.writeInt(T, (self.buffer.ptr + self.offset)[0..N], bits, .little);
            self.offset += N;
            return;
        }
        // Straddles the end of the buffer: fall back to the draining copy.
        var le: [N]u8 = undefined;
        std.mem.writeInt(T, &le, bits, .little);
        return self.pushRaw(&le);
    }

    /// Write a 32-bit float field.
    pub inline fn writeFp32(self: *OStream, id: Id, value: f32) Error!void {
        return self.writeFixedFixlen(id, u32, @bitCast(value), .fp32);
    }

    /// Write a 64-bit float field.
    pub inline fn writeFp64(self: *OStream, id: Id, value: f64) Error!void {
        return self.writeFixedFixlen(id, u64, @bitCast(value), .fp64);
    }

    /// Write a string field (UTF-8 bytes, no NUL on the wire).
    ///
    /// Under `SOFAB_STRICT_UTF8` (on by default, CORELIB_PLAN §6.4) a `string`
    /// value that is not valid UTF-8 is refused with `error.InvalidArgument`:
    /// encode-side validation enforces MESSAGE_SPEC §8's producer-side MUST NOT,
    /// so a strict ecosystem's own encoders cannot emit bytes its decoders
    /// reject. When the option is compiled off the check folds away and the
    /// bytes are written verbatim. The check itself lives in `writeFixlen`, so
    /// naming the `string` subtype through the generic call is held to exactly
    /// the same policy.
    pub inline fn writeString(self: *OStream, id: Id, text: []const u8) Error!void {
        try self.writeFixlen(id, text, .string);
    }

    /// Write a binary blob field.
    pub inline fn writeBlob(self: *OStream, id: Id, data: []const u8) Error!void {
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
        try self.writeHeaderAnd(id, types.T_VARINTARRAY_UNSIGNED, @as(Unsigned, data.len));
        try self.writeVarintRun(data, false);
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
        try self.writeHeaderAnd(id, types.T_VARINTARRAY_SIGNED, @as(Unsigned, data.len));
        try self.writeVarintRun(data, true);
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
        try self.writeHeaderAnd(id, types.T_FIXLENARRAY, @as(Unsigned, data.len));
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
        try self.writeHeaderAnd(id, types.T_FIXLENARRAY, @as(Unsigned, data.len));
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

test "writeFixlen: the .string subtype is held to the same UTF-8 policy (§6.4)" {
    // `writeString` is only the convenience spelling; the generic `writeFixlen`
    // is public API too (§6.1 direct-corelib use) and can name the `string`
    // subtype itself. Whatever policy one enforces the other must enforce, or a
    // strict build can still emit a `string` field its own decoder is required
    // to reject.
    const bad = [_]u8{ 0xC0, 0x80 }; // overlong NUL
    var buf: [16]u8 = undefined;
    var os = OStream.init(&buf);
    // `blob` carries opaque bytes and is never validated, in either build.
    try os.writeFixlen(1, &bad, .blob);
    const before = os.bytesUsed();
    if (comptime utf8.STRICT_UTF8) {
        try testing.expectError(Error.InvalidArgument, os.writeFixlen(2, &bad, .string));
        // Refused before any of it reaches the wire.
        try testing.expectEqual(before, os.bytesUsed());
    } else {
        try os.writeFixlen(2, &bad, .string);
    }
    // Valid UTF-8 goes through the generic entry point unchanged.
    try os.writeFixlen(3, "ok\xC2\xA2", .string);
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

/// The flush sink the streaming tests below drive: it records the bytes it was
/// handed, so a test can compare them against the one-shot encoding, and how
/// often it was called, so a test can assert it was never called at all.
const CountingSink = struct {
    out: [128]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn push(ctx: ?*anyopaque, data: []const u8) void {
        const self: *CountingSink = @ptrCast(@alignCast(ctx.?));
        @memcpy(self.out[self.len..][0..data.len], data);
        self.len += data.len;
        self.calls += 1;
    }
};

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

    var sink: CountingSink = .{};
    var tiny: [3]u8 = undefined;
    var os = OStream.initFlush(&tiny, 0, &sink, CountingSink.push);
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
    var sink: CountingSink = .{};
    var tiny: [2]u8 = undefined;
    var os = OStream.initFlush(&tiny, 0, &sink, CountingSink.push);
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

// --- §5.1 buffer installation ------------------------------------------------

test "a sink-backed buffer below MIN_OUTPUT_BUFFER is refused at the hand-over (§5.1)" {
    // One byte short of the minimum — for this port's declared `1`, a buffer
    // with zero usable bytes. It must be refused where it is handed over, never
    // partway through a message, and it must not write a single byte: the
    // surrounding guard bytes prove no store escaped the (empty) slice.
    var guard: [16]u8 = @splat(0x11);
    var sink: CountingSink = .{};

    var os = OStream.initFlush(guard[8..8], 0, &sink, CountingSink.push);
    try testing.expectError(Error.InvalidArgument, os.writeUnsigned(1, 1));
    try testing.expectError(Error.InvalidArgument, os.writeString(2, "abc"));
    try testing.expectEqual(@as(usize, 0), os.bytesUsed());
    try testing.expectEqual(@as(usize, 0), os.flush());
    try testing.expectEqual(@as(usize, 0), sink.calls);
    for (guard) |b| try testing.expectEqual(@as(u8, 0x11), b);

    // The same refusal as an error status, and the same for a non-empty buffer
    // whose *offset* leaves less than the minimum behind it.
    try testing.expectError(
        Error.InvalidArgument,
        OStream.initFlushChecked(guard[8..8], 0, &sink, CountingSink.push),
    );
    try testing.expectError(
        Error.InvalidArgument,
        OStream.initFlushChecked(&guard, guard.len, &sink, CountingSink.push),
    );
    // Exactly the minimum is accepted.
    _ = try OStream.initFlushChecked(&guard, guard.len - types.MIN_OUTPUT_BUFFER, &sink, CountingSink.push);
}

test "a start offset past the end is refused at the hand-over (§5.1)" {
    var guard: [8]u8 = @splat(0x22);

    var os = OStream.initOffset(&guard, 100);
    try testing.expectError(Error.InvalidArgument, os.writeUnsigned(1, 1));
    try testing.expectEqual(@as(usize, 0), os.bytesUsed());
    for (guard) |b| try testing.expectEqual(@as(u8, 0x22), b);

    try testing.expectError(Error.InvalidArgument, OStream.initOffsetChecked(&guard, 100));
    // `offset == len` is in range: a capacity of zero, legal without a sink.
    var edge = try OStream.initOffsetChecked(&guard, guard.len);
    try testing.expectError(Error.BufferFull, edge.writeUnsigned(1, 1));
}

test "the minimum binds only a buffer installed with a sink (§5.1)" {
    // The converse of the rejection above: the very buffer a sink cannot have —
    // zero usable bytes — is a legal installation *without* one, and a message
    // that fits in it encodes. A sequence closed contentless is exactly that
    // message: it occupies no bytes at all (MESSAGE_SPEC §2).
    var buf: [4]u8 = @splat(0x33);
    var os = OStream.init(buf[0..0]);
    try os.writeSequenceBeginLazy(1);
    try os.writeSequenceEnd();
    try testing.expectEqual(@as(usize, 0), os.bytesUsed());
    // A field does not fit, and says so with BufferFull — the sinkless
    // overflow — not with the installation refusal.
    try testing.expectError(Error.BufferFull, os.writeUnsigned(1, 1));
    for (buf) |b| try testing.expectEqual(@as(u8, 0x33), b);

    // And the minimum is no floor on a one-shot buffer either: a two-byte
    // message still encodes into exactly two bytes.
    var exact: [2]u8 = undefined;
    var os2 = OStream.init(&exact);
    try os2.writeUnsigned(0, 127);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x7F }, exact[0..os2.bytesUsed()]);
}

test "a buffer of exactly MIN_OUTPUT_BUFFER streams the one-shot bytes (§5.1)" {
    const ops = struct {
        fn f(os: *OStream) Error!void {
            try os.writeUnsigned(1, 300);
            // A payload run far longer than the buffer: the divisible-run path.
            try os.writeString(2, "sofabuffers streams through one byte at a time");
            try os.writeArrayUnsigned(3, &[_]u32{ 1, 128, 70000 });
            try os.writeFp64(4, 1.5);
        }
    }.f;

    var one_shot_buf: [128]u8 = undefined;
    const one_shot = try encoded(&one_shot_buf, ops);

    var sink: CountingSink = .{};
    var tiny: [types.MIN_OUTPUT_BUFFER]u8 = undefined;
    var os = OStream.initFlush(&tiny, 0, &sink, CountingSink.push);
    try ops(&os);
    _ = os.flush();
    try testing.expectEqualSlices(u8, one_shot, sink.out[0..sink.len]);
}

test "a refused mid-stream buffer-set leaves the stream inert (§5.1)" {
    var sink: CountingSink = .{};
    var buf: [8]u8 = undefined;
    var os = OStream.initFlush(&buf, 0, &sink, CountingSink.push);
    try os.writeUnsigned(1, 1);

    // Refused as an error status: nothing is installed, the stream keeps
    // writing into the buffer it already had.
    var replacement: [2]u8 = @splat(0x44);
    try testing.expectError(Error.InvalidArgument, os.bufferSetChecked(&replacement, 5));
    try testing.expectError(Error.InvalidArgument, os.bufferSetChecked(replacement[0..0], 0));
    try os.writeUnsigned(2, 2);
    try testing.expectEqual(@as(usize, 4), os.bytesUsed());

    // Refused at the hand-over a sink can only take one way: the stream goes
    // inert instead of writing past the end of the replacement.
    os.bufferSet(&replacement, 5);
    try testing.expectError(Error.InvalidArgument, os.writeUnsigned(3, 3));
    try testing.expectEqual(@as(usize, 0), os.bytesUsed());
    for (replacement) |b| try testing.expectEqual(@as(u8, 0x44), b);
    // An inert stream is not revived by a sound buffer: it is missing the
    // writes it refused.
    var fresh: [16]u8 = undefined;
    try testing.expectError(Error.InvalidArgument, os.bufferSetChecked(&fresh, 0));

    // Without a sink the minimum does not bind a replacement — only the range
    // of its offset does.
    var sinkless = OStream.init(&buf);
    try sinkless.bufferSetChecked(replacement[0..0], 0);
    try testing.expectError(Error.BufferFull, sinkless.writeUnsigned(1, 1));
    try testing.expectError(Error.InvalidArgument, sinkless.bufferSetChecked(&replacement, 3));
}

/// Drives the same short message through every §5.1 sink shape below: enough
/// fields that a 16-byte buffer with a reservation flushes several times.
fn reservedRoomOps(os: *OStream) Error!void {
    var i: Id = 0;
    while (i < 16) : (i += 1) try os.writeUnsigned(i, 1);
}

test "a taking sink's replacement keeps its own start offset (§5.1)" {
    // The take-and-replace half of the returning-callback contract: the sink
    // takes the buffer it was handed and installs a *different* one, with
    // header room reserved, before returning. The start offset belongs to that
    // installation, so every flushed unit — not only the first — begins with
    // the bytes the sink reserved.
    const reserve = 4;
    const Taking = struct {
        a: [16]u8 = @splat(0xEE),
        b: [16]u8 = @splat(0xEE),
        units: [8][16]u8 = undefined,
        lens: [8]usize = @splat(0),
        n: usize = 0,
        os: *OStream = undefined,

        fn push(ctx: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.units[self.n][0..data.len], data);
            self.lens[self.n] = data.len;
            self.n += 1;
            // Taken, not copied: scrub the buffer we were handed so a store the
            // encoder makes into it after we return shows up as garbage rather
            // than as the bytes we already carried away.
            const took_a = @intFromPtr(data.ptr) == @intFromPtr(&self.a);
            const handed: *[16]u8 = if (took_a) &self.a else &self.b;
            const fresh: *[16]u8 = if (took_a) &self.b else &self.a;
            @memset(handed, 0xAA);
            @memset(fresh, 0xEE);
            self.os.bufferSet(fresh, reserve);
        }
    };

    var one_shot_buf: [128]u8 = undefined;
    const one_shot = try encoded(&one_shot_buf, reservedRoomOps);

    var sink: Taking = .{};
    var os = OStream.initFlush(&sink.a, reserve, &sink, Taking.push);
    sink.os = &os;
    try reservedRoomOps(&os);
    _ = os.flush();

    try testing.expect(sink.n >= 3); // several flushes, so the swap really runs
    var joined: [128]u8 = undefined;
    var len: usize = 0;
    for (sink.units[0..sink.n], sink.lens[0..sink.n]) |unit, unit_len| {
        // The reservation survived the return: the sink's own header room is
        // still its own, in this unit as in the first.
        try testing.expect(unit_len > reserve);
        for (unit[0..reserve]) |b| try testing.expectEqual(@as(u8, 0xEE), b);
        @memcpy(joined[len..][0 .. unit_len - reserve], unit[reserve..unit_len]);
        len += unit_len - reserve;
    }
    // And the payload behind the reservations is the one-shot message.
    try testing.expectEqualSlices(u8, one_shot, joined[0..len]);
}

test "re-installing the same buffer re-arms its reservation (§5.1)" {
    // "Passing the same buffer to buffer-set is a new installation like any
    // other" — that is how a copying sink gets fresh header room in every
    // flushed unit, so the distinction cannot be drawn by comparing pointers.
    const reserve = 3;
    const Rearming = struct {
        buf: [16]u8 = @splat(0xEE),
        units: [8][16]u8 = undefined,
        lens: [8]usize = @splat(0),
        n: usize = 0,
        os: *OStream = undefined,

        fn push(ctx: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.units[self.n][0..data.len], data);
            self.lens[self.n] = data.len;
            self.n += 1;
            @memset(&self.buf, 0xEE);
            self.os.bufferSet(&self.buf, reserve);
        }
    };

    var one_shot_buf: [128]u8 = undefined;
    const one_shot = try encoded(&one_shot_buf, reservedRoomOps);

    var sink: Rearming = .{};
    var os = OStream.initFlush(&sink.buf, reserve, &sink, Rearming.push);
    sink.os = &os;
    try reservedRoomOps(&os);
    _ = os.flush();

    try testing.expect(sink.n >= 3);
    var joined: [128]u8 = undefined;
    var len: usize = 0;
    for (sink.units[0..sink.n], sink.lens[0..sink.n]) |unit, unit_len| {
        try testing.expect(unit_len > reserve);
        for (unit[0..reserve]) |b| try testing.expectEqual(@as(u8, 0xEE), b);
        @memcpy(joined[len..][0 .. unit_len - reserve], unit[reserve..unit_len]);
        len += unit_len - reserve;
    }
    try testing.expectEqualSlices(u8, one_shot, joined[0..len]);
}

test "a copying sink that returns without installing resumes at 0 (§5.1)" {
    // The other half of the contract, and the reason the distinction is a flag
    // the callback sets rather than a property of the buffer: this sink
    // installs nothing, so the offset it was installed with is consumed by the
    // first flush and every later unit starts at 0.
    var sink: CountingSink = .{};
    var buf: [16]u8 = @splat(0xEE);
    var os = OStream.initFlush(&buf, 4, &sink, CountingSink.push);
    try reservedRoomOps(&os);
    _ = os.flush();

    var one_shot_buf: [128]u8 = undefined;
    const one_shot = try encoded(&one_shot_buf, reservedRoomOps);
    // One reservation, in the first unit only: the rest of the stream is the
    // message, contiguous behind it.
    try testing.expect(sink.calls >= 3);
    for (sink.out[0..4]) |b| try testing.expectEqual(@as(u8, 0xEE), b);
    try testing.expectEqualSlices(u8, one_shot, sink.out[4..sink.len]);
}

test "a replacement the sink cannot install leaves the stream inert (§5.1)" {
    // The refusal rule does not soften inside a callback: a sink that installs
    // an unusable replacement kills the stream there, and the write that
    // triggered the flush reports it instead of storing into the buffer that
    // was refused.
    const BadTaker = struct {
        buf: [16]u8 = undefined,
        replacement: [8]u8 = @splat(0x55),
        calls: usize = 0,
        os: *OStream = undefined,

        fn push(ctx: ?*anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            // No usable bytes behind the offset: below MIN_OUTPUT_BUFFER.
            self.os.bufferSet(&self.replacement, self.replacement.len);
        }
    };

    var sink: BadTaker = .{};
    var os = OStream.initFlush(&sink.buf, 0, &sink, BadTaker.push);
    sink.os = &os;
    try testing.expectError(Error.InvalidArgument, reservedRoomOps(&os));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectError(Error.InvalidArgument, os.writeUnsigned(1, 1));
    for (sink.replacement) |b| try testing.expectEqual(@as(u8, 0x55), b);
}
