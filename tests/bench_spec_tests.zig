//! The benchmark suite held against BENCH_SPEC (CORELIB_PLAN §10, §13).
//!
//! BENCH_SPEC's value is that the same workloads, on the same data, are
//! measured the same way in every port — so a row that is missing here, or that
//! encodes different bytes from the other ports', silently drops out of the
//! comparison tables (or, worse, stays in them and lies). Neither failure is
//! visible from a benchmark run: the tool prints a table either way.
//!
//! These tests read the shipped workload table, run every workload once, and
//! hold the result against the spec:
//!
//! * the table covers **exactly** the rows the output grammar defines, in the
//!   order the grammar prints them (the optional `blob 1MB passthrough` row
//!   aside — this port grants no pass-through permission, so it omits it);
//! * every workload runs end to end and reports a real encoded size, including
//!   the two parity checks the spec states outright — `blob 1MB` is 1,000,005
//!   bytes and `composite` is 956 on every port;
//! * the `composite` message really has the shape the dataset describes: a
//!   wrapper array whose element ids straddle the one-byte header boundary, a
//!   non-ASCII string, nesting at depth 3, an omitted all-default field and a
//!   two-byte field header;
//! * the streaming `blob 1MB` row encodes the *same bytes* as the one-shot row
//!   it is read against — a divisible-run path that dropped or duplicated a
//!   byte would still print a plausible MB/s figure.

const std = @import("std");
const sofab = @import("sofab");
const w = @import("bench_workloads");

/// The rows BENCH_SPEC's output grammar defines, in the order it prints them.
/// `blob 1MB passthrough` is the one optional row and is deliberately absent:
/// this port implements no pass-through permission, and the spec requires such
/// a port to omit the row rather than print a placeholder.
const required_rows = [_][]const u8{
    "encode: u64 array (1000)",
    "encode: typical message",
    "encode: blob 1MB one-shot",
    "encode: blob 1MB streaming",
    "encode: composite",
    "decode: u64 array (1000)",
    "decode: typical message",
    "decode: blob 1MB",
    "decode: composite",
    "decode: composite skip-all",
};

test "the workload table is exactly BENCH_SPEC's rows, in the grammar's order" {
    try std.testing.expectEqual(required_rows.len, w.workloads.len);
    for (required_rows, w.workloads) |want, got| {
        try std.testing.expectEqualStrings(want, got.label);
    }
}

test "every workload runs end to end and reports a real encoded size" {
    w.prepare();
    for (w.workloads) |wl| {
        if (wl.setup) |setup| std.mem.doNotOptimizeAway(setup());
        std.mem.doNotOptimizeAway(wl.run());
        if (wl.bytes.* == 0) {
            std.debug.print("workload `{s}` reported 0 bytes\n", .{wl.name});
            return error.WorkloadProducedNothing;
        }
    }

    // The parity checks BENCH_SPEC states outright: a port whose figures differ
    // here is encoding something else than the rest of the family.
    try std.testing.expectEqual(@as(usize, w.BLOB_LEN + 5), w.blob_used);
    try std.testing.expectEqual(@as(usize, w.BLOB_LEN + 5), w.blob_stream_used);
    try std.testing.expectEqual(@as(usize, 956), w.comp_used);
}

test "the streaming blob row encodes the same bytes as the one-shot row" {
    w.prepare();
    std.mem.doNotOptimizeAway(w.encodeBlobOneshot());
    const one_shot = w.blobMessage();

    // The workload's own sink discards (BENCH_SPEC: it must not accumulate);
    // this one keeps the bytes so the two encodings can be compared. Same
    // 4096-byte buffer, same absence of a pass-through permission.
    const Collect = struct {
        var out: [w.BLOB_LEN + 16]u8 = undefined;
        var len: usize = 0;
        fn sink(_: ?*anyopaque, data: []const u8) void {
            @memcpy(out[len..][0..data.len], data);
            len += data.len;
        }
    };
    Collect.len = 0;
    var scratch: [w.BLOB_CHUNK]u8 = undefined;
    var os = sofab.OStream.initFlush(&scratch, 0, null, Collect.sink);
    try os.writeBlob(1, w.blobPayload());
    _ = os.flush();

    try std.testing.expectEqual(one_shot.len, Collect.len);
    try std.testing.expectEqualSlices(u8, one_shot, Collect.out[0..Collect.len]);
}

test "the blob decode row consumes the whole message in 4096-byte chunks" {
    w.prepare();
    std.mem.doNotOptimizeAway(w.encodeBlobOneshot());
    const msg = w.blobMessage();

    // What the workload does, with the payload checked rather than folded away:
    // every chunk but the last ends inside the payload, so all but the last
    // feed reports INCOMPLETE and the field is delivered across them.
    const Check = struct {
        seen: usize = 0,
        xor: u8 = 0,
        pub fn blob(self: *@This(), _: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
            if (offset == self.seen and total == w.BLOB_LEN) self.seen += chunk.len;
            for (chunk) |b| self.xor ^= b;
        }
    };
    var check: Check = .{};
    var is = sofab.IStream.init();
    var off: usize = 0;
    var status: sofab.Status = .incomplete;
    while (off < msg.len) : (off += w.BLOB_CHUNK) {
        const n = @min(w.BLOB_CHUNK, msg.len - off);
        status = try is.feed(msg[off..][0..n], &check);
    }
    try std.testing.expectEqual(sofab.Status.complete, status);
    try std.testing.expectEqual(@as(usize, w.BLOB_LEN), check.seen);

    var want: u8 = 0;
    for (w.blobPayload()) |b| want ^= b;
    try std.testing.expectEqual(want, check.xor);
}

/// Walks the `composite` message and records the facts the dataset exists to
/// exercise (BENCH_SPEC, "`composite` message").
const CompositeShape = struct {
    depth: u32 = 0,
    /// Ids seen at the top level, in order.
    top_ids: std.ArrayList(sofab.Id) = .empty,
    /// Element ids of the wrapper array at id 1.
    elements: std.ArrayList(sofab.Id) = .empty,
    alloc: std.mem.Allocator,
    /// Byte length of the string at id 2.
    text_len: usize = 0,
    /// Longest sequence nesting reached.
    max_depth: u32 = 0,
    /// The value at id 3 → 1 → 1 → 1, and the id-130 field.
    deep: u64 = 0,
    big: u64 = 0,
    /// Total bytes of the wrapper array's element payloads.
    element_bytes: usize = 0,

    pub fn unsigned(self: *CompositeShape, id: sofab.Id, v: u64) void {
        if (self.depth == 0) self.top_ids.append(self.alloc, id) catch unreachable;
        if (self.depth == 0 and id == 130) self.big = v;
        if (self.depth == 3 and id == 1) self.deep = v;
    }
    pub fn signed(_: *CompositeShape, _: sofab.Id, _: i64) void {}
    pub fn string(self: *CompositeShape, id: sofab.Id, _: usize, offset: usize, chunk: []const u8) void {
        if (self.depth == 0) {
            if (offset == 0) self.top_ids.append(self.alloc, id) catch unreachable;
            self.text_len += chunk.len;
        }
        if (self.depth == 1) {
            self.elements.append(self.alloc, id) catch unreachable;
            self.element_bytes += chunk.len;
        }
    }
    pub fn sequenceBegin(self: *CompositeShape, id: sofab.Id) void {
        if (self.depth == 0) self.top_ids.append(self.alloc, id) catch unreachable;
        self.depth += 1;
        self.max_depth = @max(self.max_depth, self.depth);
    }
    pub fn sequenceEnd(self: *CompositeShape) void {
        self.depth -= 1;
    }
};

test "the composite message has the shape BENCH_SPEC's dataset describes" {
    w.prepare();
    std.mem.doNotOptimizeAway(w.encodeComposite());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var shape: CompositeShape = .{ .alloc = arena.allocator() };
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(w.compositeMessage(), &shape));

    // Field 4 equals its declared default, so the encoder must not write it:
    // the top-level ids are 1, 2, 3 and 130 — never 4.
    try std.testing.expectEqualSlices(sofab.Id, &.{ 1, 2, 3, 130 }, shape.top_ids.items);

    // Field 1: the suite's only wrapper array — one header per element, element
    // id = array index, ids 0..63 so the header width changes partway through.
    try std.testing.expectEqual(@as(usize, 64), shape.elements.items.len);
    for (shape.elements.items, 0..) |id, i| try std.testing.expectEqual(@as(sofab.Id, @intCast(i)), id);
    // "item-0".."item-9" are 6 bytes, "item-10".."item-63" are 7.
    try std.testing.expectEqual(@as(usize, 10 * 6 + 54 * 7), shape.element_bytes);

    // Field 2: 32 cycles of a 1-/2-/3-/4-byte UTF-8 run = 320 bytes.
    try std.testing.expectEqual(@as(usize, 320), shape.text_len);

    // Field 3: nesting at depth 3, innermost value 7. Field 130: the suite's
    // only two-byte field header.
    try std.testing.expectEqual(@as(u32, 3), shape.max_depth);
    try std.testing.expectEqual(@as(u64, 7), shape.deep);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF), shape.big);
}

test "skipping the composite message consumes exactly the same bytes" {
    w.prepare();
    std.mem.doNotOptimizeAway(w.encodeComposite());

    // The skip-all row's visitor: it declares nothing, so every field is
    // skipped by its metadata and every sub-sequence is consumed whole. The
    // verdict must still be COMPLETE — skipping is not a shortcut around the
    // parse (MESSAGE_SPEC §7.3).
    const Nothing = struct {};
    var nothing: Nothing = .{};
    try std.testing.expectEqual(
        sofab.Status.complete,
        try sofab.decode(w.compositeMessage(), &nothing),
    );
}
