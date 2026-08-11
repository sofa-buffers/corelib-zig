//! The benchmark suite's datasets and operations — the one definition of what
//! this port measures (BENCH_SPEC, "Datasets").
//!
//! `bench.zig` (MB/s), `perf.zig` (cycles/op) and `callgrind.zig` (Ir/op) all
//! drive the workloads from here, so a workload cannot exist in one tool and be
//! missing from another, and the three tools cannot drift into measuring
//! different work. `tests/bench_spec_tests.zig` holds the table against
//! BENCH_SPEC's output grammar and runs every entry, so a row that stops
//! producing bytes fails the test suite rather than printing a plausible
//! number.
//!
//! Field ids, types and values are BENCH_SPEC's literals — never language math
//! constants — because the encoded bytes are what makes the ports comparable.
//! The two encoded sizes the spec states outright (`blob 1MB` = 1,000,005 bytes,
//! `composite` = 956) are parity checks: a port printing different ones is
//! encoding something else.

const std = @import("std");
const sofab = @import("sofab");

// ---------------------------------------------------------------------------
// dataset parameters
// ---------------------------------------------------------------------------

/// Element count of the `u64 array (1000)` workload.
pub const N = 1000;

/// `blob 1MB` payload length. The encoded message is `BLOB_LEN + 5` bytes on
/// every port — a 1-byte header, a 4-byte `fixlen_word` and the payload.
pub const BLOB_LEN = 1_000_000;

/// Buffer the streaming `blob 1MB` row encodes through, and the chunk size its
/// decode row is fed in. A fixed 4096 on every port rather than each port's own
/// buffer size, so the rows stay comparable (BENCH_SPEC).
pub const BLOB_CHUNK = 4096;

/// The multiplier behind both generated datasets: one magic number in the
/// suite, and the same derivation in every port.
const GOLDEN = 0x9E37_79B9_7F4A_7C15;

/// One cycle of the `composite` string field: 1-, 2-, 3- and 4-byte UTF-8
/// (`a`, `ä`, `€`, `𝄞`), spelled as bytes so no source encoding can change it.
const COMPOSITE_CYCLE = "a\xc3\xa4\xe2\x82\xac\xf0\x9d\x84\x9e";

// ---------------------------------------------------------------------------
// data and buffers (filled by `prepare`, never part of a measured operation)
// ---------------------------------------------------------------------------

/// `u64 array (1000)` source values and its encoded message.
pub var src: [N]u64 = undefined;
var u64_buf: [N * 11 + 16]u8 = undefined;
pub var u64_used: usize = 0;

/// The `typical` message.
var typ_buf: [256]u8 = undefined;
pub var typ_used: usize = 0;

/// `blob 1MB`: the payload, the one-shot output buffer (sized by hand to
/// 1,000,005 + slack, *not* from a generated `MAX_SIZE` — the schema is
/// unbounded, so there is no such size), and the 4096-byte buffer the streaming
/// row flushes through.
var blob_src: [BLOB_LEN]u8 = undefined;
var blob_enc: [BLOB_LEN + 16]u8 = undefined;
pub var blob_used: usize = 0;
var blob_scratch: [BLOB_CHUNK]u8 = undefined;
/// Bytes the streaming sink was handed, in total: the streaming row's own size,
/// so a row that did not move the whole megabyte fails the parity check instead
/// of borrowing the one-shot row's figure.
pub var blob_stream_used: usize = 0;
var blob_sink_acc: u8 = 0;

/// `composite`: the encoded message and the pieces of its two payload fields.
var comp_buf: [2048]u8 = undefined;
pub var comp_used: usize = 0;
var comp_text: [COMPOSITE_CYCLE.len * 32]u8 = undefined;
/// The 64 wrapper-array elements, `"item-0"` … `"item-63"`, built once at
/// startup: the dataset is the *values*, and formatting them inside the
/// measured run would put integer formatting into a figure meant to be the
/// encoder's. The longest is `"item-63"` (7 bytes).
var comp_items: [64][8]u8 = undefined;
var comp_item_len: [64]u8 = undefined;

/// Where every decode row's result lands, so nothing it decoded can be elided.
pub var checksum: u64 = 0;

/// The one-shot `blob 1MB` message, valid once `encodeBlobOneshot` has run.
pub fn blobMessage() []const u8 {
    return blob_enc[0..blob_used];
}

/// The `blob 1MB` payload itself (1,000,000 bytes), valid after `prepare`.
pub fn blobPayload() []const u8 {
    return &blob_src;
}

/// The `composite` message, valid once `encodeComposite` has run.
pub fn compositeMessage() []const u8 {
    return comp_buf[0..comp_used];
}

/// Build every dataset. Never part of a measured operation.
pub fn prepare() void {
    for (&src, 0..) |*v, i| v.* = @as(u64, i) *% GOLDEN;
    // Same constant as the u64 array, low byte.
    for (&blob_src, 0..) |*b, i| b.* = @truncate(@as(u64, i) *% GOLDEN);
    for (&comp_text, 0..) |*c, i| c.* = COMPOSITE_CYCLE[i % COMPOSITE_CYCLE.len];
    for (&comp_items, &comp_item_len, 0..) |*item, *len, i| {
        len.* = @intCast((std.fmt.bufPrint(item, "item-{d}", .{i}) catch unreachable).len);
    }
}

// ---------------------------------------------------------------------------
// visitors
// ---------------------------------------------------------------------------

/// Decode destination for every decode row but the skip-all one: it folds
/// every value into a checksum so the optimizer cannot elide the decode work,
/// and — like the reference implementation's — it folds a string/blob payload's
/// *length*, not its bytes. Copying the payload out would measure the
/// destination rather than the decoder, and this port hands the visitor a slice
/// borrowed straight out of the input buffer.
pub const Checksum = struct {
    acc: u64 = 0,

    pub fn unsigned(self: *Checksum, id: sofab.Id, v: u64) void {
        self.acc +%= v ^ id;
    }
    pub fn signed(self: *Checksum, id: sofab.Id, v: i64) void {
        self.acc +%= @as(u64, @bitCast(v)) ^ id;
    }
    pub fn fp32(self: *Checksum, _: sofab.Id, v: f32) void {
        self.acc +%= @as(u32, @bitCast(v));
    }
    pub fn fp64(self: *Checksum, _: sofab.Id, v: f64) void {
        self.acc +%= @as(u64, @bitCast(v));
    }
    pub fn string(self: *Checksum, _: sofab.Id, _: usize, _: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
    }
    pub fn blob(self: *Checksum, _: sofab.Id, _: usize, _: usize, chunk: []const u8) void {
        self.acc +%= chunk.len;
    }
    // Declaring `sequenceBegin` is what makes a visitor descend: without it the
    // decoder auto-skips whole sub-sequences, and the `typical` row would stop
    // decoding the two fields inside its nested scope — and the `composite` row
    // would skip its 64-element wrapper array outright, measuring the same work
    // as the skip-all row it is supposed to be read against (BENCH_SPEC).
    pub fn sequenceBegin(self: *Checksum, id: sofab.Id) void {
        self.acc +%= id;
    }
    pub fn sequenceEnd(self: *Checksum) void {
        self.acc +%= 1;
    }
};

/// The `decode: composite skip-all` destination: a visitor that declares no
/// callback at all. The decoder still walks every header, length word and
/// count — and consumes every sub-sequence whole — but nothing is delivered
/// anywhere. That is the path a router or filter runs in production, and its
/// distance from `decode: composite` is what not-decoding is worth.
const SkipAll = struct {};

/// The streaming `blob 1MB` row's sink. BENCH_SPEC is explicit that it
/// **consumes and discards**: accumulating the bytes would charge the streaming
/// row a copy the one-shot row never pays, and I/O is not deterministic under
/// Callgrind. Folding one byte per call is the minimum that keeps the call from
/// being optimised away; the byte counter is what proves the row really moved a
/// megabyte, and costs one add per flush.
///
/// It returns without installing a buffer, which is CORELIB_PLAN §5.1's
/// *copying* sink: the encoder resumes in the same 4096-byte buffer at offset 0.
fn blobSink(_: ?*anyopaque, data: []const u8) void {
    blob_sink_acc ^= if (data.len == 0) 0 else data[0];
    blob_stream_used += data.len;
}

// ---------------------------------------------------------------------------
// message writers
// ---------------------------------------------------------------------------

/// The `typical` message of BENCH_SPEC: a few scalars, a float, a short string
/// and a small array, plus a nested sequence. The literal values are the
/// spec's — every port encodes these exact bytes, so they must not be swapped
/// for language math constants.
pub fn writeTypical(os: *sofab.OStream) void {
    os.writeUnsigned(1, 0xDEAD_BEEF) catch unreachable;
    os.writeSigned(2, -12345) catch unreachable;
    os.writeBoolean(3, true) catch unreachable;
    os.writeFp32(4, 3.14159) catch unreachable;
    os.writeString(5, "sofab") catch unreachable;
    os.writeArrayUnsigned(6, &[_]u16{ 10, 20, 30, 40 }) catch unreachable;
    os.writeSequenceBeginLazy(7) catch unreachable;
    os.writeUnsigned(1, 99) catch unreachable;
    os.writeSigned(2, -7) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
}

/// The `composite` message (BENCH_SPEC), field by field and each for a reason:
///
/// * **id 1** — the suite's only **wrapper array** (MESSAGE_SPEC §5.1): one
///   field header per element, element id = array index, so ids 0–15 take a
///   one-byte header and 16–63 take two.
/// * **id 2** — 320 UTF-8 bytes covering 1-, 2-, 3- and 4-byte sequences, which
///   puts the §6.4 validator on a payload that is not ASCII.
/// * **id 3** — nesting at **depth 3**, so the lazy hold-back run grows past
///   the single level `typical` and `perf` reach.
/// * **id 4** — equal to its declared default, so the encoder must **not**
///   write it: `writeSequenceBeginLazy` + `writeSequenceEnd` with nothing in
///   between is the hold-back's discard path, the one branch nothing else in
///   the suite takes.
/// * **id 130** — the suite's only **two-byte field header**, `(130 << 3) | 0`.
///
/// Encodes to 956 bytes on every port — this dataset's parity check, the way
/// 170 is `perf`'s.
pub fn writeComposite(os: *sofab.OStream) void {
    os.writeSequenceBeginLazy(1) catch unreachable;
    for (&comp_items, comp_item_len, 0..) |*item, len, i| {
        os.writeString(@intCast(i), item[0..len]) catch unreachable;
    }
    os.writeSequenceEnd() catch unreachable;

    os.writeString(2, &comp_text) catch unreachable;

    os.writeSequenceBeginLazy(3) catch unreachable;
    os.writeSequenceBeginLazy(1) catch unreachable;
    os.writeSequenceBeginLazy(1) catch unreachable;
    os.writeUnsigned(1, 7) catch unreachable;
    os.writeSequenceEnd() catch unreachable;
    os.writeSequenceEnd() catch unreachable;
    os.writeSigned(2, -1) catch unreachable;
    os.writeSequenceEnd() catch unreachable;

    // id 4: all-default — opened and dropped, emitting nothing.
    os.writeSequenceBeginLazy(4) catch unreachable;
    os.writeSequenceEnd() catch unreachable;

    os.writeUnsigned(130, 0xDEAD_BEEF) catch unreachable;
}

// ---------------------------------------------------------------------------
// the operations — one op each, returning an observable
// ---------------------------------------------------------------------------

pub fn encodeU64Array() usize {
    var os = sofab.OStream.init(&u64_buf);
    os.writeArrayUnsigned(1, @as([]const u64, &src)) catch unreachable;
    u64_used = os.bytesUsed();
    return u64_used;
}

pub fn encodeTypical() usize {
    var os = sofab.OStream.init(&typ_buf);
    writeTypical(&os);
    typ_used = os.bytesUsed();
    return typ_used;
}

/// `blob 1MB`, the floor: the whole message into a caller buffer sized by hand
/// to hold it, **no sink**, so the payload is one contiguous write and no flush
/// logic runs.
pub fn encodeBlobOneshot() usize {
    var os = sofab.OStream.init(&blob_enc);
    os.writeBlob(1, &blob_src) catch unreachable;
    blob_used = os.bytesUsed();
    return blob_used;
}

/// The same bytes through a **4096-byte** caller buffer with a flush sink:
/// ~245 flushes, every one of them mid-payload, so this is the divisible-run
/// path of CORELIB_PLAN §5.1 end to end. Pass-through is **not** granted — this
/// port implements no such permission, so BENCH_SPEC's optional
/// `blob 1MB passthrough` row is omitted rather than printed as a placeholder.
///
/// The trailing `flush` is part of the op: it is what hands the last partial
/// buffer to the sink, so the row moves the same 1,000,005 bytes as the
/// one-shot row rather than 1,000,005 minus a remainder.
pub fn encodeBlobStreaming() usize {
    blob_stream_used = 0;
    var os = sofab.OStream.initFlush(&blob_scratch, 0, null, blobSink);
    os.writeBlob(1, &blob_src) catch unreachable;
    _ = os.flush();
    return blob_stream_used;
}

/// `blob 1MB` decode, fed in 4096-byte chunks: every chunk but the last ends
/// inside the payload, so all but the last feed reports INCOMPLETE and the
/// field is delivered piece by piece. A fresh `IStream` per op costs nothing —
/// this decoder owns no heap memory, only a small inline carry buffer.
pub fn decodeBlob() usize {
    var sink: Checksum = .{};
    var is = sofab.IStream.init();
    var off: usize = 0;
    while (off < blob_used) : (off += BLOB_CHUNK) {
        const n = @min(BLOB_CHUNK, blob_used - off);
        _ = is.feed(blob_enc[off..][0..n], &sink) catch unreachable;
    }
    checksum = sink.acc;
    return blob_used;
}

pub fn encodeComposite() usize {
    var os = sofab.OStream.init(&comp_buf);
    writeComposite(&os);
    comp_used = os.bytesUsed();
    return comp_used;
}

pub fn decodeU64Array() usize {
    return decodeWhole(u64_buf[0..u64_used]);
}

pub fn decodeTypical() usize {
    return decodeWhole(typ_buf[0..typ_used]);
}

pub fn decodeComposite() usize {
    return decodeWhole(comp_buf[0..comp_used]);
}

/// Decode a whole message with the checksum visitor — the shared body of the
/// contiguous decode rows.
fn decodeWhole(msg: []const u8) usize {
    var sink: Checksum = .{};
    var is = sofab.IStream.init();
    _ = is.feed(msg, &sink) catch unreachable;
    checksum = sink.acc;
    return msg.len;
}

/// `decode: composite skip-all` — walk the message, materialize nothing.
pub fn decodeCompositeSkip() usize {
    var sink: SkipAll = .{};
    var is = sofab.IStream.init();
    const st = is.feed(comp_buf[0..comp_used], &sink) catch unreachable;
    checksum = @intFromEnum(st);
    return comp_used;
}

// ---------------------------------------------------------------------------
// the workload table
// ---------------------------------------------------------------------------

/// One benchmark operation: performs exactly one op and returns an observable,
/// so nothing it did can be optimized away.
pub const Op = *const fn () usize;

/// One measured operation. `run` performs **exactly one** op and returns an
/// observable; `setup` prepares its input and is never measured; `bytes` is the
/// encoded message size the reports print, valid once the two have run.
pub const Workload = struct {
    /// CLI name; the Callgrind toggle is `run_<name>`.
    name: []const u8,
    /// Row label, per BENCH_SPEC's output grammar.
    label: []const u8,
    setup: ?Op = null,
    run: Op,
    bytes: *const usize,
};

/// Every row BENCH_SPEC's output grammar defines, in the order it prints them.
/// The optional `blob 1MB passthrough` row is absent on purpose: this port
/// implements no pass-through permission, and a port that does not implement it
/// omits the row rather than printing a placeholder.
pub const workloads = [_]Workload{
    .{ .name = "encode_u64_array", .label = "encode: u64 array (1000)", .run = &encodeU64Array, .bytes = &u64_used },
    .{ .name = "encode_typical", .label = "encode: typical message", .run = &encodeTypical, .bytes = &typ_used },
    .{ .name = "encode_blob_oneshot", .label = "encode: blob 1MB one-shot", .run = &encodeBlobOneshot, .bytes = &blob_used },
    .{ .name = "encode_blob_streaming", .label = "encode: blob 1MB streaming", .run = &encodeBlobStreaming, .bytes = &blob_stream_used },
    .{ .name = "encode_composite", .label = "encode: composite", .run = &encodeComposite, .bytes = &comp_used },
    .{ .name = "decode_u64_array", .label = "decode: u64 array (1000)", .setup = &encodeU64Array, .run = &decodeU64Array, .bytes = &u64_used },
    .{ .name = "decode_typical", .label = "decode: typical message", .setup = &encodeTypical, .run = &decodeTypical, .bytes = &typ_used },
    .{ .name = "decode_blob", .label = "decode: blob 1MB", .setup = &encodeBlobOneshot, .run = &decodeBlob, .bytes = &blob_used },
    .{ .name = "decode_composite", .label = "decode: composite", .setup = &encodeComposite, .run = &decodeComposite, .bytes = &comp_used },
    .{ .name = "decode_composite_skip", .label = "decode: composite skip-all", .setup = &encodeComposite, .run = &decodeCompositeSkip, .bytes = &comp_used },
};

/// The workload named `name`, or `null`.
pub fn find(name: []const u8) ?Workload {
    for (workloads) |wl| {
        if (std.mem.eql(u8, wl.name, name)) return wl;
    }
    return null;
}
