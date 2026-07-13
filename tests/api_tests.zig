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
    // INCOMPLETE is a distinct outcome (MESSAGE_SPEC §7), not folded into
    // InvalidMessage.
    try std.testing.expectError(E.Incomplete, @as(E!void, E.Incomplete));
}
