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

test "error baseline (§6.3) is exposed" {
    // The canonical baseline codes must all be members of the error set.
    const E = sofab.Error;
    try std.testing.expectError(E.InvalidArgument, @as(E!void, E.InvalidArgument));
    try std.testing.expectError(E.UsageError, @as(E!void, E.UsageError));
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
