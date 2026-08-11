<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

[Would you like to know more?](https://github.com/sofa-buffers)

## SofaBuffers Zig library

[![CI](https://github.com/sofa-buffers/corelib-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/sofa-buffers/corelib-zig/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsofa-buffers%2Fcorelib-zig%2Fbadges%2Fcoverage.json)](https://github.com/sofa-buffers/corelib-zig/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-1f7feb)](https://sofa-buffers.github.io/corelib-zig/)

[GitHub repository](https://github.com/sofa-buffers/corelib-zig)

A **maximum-throughput, streaming** Zig implementation of the SofaBuffers
(*Sofab*) serialization format. The decoder advances a Protocol-Buffers-style
cursor over contiguous memory with zero copies, field dispatch is comptime duck
typing (monomorphized, no vtable), and the codec itself — `OStream` *and*
`IStream`/`decode` — is **allocation-free**: caller-owned buffers on both sides,
a fixed carry buffer inside the streaming decoder, no allocator held or taken.
(The `sofab.arrays` helpers that generated *decode* code uses for dynamically
sized arrays are the one exception: they take the caller's allocator as an
argument.) It is wire-compatible, byte-for-byte, with every other `corelib-*`
port.

### Requirements

**Zig 0.16.0 or newer.** No OS assumptions in the library itself; the benchmark
tools use the Linux process-CPU clock.

Add the package to your project and wire up the `sofab` module:

```bash
zig fetch --save git+https://github.com/sofa-buffers/corelib-zig
```

```zig
// build.zig
const corelib = b.dependency("sofa_buffers_corelib", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sofab", corelib.module("sofab"));
```

```zig
const sofab = @import("sofab");
```

The package name is `sofa_buffers_corelib` (the family's `sofa-buffers` +
`corelib` naming, delimited as a Zig identifier); the importable namespace is
`sofab`.

### Dependencies

None — only the Zig standard library, and `std.json` is used solely by the test
suite. Nothing is pulled into downstream builds.

## Why this design

| Goal | How |
|------|-----|
| Streaming **out** | `OStream` writes into a caller buffer and calls a flush callback when it fills, so a message can exceed the buffer; `bufferSet` swaps the buffer mid-stream. |
| Streaming **in** | `IStream.feed` takes arbitrarily small chunks and suspends/resumes at any byte boundary; string/blob payloads are delivered incrementally. |
| Zero unnecessary copies | `decode` parses straight from the input buffer, handing string/blob fields back as borrowed slices; `feed` copies only the few bytes of the one small item that straddles a chunk boundary — once that item is complete the rest of the chunk is parsed in place, at full contiguous speed. |
| No allocation | The codec is allocator-free — not just the hot path. Encoder state is a struct over your buffer (plus the inline sequence hold-back run, see below); the decoder's only memory is a fixed 64-byte carry buffer. Only the `sofab.arrays` helpers for dynamically sized arrays take an allocator, and only as a parameter. |
| Raw speed | Unchecked pointer-advancing varint encode *and* decode once bounds are guaranteed, bulk `@memcpy`/native little-endian float loads, comptime-monomorphized visitor dispatch, **inline field writers** (a generated `serialize()` pays no call per field), `@branchHint(.cold)` on the drain path and on the chunk-boundary stitch, ReleaseFast shipping profile. |
| Type safety | Wire types and value widths live in the type system; array element widths are comptime-checked, so an invalid element type is a compile error. |
| Cross-language compatibility | The shared `assets/test_vectors.json` is replayed — the same bytes every other port produces — plus a big-endian (s390x) CI leg. |

## Usage

The codec has four use cases — serialize a message that fits in one buffer,
serialize one too large for the buffer (streamed out in chunks), deserialize a
whole message, and deserialize one arriving in chunks — plus the generated-code
path that wraps them.

### Serialize

`OStream.init` wraps a caller-owned buffer big enough for the whole message.
Each `write*` returns an error union, never allocates, and `bytesUsed()`
reports the byte count:

```zig
const sofab = @import("sofab");

var buf: [64]u8 = undefined;
var os = sofab.OStream.init(&buf);
try os.writeUnsigned(1, 42);
try os.writeSigned(2, -7);
try os.writeString(3, "hi");
const message = buf[0..os.bytesUsed()];
```

Nested scopes are opened with `writeSequenceBeginLazy(id)`, which **holds the
header back** until the sequence turns out to have content — that is what lets
the message layer omit an all-default sequence without ever buffering the
sub-message (MESSAGE_SPEC §2, CORELIB_PLAN §6). Which closer you use is a
property of the *position*, decided at generation time, not of the value:

```zig
try os.writeSequenceBeginLazy(4);
try os.writeUnsigned(1, 99);
try os.writeSequenceEnd(); // struct/union field, or an array field:
                           // a sequence that got no content vanishes entirely
```

| position | closer |
|---|---|
| `struct` / `union` field | `writeSequenceEnd` |
| array field (the wrapper) | `writeSequenceEnd` |
| wrapper-array **element** (`struct`/`union`/nested row) | `writeSequenceEndKeep` |
| array field known to differ from a **non-empty** declared `default` | `writeSequenceEndKeep` |

`writeSequenceEndKeep` behaves like a write: it emits the held-back headers and
the end marker, so a contentless sequence still reaches the wire as
`begin` + `end`. It is the safe default when a call site is ambiguous — using it
where `writeSequenceEnd` would do costs one non-canonical empty frame that every
decoder normalizes away, while the reverse drops an array element and silently
changes the decoded array's **length** (MESSAGE_SPEC §5.1).

**How deep the hold-back reaches.** All the way: up to `MAX_DEPTH` (255), the
format's own nesting ceiling. There is no window past which this encoder gives
up and frames eagerly, so a sequence closed contentless is omitted at *every*
depth and the bytes are canonical everywhere (CORELIB_PLAN §6). The price is
paid in the struct rather than on the heap — the run is reserved inline, 255
ids, so an `OStream` value is 1080 bytes on a 64-bit target and still allocates
nothing. Only a heap-free profile is allowed to bound the run instead, and then
it must publish the bound, because two encoders that disagree about it disagree
about bytes; this port has no bound to publish.

Held-back ids are encoder state, never buffer content, so a pending run cannot
straddle a flush — a run costs no buffer space, and the buffer only fills
through a write, which commits the run before its first byte. Output is
therefore buffer-size independent: a tiny output buffer produces exactly the
one-shot bytes.

### Serialize stream

Attach a flush callback with `OStream.initFlush`. When the scratch buffer
fills, its bytes drain to the callback and writing resumes at the start;
`flush()` pushes the tail — so the message can far exceed the buffer:

```zig
const Sink = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn push(ctx: ?*anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.list.appendSlice(self.gpa, chunk) catch @panic("oom");
    }
};

var out: Sink = .{ .gpa = gpa }; // or a socket / file writer
var scratch: [16]u8 = undefined;
var os = sofab.OStream.initFlush(&scratch, 0, &out, Sink.push);
for (0..1000) |i| try os.writeUnsigned(@intCast(i), i);
_ = os.flush(); // push the tail
```

The scratch buffer may be as small as **`sofab.MIN_OUTPUT_BUFFER` (1 byte)** —
this encoder splits every atomic unit across a flush, so any non-empty buffer
streams a message of any size and the bytes are identical to the one-shot path.
That minimum binds a buffer installed **with** a sink, and only such a buffer;
see [Memory handling](#memory-handling) for what happens to one below it.

### Deserialize

Decoding is **push-based**: pass a pointer to any struct implementing the
callbacks you care about, and the decoder calls one method per field. Missing
methods are comptime no-ops, so unhandled fields are skipped automatically.
`decode` runs the zero-copy fast path over a complete message:

```zig
const My = struct {
    a: u64 = 0,
    b: i64 = 0,
    s: [16]u8 = undefined,
    s_len: usize = 0,

    pub fn unsigned(self: *@This(), id: sofab.Id, v: u64) void {
        if (id == 1) self.a = v;
    }
    pub fn signed(self: *@This(), id: sofab.Id, v: i64) void {
        if (id == 2) self.b = v;
    }
    pub fn string(self: *@This(), id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        _ = total;
        if (id == 3) {
            @memcpy(self.s[offset..][0..chunk.len], chunk);
            self.s_len = offset + chunk.len;
        }
    }
    // blob, fp32, fp64, arrayBegin, sequenceBegin, sequenceEnd … as needed
};

var sink: My = .{};
_ = try sofab.decode(message, &sink); // .complete at a clean message boundary
// sink.a == 42, sink.b == -7, sink.s[0..sink.s_len] == "hi"
```

**Nested scopes: declaring `sequenceBegin` is what opts you in.** Every sequence
opens a **fresh id namespace** — a child's `id 1` is unrelated to the enclosing
scope's `id 1` — so a visitor that declares no `sequenceBegin` is never told a
scope was entered and could not tell the two apart. For such a visitor the
decoder therefore consumes and discards the **entire sub-sequence**, children and
the matching `sequenceEnd` alike (CORELIB_PLAN §5.2/§6), and the visitor sees the
message's top-level fields only. Declare `sequenceBegin` (as generated code
always does) and you get every nested field instead, with the scope bookkeeping
yours to do. Either way the skipped bytes are still fully parsed: `MAX_DEPTH`,
every malformed-input verdict and the resync onto the field after the scope are
unaffected, and the outcome does not depend on where the chunk boundaries fall.

### Deserialize stream

`IStream.feed` takes chunks of any size, suspends/resumes at any byte boundary,
and drives the same visitor — so it decodes whatever the transport hands you.
`feed` returns the message-boundary `Status` after each chunk (`status()`
re-queries it without feeding more): `.complete` at a clean field boundary and
`.incomplete` when the bytes ended inside a field or with a sequence still open.
There is **no** `finish()`/`finalize()` call — the outcome comes straight out of
`feed(chunk)→status`. Truncation is **not** an error the decoder invents — the
caller owns end-of-input and decides, from its own framing, whether a trailing
`.incomplete` is a truncation failure (MESSAGE_SPEC §7). Malformed bytes are
still rejected as `error.InvalidMessage` by `feed` itself.

```zig
var sink: My = .{};
var is = sofab.IStream.init();
var status = sofab.Status.complete;
while (transport.nextChunk()) |chunk| { // 7 bytes at a time, or 1, or 64k
    status = try is.feed(chunk, &sink); // error.InvalidMessage on malformed input
}
switch (status) { // == is.status()
    .complete => {},
    .incomplete => {}, // stream ended mid-message: your framing decides
    .invalid => {},    // unreachable after a `try` — see below
}
```

**A rejection is terminal.** `error.InvalidMessage` means the consumed bytes are
malformed *regardless of what follows* (CORELIB_PLAN §5.2), so the decoder
latches that verdict instead of resynchronizing on whatever comes after the
malformed construct: every further `feed` — a whole valid message, a truncated
prefix and an empty end-of-input probe alike — returns `error.InvalidMessage`
again, and `status()` reports the third `Status`, `.invalid`. That is the only
way `.invalid` is ever observed, since `feed`/`decode` surface the outcome as the
error itself. Without the latch the verdict would depend on where the chunk
boundaries happened to fall — the same bytes must decode to the same outcome fed
whole or one byte at a time (MESSAGE_SPEC §7.2). `is.reset()` clears the latch —
it is the only way out — and readies the decoder for the next message.

The error set also carries `error.LimitExceeded`, for a **receiver-configured**
decode limit on an unbounded field (`max_dyn_array_count`, `max_dyn_string_len`,
`max_dyn_blob_len`). This corelib never raises it and defines no default limits —
the caps come from the sofabgen config and are enforced in generated decode code,
which raises this category before allocating. It is deliberately distinct from
`error.InvalidMessage`: exceeding a receiver limit is policy, not wire
malformation (see [`generator#102`](https://github.com/sofa-buffers/generator/issues/102)).

### UTF-8 validation (`SOFAB_STRICT_UTF8`)

A `string` payload is UTF-8; `blob` is opaque bytes and is never validated. Strict
UTF-8 validation is gated by the compile-time build option `strict_utf8`
(`SOFAB_STRICT_UTF8`, CORELIB_PLAN §6.4), **on by default**:

```bash
zig build test                       # strict on (default)
zig build test -Dstrict_utf8=false   # non-strict build (validation compiled out)
```

Zig is a **byte-container** target (a string is `[]const u8`), so the corelib
exposes the primitive `sofab.utf8_valid(bytes: []const u8) bool`. Generated
decode code calls it **unconditionally** on every materialized `string`; the gate
lives inside the primitive, so flipping the flag never regenerates code and
generated code is identical across build configurations. On the encode side,
`OStream.writeString` refuses a non-UTF-8 value with `error.InvalidArgument` under
strict — and so does the generic `OStream.writeFixlen(id, data, .string)`, which
is where the check lives, so every path that can put a `string`-subtype field on
the wire is covered (`blob` and the float subtypes are never validated).
`sofab.STRICT_UTF8` reflects the compiled state. When the option is off,
`utf8_valid` folds to `true` (zero cost, no validator compiled in) and both
writers emit bytes verbatim — never silent/lossy. Skipped fields are
never validated. The validator is a real one (rejects overlong forms including
`C0 80`, surrogates, and code points above `U+10FFFF`; accepts embedded `U+0000`).

### Code generator

Usually you never touch the raw API: the
[`generator`](https://github.com/sofa-buffers/generator) turns a schema into
typed structs whose surface is the closed name set of CORELIB_PLAN §6.1.1 — the
one-shot `encode()` / `decode()` pair users reach for, and the streaming
`serialize()` / `deserialize` pair that talks to this corelib (`deserialize`
being, in Zig, the generated visitor the decoder calls). The one-shot helpers
are thin wrappers over the streaming path, not a second implementation of it,
and there is no second spelling for either — the words are fixed, only the
casing follows the language.

`sofabgen --lang zig` over a two-field schema

```yaml
messages:
  point:
    summary: A 2D point.
    payload:
      x: { id: 1, type: i32 }
      y: { id: 2, type: i32 }
```

emits this — doc comments shortened, and the array/string/nested-sequence
machinery this schema does not use left out:

```zig
// Code generated by sofabgen; DO NOT EDIT.
const std = @import("std");
const sofab = @import("sofab");

/// The corelib baseline plus IncompleteMessage: for a one-shot decode over a
/// whole buffer, a trailing .incomplete means the message was truncated.
pub const DecodeError = sofab.Error || error{IncompleteMessage};

/// A 2D point.
pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    /// Worst-case encoded size of this message, derived from the schema.
    pub const MAX_SIZE: usize = 12;

    /// Streaming out: write this value's fields into any OStream.
    pub fn serialize(self: *const Point, os: *sofab.OStream) sofab.Error!void {
        if (self.x != 0) try os.writeSigned(1, self.x);
        if (self.y != 0) try os.writeSigned(2, self.y);
    }

    /// One-shot: `serialize` into a scratch buffer drained by a growing sink.
    pub fn encode(self: *const Point, alloc: std.mem.Allocator) (sofab.Error || std.mem.Allocator.Error)![]u8 {
        var sink: _EncodeSink = .{ .alloc = alloc };
        var scratch: [512]u8 = undefined;
        var os = sofab.OStream.initFlush(&scratch, 0, &sink, _EncodeSink.push);
        try self.serialize(&os);
        _ = os.flush();
        if (sink.failed) return error.OutOfMemory;
        return sink.list.toOwnedSlice(alloc);
    }

    /// One-shot: the generated visitor driven over one whole buffer. Zero-copy —
    /// string/blob fields would borrow from `data`; truncated input fails with
    /// error.IncompleteMessage, malformed input with error.InvalidMessage.
    pub fn decode(alloc: std.mem.Allocator, data: []const u8) DecodeError!Point {
        var m: Point = .{};
        var v: _dec_Point = .{ .m = &m, .alloc = alloc };
        const st = try sofab.decode(data, &v);
        if (v.inv) return error.InvalidMessage;
        if (st == .incomplete) return error.IncompleteMessage;
        return m;
    }

    /// Incremental decoder: hold one and feed the message as bytes arrive.
    /// Unlike decode(), this path COPIES every string and blob into `alloc`.
    pub const Decoder = struct {
        is: sofab.IStream = sofab.IStream.init(),
        v: _dec_Point,

        /// Feed the next chunk, of any size. `.complete` means the bytes ended
        /// on a field boundary, `.incomplete` mid-field — neither answers
        /// whether the MESSAGE is done.
        pub fn feed(self: *Decoder, chunk: []const u8) DecodeError!sofab.Status {
            const st = try self.is.feed(chunk, &self.v);
            if (self.v.inv) return error.InvalidMessage;
            return st;
        }

        /// The outcome for everything fed so far, without feeding more.
        pub fn status(self: *const Decoder) sofab.Status {
            return self.is.status();
        }

        /// Declare end-of-input: a stream that ended mid-field fails here.
        pub fn finish(self: *const Decoder) DecodeError!void {
            if (self.is.status() == .incomplete) return error.IncompleteMessage;
        }
    };

    /// Streaming in: an incremental decoder filling `out`.
    pub fn decoder(out: *Point, alloc: std.mem.Allocator) Decoder {
        return .{ .v = .{ .m = out, .alloc = alloc, .own = true } };
    }
};

/// The `deserialize` half of §6.1.1: the per-field hook the corelib's decoder
/// calls.
const _dec_Point = struct {
    m: *Point,
    alloc: std.mem.Allocator,
    own: bool = false, // copy payloads instead of borrowing (streaming path)
    inv: bool = false, // a value outside its schema bound -> INVALID

    pub fn signed(self: *_dec_Point, id: sofab.Id, value: sofab.Signed) void {
        switch (id) {
            1 => {
                if (value < -2147483648 or value > 2147483647) {
                    self.inv = true;
                    return;
                }
                self.m.x = @intCast(value);
            },
            2 => {
                if (value < -2147483648 or value > 2147483647) {
                    self.inv = true;
                    return;
                }
                self.m.y = @intCast(value);
            },
            else => {},
        }
    }
};

/// Flush sink behind encode(): drains the OStream scratch into a byte list.
const _EncodeSink = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    failed: bool = false,
    fn push(ctx: ?*anyopaque, data: []const u8) void {
        const self: *_EncodeSink = @ptrCast(@alignCast(ctx.?));
        self.list.appendSlice(self.alloc, data) catch {
            self.failed = true;
        };
    }
};
```

Both paths, on that generated type — the convenience pair first, then the
streaming pair the corelib actually talks to:

```zig
// The generated layer allocates; the corelib still does not. An arena
// frees the whole message at once.
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const alloc = arena.allocator();

// --- one-shot: encode()/decode(), thin wrappers over the streaming pair ---
const wire = try (Point{ .x = 3, .y = 4 }).encode(alloc);
const got = try Point.decode(alloc, wire); // got.x == 3, got.y == 4

// --- streaming out: an output buffer smaller than the message + a sink ---
const Sink = struct {
    buf: [Point.MAX_SIZE]u8 = undefined,
    len: usize = 0,
    fn push(ctx: ?*anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }
};
var sink: Sink = .{};
var scratch: [4]u8 = undefined; // well under MAX_SIZE: the sink drains it
var os = sofab.OStream.initFlush(&scratch, 0, &sink, Sink.push);
try (Point{ .x = 3, .y = 4 }).serialize(&os);
_ = os.flush(); // sink.buf[0..sink.len] is the same message

// --- streaming in: feed the message in chunks of any size ---------------
var out: Point = .{};
var dec = Point.decoder(&out, alloc);
var st = try dec.feed(wire[0..1]); // .incomplete — ended mid-field
st = try dec.feed(wire[1..]); // .complete — ended on a field boundary
try dec.finish(); // end-of-input: a trailing .incomplete fails here
```

`feed` never says the *message* is done — only that the bytes handed in ended on
a field boundary or mid-field — so `finish()` is where the generated layer turns
a trailing `.incomplete` into `error.IncompleteMessage`. Both blocks are
compiled and run by the test suite (`tests/readme_generated_example.zig`), and
`tests/readme_tests.zig` fails the build if this section drifts from them.

## Memory handling

You own every buffer. The codec is allocation-free and holds no heap memory —
`OStream`, `IStream` and `decode` neither take nor keep an allocator.

- **Encode (`OStream`):** you own the output `[]u8`; the library never allocates
  or grows it. With no flush sink, overflow is `error.BufferFull`; with a flush
  callback the buffer drains and is reused (`bufferSet` swaps in a fresh one),
  and `initOffset` reserves leading framing space. Each write copies its bytes
  into the buffer, so caller source strings/slices may be reused immediately.
  A sink is never handed memory other than the output buffer — this port does
  not pass `string`/`blob` payloads through.
  **`sofab.MIN_OUTPUT_BUFFER` is `1`:** the smallest buffer accepted **for
  streaming**, i.e. one installed together with a flush sink, which must offer
  at least that many usable bytes (`buffer.len - offset`). A buffer installed
  **without** a sink is subject to no minimum — no flush can occur, so it either
  holds the message or reports `error.BufferFull`, and a two-byte message
  encodes into a two-byte buffer. Every installation is judged where the buffer
  is handed over — `initOffset`, `initFlush`, `bufferSet` — never partway
  through a message: an offset past the end of the buffer, or less than
  `MIN_OUTPUT_BUFFER` behind a sink, is refused there and leaves the stream
  inert, writing nothing and reporting `error.InvalidArgument` from every write.
  `initOffsetChecked` / `initFlushChecked` / `bufferSetChecked` are the same
  installations reported as an error status up front, for a buffer or offset
  computed at runtime.
  **What the flush callback does before it returns decides where the encoder
  goes on writing.** A sink may *copy* the bytes it was handed or *take* the
  buffer — hand it to a transport, queue it for an asynchronous write — and the
  encoder cannot tell the two apart, so the callback states which it is:
  returning **without** installing a buffer means it copied, and the active
  buffer stays active with the cursor back at **0**; a sink that **takes** the
  buffer must `bufferSet` a replacement before returning. The start offset
  belongs to that installation, not to the buffer, so the encoder resumes at
  *that call's* offset — `os.bufferSet(fresh, 4)` re-arms four bytes of header
  room in the next flushed unit. Installing the **same** buffer is a new
  installation like any other: that is how a sink gets fresh framing room in
  **every** unit, one header per packet, where a bare return would give it only
  in the first. The offset is consumed by the installation, so a later bare
  return resumes at 0 again. A replacement refused inside a callback leaves the
  stream inert like any other refusal, and the write that triggered the flush
  reports `error.InvalidArgument` instead of storing into it.
  The struct itself is 1080 bytes on a 64-bit target: it reserves the full
  `MAX_DEPTH` lazy sequence hold-back run inline (see
  [Serialize](#serialize)), which is what buys canonical framing at every depth
  without an allocator. Put it wherever you would put a 1 KiB local.
- **Decode (`decode` / `IStream` + visitor):** you own the input buffer and it
  must outlive the `decode`/`feed` call. A `string`/`blob` chunk is a borrowed
  slice; where it borrows from — and therefore how long it stays valid — depends
  on the path. Scalars and floats always arrive by value.
  - **`decode` (whole message in one buffer):** every delivered slice points
    directly into the caller's input buffer, and is **valid for that buffer's
    lifetime** — you may retain it as long as you keep the input buffer alive,
    not merely for the duration of the callback. This is the guarantee the
    zero-copy decode rests on: a decoded value can hold a `[]const u8` view into
    your buffer with no copy.
  - **`feed` (streaming, chunk by chunk):** a delivered slice is **valid only
    during that callback** — copy it out to keep it. It usually points into the
    chunk you just fed, but a payload that straddled a chunk boundary is
    stitched together in `IStream`'s internal carry buffer and delivered as a
    slice into *that*, which the next stitched item overwrites. Do not assume a
    `feed`-delivered slice lives in your own chunk.

| Buffer | Owner / lifetime |
|--------|------------------|
| **Output buffer** | Caller-owned `[]u8`; library never allocates or grows it (no sink → `error.BufferFull`). With a sink it must offer at least `MIN_OUTPUT_BUFFER` = 1 usable byte, checked at every installation; without one, no minimum applies. |
| **Input buffer (`decode`)** | Caller-owned; must outlive the call. Delivered string/blob slices borrow from it and stay valid for its whole lifetime — retainable, not callback-scoped. |
| **Input chunk (`feed`)** | Caller-owned; must outlive the call. Delivered string/blob slices are valid only during the callback; a carry-completed payload borrows from `IStream`, not from your chunk. |

This is a **push / visitor** model, so there is no address-stability requirement
on decoded values. The only memory the decoder owns is `IStream`'s fixed 64-byte
carry buffer — the few bytes of an item that straddled a chunk boundary.

## Feature flags

The wire format is always fully supported — there are no toggles for wire types.
The one build option is the strict UTF-8 validation policy:

| Build option | Default | Effect |
|--------------|---------|--------|
| `-Dstrict_utf8=<bool>` (`SOFAB_STRICT_UTF8`) | `true` (on) | Strict UTF-8 validation of `string` fields — see [UTF-8 validation](#utf-8-validation-sofab_strict_utf8). Off compiles the validator out (zero cost) and stores/writes bytes verbatim. A validation policy only, never a wire-format switch. |

## Build & test

```bash
zig build --release=fast         # static library in the shipping config (ReleaseFast)
zig build test                   # unit + conformance tests (incl. shared vectors)
zig build test --release=fast    # the same suite in the shipping config
./coverage.sh                    # line coverage via kcov (HTML + percentage)
```

CI runs `zig fmt --check`, the full suite in Debug and ReleaseFast, the same
suite on a **big-endian** s390x host under QEMU, and the kcov coverage job.
Conformance tests live in `tests/` (shared-vector replay, chunked encode/decode,
roundtrip, malformed-input, cross-chunk UTF-8 and skip scenarios); unit tests
live next to the code in `src/`.

## Benchmarks

Three tools mirror the other ports' `perf`, `bench` and `run_callgrind.sh`
tooling — same workloads (a 1000-element `u64` array and a mixed message) and
output format per [`BENCH_SPEC.md`](https://github.com/sofa-buffers/documentation/blob/main/BENCH_SPEC.md),
so results are comparable across languages:

```bash
zig build perf                   # cycles/op + CPU ns/op + throughput per op
zig build bench                  # practical MB/s (encode + decode)
zig build bench -Dcpu=native     # last few percent
bash bench/run_callgrind.sh      # instructions/op (Callgrind Ir/op)
```

`perf` reports the CPU-independent per-op cost (hardware cycle counter);
`bench` reports throughput in MB/s on the current machine, both measured over a
~1 s process-CPU-time loop.

`bench/run_callgrind.sh` reports **instructions retired per op** (`Ir/op`) under
Callgrind — deterministic and independent of clock speed and scheduler, so the
numbers compare across machines and against the sibling ports, and unlike
`perf`'s cycle counter the measurement is available on every target. It needs
`valgrind` installed — the devcontainer image ships it — and builds its tool
(`zig build callgrind`) itself;
collection is toggled on that tool's `run_<workload>` symbol, so each printed
number is one operation's cost directly, with no rep-count subtraction. It is
measurement tooling for reporting, not part of the test suite or CI.
