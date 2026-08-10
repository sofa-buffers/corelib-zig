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
