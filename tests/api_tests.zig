//! API-contract checks (ARCHITECTURE §6): version constant, limits, and the
//! error baseline.

const std = @import("std");
const sofab = @import("sofab");

test "API version is 1" {
    try std.testing.expectEqual(@as(u32, 1), sofab.API_VERSION);
}

test "normative limits (§6.2)" {
    try std.testing.expectEqual(@as(sofab.Id, 2_147_483_647), sofab.ID_MAX);
    try std.testing.expectEqual(@as(u32, 255), sofab.MAX_DEPTH);
    try std.testing.expectEqual(u64, sofab.Unsigned);
    try std.testing.expectEqual(i64, sofab.Signed);
}

test "MIN_OUTPUT_BUFFER is declared and within the §5.1 ceiling" {
    // The smallest buffer this port accepts for streaming has to be a number a
    // caller can read off the API before sizing its buffer, and §5.1 caps any
    // declaration at 20 — a header varint plus its value, which is also the
    // smallest message a schema can bound.
    try std.testing.expectEqual(usize, @TypeOf(sofab.MIN_OUTPUT_BUFFER));
    try std.testing.expect(sofab.MIN_OUTPUT_BUFFER >= 1);
    try std.testing.expect(sofab.MIN_OUTPUT_BUFFER <= 20);
    // This port splits atomic units across a flush, so it declares the floor.
    try std.testing.expectEqual(@as(usize, 1), sofab.MIN_OUTPUT_BUFFER);
}

test "the minimum binds a sink-backed installation and no other (§5.1)" {
    const Sink = struct {
        fn push(ctx: ?*anyopaque, chunk: []const u8) void {
            _ = ctx;
            _ = chunk;
        }
    };
    var buf: [8]u8 = @splat(0xEE);

    // One byte short of the minimum behind a sink: refused where the buffer is
    // handed over, not partway through a message, and nothing is written.
    try std.testing.expectError(
        sofab.Error.InvalidArgument,
        sofab.OStream.initFlushChecked(&buf, buf.len, null, Sink.push),
    );
    var refused = sofab.OStream.initFlush(&buf, buf.len, null, Sink.push);
    try std.testing.expectError(sofab.Error.InvalidArgument, refused.writeUnsigned(1, 1));
    try std.testing.expectEqual(@as(usize, 0), refused.bytesUsed());
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xEE), b);

    // The converse: the same buffer without a sink is accepted, and a message
    // that fits encodes into it — the minimum is a streaming constant, never a
    // floor on the one-shot path.
    var small = sofab.OStream.init(buf[0..2]);
    try small.writeUnsigned(0, 127);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7F }, buf[0..small.bytesUsed()]);
}

test "error baseline (§6.3) is exposed" {
    // The canonical baseline codes must all be members of the error set.
    // UsageError is deliberately absent: it was declared and never returned, so
    // it left callers a branch that could not be reached (the C corelib removed
    // its SOFAB_RET_E_USAGE for the same reason). A caller error here is an
    // InvalidArgument.
    const E = sofab.Error;
    try std.testing.expectError(E.InvalidArgument, @as(E!void, E.InvalidArgument));
    try std.testing.expectError(E.BufferFull, @as(E!void, E.BufferFull));
    try std.testing.expectError(E.InvalidMessage, @as(E!void, E.InvalidMessage));
    // LIMIT_EXCEEDED is a distinct policy outcome (generator#102), exposed for
    // generated decode code to report a receiver-configured limit violation.
    try std.testing.expectError(E.LimitExceeded, @as(E!void, E.LimitExceeded));
}

test "INCOMPLETE is a distinct decode status, not an error (MESSAGE_SPEC §7)" {
    // The three-valued streaming outcome surfaces INCOMPLETE as a `Status`
    // value returned from `feed`/`status` — never promoted into the
    // `InvalidMessage` error channel, and never via a `finish()`/`finalize()`
    // call (the plan forbids one; §5, §6.1).
    try std.testing.expect(sofab.Status.incomplete != sofab.Status.complete);
}

test "LimitExceeded is distinguishable from InvalidMessage" {
    // A limit violation is receiver policy, not wire malformation — the two must
    // never collapse to the same value, or a differential fuzzer would read a
    // backend's configured limit as a wire-conformance divergence.
    const E = sofab.Error;
    try std.testing.expect(E.LimitExceeded != E.InvalidMessage);

    // A caller (e.g. generated decode code) can switch the two apart.
    const classify = struct {
        fn f(e: E) []const u8 {
            return switch (e) {
                E.LimitExceeded => "policy",
                E.InvalidMessage => "malformed",
                else => "other",
            };
        }
    }.f;
    try std.testing.expectEqualStrings("policy", classify(E.LimitExceeded));
    try std.testing.expectEqualStrings("malformed", classify(E.InvalidMessage));
}

test "sofab.arrays is the closed set of helpers generated code calls (§6.1)" {
    // §6.1 keeps the public surface a closed, traceable name set: every helper
    // here has an emitted call site in the Zig backend, and a helper the
    // generator never emits cannot be traced back to a spec rule.
    //
    // Three used to sit here with no caller at all. `put` was `putChecked` minus
    // the §7.1 over-count flag — the same store, silently clamping where the
    // spec says INVALID. `trimTail` cut the trailing run of default elements
    // off a `count: N` array, the pre-PR#29 reading of MESSAGE_SPEC §3; §3 now
    // says the opposite (see the test below), so keeping it published offered
    // an inverted rule as current guidance. `last` addressed the final element
    // of a decode-allocated slice, from a wrapper-array shape the backend
    // stopped emitting when it moved to placing an element at its wire id
    // (`setElem`/`grow`) instead of appending.
    //
    // `allocCapped` and `ARRAY_INIT_CAP` left with generator#396, which stopped
    // emitting them: a native array's count is now bounded before it is
    // allocated from, so the destination is `allocN(count)` and there is nothing
    // to cap the first allocation at. A helper with no emitted call site is
    // exactly what this closed set exists to keep out — and `ARRAY_INIT_CAP` was
    // besides "a limit the codec invented of its own", which §6.2.1 forbids.
    inline for (.{ "putGrowing", "putChecked", "grow", "allocN", "setElem" }) |name| {
        try std.testing.expect(@hasDecl(sofab.arrays, name));
    }
    inline for (.{ "put", "trimTail", "last", "allocCapped", "ARRAY_INIT_CAP" }) |name| {
        try std.testing.expect(!@hasDecl(sofab.arrays, name));
    }
}

test "the generated layer's support types are exported (ARCHITECTURE §8)" {
    // Schema-free types the generator used to emit a copy of into every module:
    // the capacity is a type parameter, the allocator and the payload length are
    // arguments.
    const alloc = std.testing.allocator;

    // A `count: 4` field holding two elements — a capacity is not a length.
    const levels: sofab.FixedArray(u32, 4) = .init(&.{ 10, 20 });
    try std.testing.expectEqual(@as(usize, 4), @TypeOf(levels).capacity);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, levels.slice());
    var buf: [16]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeArrayUnsigned(9, levels.slice());
    const direct = buf[0..os.bytesUsed()];

    // The same field through a scratch buffer far too small to hold it, drained
    // into a sink the CALLER allocates for (CORELIB_PLAN §5.1): byte-identical
    // to the one-shot output, as every streamed encode must be.
    var sink: sofab.CollectingSink = .{ .alloc = alloc };
    defer sink.deinit();
    var scratch: [2]u8 = undefined;
    var streamed = sofab.OStream.initFlush(&scratch, 0, &sink, sofab.CollectingSink.push);
    try streamed.writeArrayUnsigned(9, levels.slice());
    _ = streamed.flush();
    const message = try sink.toOwnedSlice();
    defer alloc.free(message);
    try std.testing.expectEqualSlices(u8, direct, message);

    // A payload split across two feed chunks, stitched into one allocation.
    var acc: sofab.PayloadAcc = .{};
    defer acc.deinit(alloc);
    try std.testing.expect(try acc.push(alloc, 5, 0, "so") == null);
    const payload = (try acc.push(alloc, 5, 2, "fab")).?;
    defer alloc.free(@constCast(payload));
    try std.testing.expectEqualStrings("sofab", payload);
}

test "a compact array is linear and gap-free: no trailing-default elision (MESSAGE_SPEC §3)" {
    // `M` is the array's LENGTH, so a trailing default element stays on the
    // wire: [1, 2, 0, 0] and [1, 2] are different values and must encode
    // differently. Trimming the trailing run would collapse them onto one
    // another. These are the bytes of the shared vector
    // `array_unsigned_trailing_defaults` (03 04 01 02 00 00).
    var buf: [16]u8 = undefined;
    var os = sofab.OStream.init(&buf);
    try os.writeArrayUnsigned(0, &[_]u32{ 1, 2, 0, 0 });
    const full = buf[0..os.bytesUsed()];
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x04, 0x01, 0x02, 0x00, 0x00 }, full);

    var buf2: [16]u8 = undefined;
    var os2 = sofab.OStream.init(&buf2);
    try os2.writeArrayUnsigned(0, &[_]u32{ 1, 2 });
    const trimmed = buf2[0..os2.bytesUsed()];
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x01, 0x02 }, trimmed);
    try std.testing.expect(!std.mem.eql(u8, full, trimmed));

    // And the decoder reports the length it was given, with no fill-to-N.
    const Sink = struct {
        count: usize = 0,
        pub fn arrayBegin(self: *@This(), id: sofab.Id, kind: sofab.ArrayKind, count: usize) void {
            _ = id;
            _ = kind;
            self.count = count;
        }
        pub fn unsigned(self: *@This(), id: sofab.Id, v: u64) void {
            _ = self;
            _ = id;
            _ = v;
        }
    };
    var sink: Sink = .{};
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(full, &sink));
    try std.testing.expectEqual(@as(usize, 4), sink.count);
}
