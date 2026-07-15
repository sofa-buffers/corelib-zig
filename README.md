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
typing (monomorphized, no vtable), and the entire library — encoder *and*
decoder — is **allocation-free**: caller-owned buffers on both sides, a fixed
carry buffer inside the streaming decoder, no allocator anywhere. It is
wire-compatible, byte-for-byte, with every other `corelib-*` port.

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
| Zero unnecessary copies | `decode` parses straight from the input buffer, handing string/blob fields back as borrowed slices; `feed` copies only the few bytes of a small item that straddles a chunk boundary. |
| No allocation | The whole library is allocator-free — not just the hot path. Encoder state is a struct over your buffer; the decoder's only memory is a fixed 64-byte carry buffer. |
| Raw speed | Unchecked pointer-advancing varint encode *and* decode once bounds are guaranteed, bulk `@memcpy`/native little-endian float loads, comptime-monomorphized visitor dispatch, `@branchHint(.cold)` on the drain path, ReleaseFast shipping profile. |
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
}
```

The error set also carries `error.LimitExceeded`, for a **receiver-configured**
decode limit on an unbounded field (`max_dyn_array_count`, `max_dyn_string_len`,
`max_dyn_blob_len`). This corelib never raises it and defines no default limits —
the caps come from the sofabgen config and are enforced in generated decode code,
which raises this category before allocating. It is deliberately distinct from
`error.InvalidMessage`: exceeding a receiver limit is policy, not wire
malformation (see [`generator#102`](https://github.com/sofa-buffers/generator/issues/102)).

### Code generator

Usually you never touch the raw API: the
[`generator`](https://github.com/sofa-buffers/generator) turns a schema into
typed structs with `encode()` / `decode()` (over `marshal` / a visitor). A
hand-written stand-in, encoded then decoded:

```zig
// generated by: sofabgen --lang zig
const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    const max_size = 32;

    fn marshal(self: *const Point, os: *sofab.OStream) void {
        os.writeSigned(1, self.x) catch unreachable;
        os.writeSigned(2, self.y) catch unreachable;
    }

    fn encode(self: *const Point, buf: *[max_size]u8) []const u8 {
        var os = sofab.OStream.init(buf);
        self.marshal(&os);
        return buf[0..os.bytesUsed()];
    }

    fn decode(data: []const u8) !Point {
        var p: Point = .{};
        _ = try sofab.decode(data, &p);
        return p;
    }

    pub fn signed(self: *Point, id: sofab.Id, v: i64) void {
        switch (id) {
            1 => self.x = @intCast(v),
            2 => self.y = @intCast(v),
            else => {},
        }
    }
};

var wire_buf: [Point.max_size]u8 = undefined;
const wire = (Point{ .x = 3, .y = 4 }).encode(&wire_buf);
const got = try Point.decode(wire); // got.x == 3, got.y == 4
```

## Memory handling

You own every buffer. The hot path is allocation-free and there is no
library-owned heap memory anywhere — no allocator is passed in or held.

- **Encode (`OStream`):** you own the output `[]u8`; the library never allocates
  or grows it. With no flush sink, overflow is `error.BufferFull`; with a flush
  callback the buffer drains and is reused (`bufferSet` swaps in a fresh one),
  and `initOffset` reserves leading framing space. Each write copies its bytes
  into the buffer, so caller source strings/slices may be reused immediately.
- **Decode (`decode` / `IStream` + visitor):** you own the input buffer and it
  must outlive the `decode`/`feed` call. `string`/`blob` chunks are borrowed
  slices that point directly into that buffer, valid only during the callback —
  copy them out to keep them. Scalars and floats arrive by value.

| Buffer | Owner / lifetime |
|--------|------------------|
| **Output buffer** | Caller-owned `[]u8`; library never allocates or grows it (no sink → `error.BufferFull`). |
| **Input buffer** | Caller-owned; must outlive the call; string/blob slices borrow from it during the callback. |

This is a **push / visitor** model, so there is no address-stability requirement
on decoded values. The only memory the decoder owns is `IStream`'s fixed 64-byte
carry buffer — the few bytes of an item that straddled a chunk boundary.

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
roundtrip, malformed-input and skip scenarios); unit tests live next to the code
in `src/`.

## Benchmarks

Two build steps mirror the other ports' `perf` and `bench` tooling — same
workloads (a 1000-element `u64` array and a mixed message) and output format
per [`BENCH_SPEC.md`](https://github.com/sofa-buffers/documentation/blob/main/BENCH_SPEC.md),
so results are comparable across languages:

```bash
zig build perf                   # cycles/op + CPU ns/op + throughput per op
zig build bench                  # practical MB/s (encode + decode)
zig build bench -Dcpu=native     # last few percent
```

`perf` reports the CPU-independent per-op cost (hardware cycle counter);
`bench` reports throughput in MB/s on the current machine, both measured over a
~1 s process-CPU-time loop.
