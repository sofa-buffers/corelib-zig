//! Receiver caps at the decode surface (CORELIB_PLAN §6.2.1, §6.3).
//!
//! The unit tests in `src/arrays.zig` pin what the capped helpers do in
//! isolation. These pin the two properties that are only visible once a real
//! decode drives them, both of which §6.2.1 states as requirements on *where*
//! the check runs:
//!
//! 1. **At the count header, before the allocation it exists to prevent.** An
//!    over-cap array count is refused without an allocator call and without a
//!    single element landing — and it is refused, never clamped to `cap`.
//! 2. **Behind the MESSAGE_SPEC §7.3 tag test.** "A skipped field is never
//!    capped": a field whose wire type contradicts the declared one is stepped
//!    over, so an over-cap count on it is not the receiver's business and the
//!    decode stays `.complete`.
//!
//! The visitor below is the shape generated decode takes on this port: an id
//! switch whose arms are the declared types, a sticky `lim` flag for the
//! terminal policy rejection (the payload callbacks are infallible by design),
//! and `sofab.arrays` for every destination. The cap's *value* is the visitor's;
//! the comparison is the helper's, which is the half §6.2.1 permits a corelib to
//! take.

const std = @import("std");
const sofab = @import("sofab");
const CountingAllocator = @import("array_growth_tests.zig").CountingAllocator;

/// This harness's stand-in for the generated `max_dyn_array_count`. The corelib
/// has no cap of its own to offer and defaults none, so the number is here.
const cap: usize = 4;

/// The "schema": id 1 is an unbounded `array<u32>`, id 2 an unbounded `string`.
const Msg = struct {
    dyn: []const u32 = &.{},
    name: []const u8 = "",
};

const Visitor = struct {
    alloc: std.mem.Allocator,
    m: Msg = .{},
    /// Terminal policy rejection (§6.3): generated `decode` turns this into
    /// `error.LimitExceeded` once the corelib returns.
    lim: bool = false,
    /// Announced element count and fill index of the array in progress.
    an: usize = 0,
    ai: usize = 0,

    pub fn arrayBegin(self: *Visitor, id: sofab.Id, kind: sofab.ArrayKind, count: usize) void {
        self.an = 0;
        self.ai = 0;
        switch (id) {
            // The §7.3 tag test: only an unsigned array is this field's value.
            1 => if (kind == .unsigned) {
                self.m.dyn = sofab.arrays.allocNCapped(u32, self.alloc, count, cap) catch {
                    self.lim = true;
                    return;
                };
                self.an = count;
            },
            // id 2 is declared `string`; an array there is not its value, and
            // there is no arm to cap.
            else => {},
        }
    }

    pub fn unsigned(self: *Visitor, id: sofab.Id, value: u64) void {
        if (id != 1) return;
        sofab.arrays.putGrowing(&self.m.dyn, self.alloc, &self.ai, self.an, @truncate(value));
    }

    pub fn string(self: *Visitor, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        _ = .{ total, offset };
        if (id == 2) self.m.name = chunk;
    }
};

/// A `count`-element unsigned array at `id`, plus nothing else.
fn arrayMessage(buf: []u8, id: sofab.Id, count: usize) ![]const u8 {
    var vals: [64]u64 = undefined;
    for (0..count) |i| vals[i] = i;
    var os = sofab.OStream.init(buf);
    try os.writeArrayUnsigned(id, vals[0..count]);
    return buf[0..os.bytesUsed()];
}

test "an over-cap array count is refused at the header, before any allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    var buf: [256]u8 = undefined;
    const msg = try arrayMessage(&buf, 1, cap + 12);

    var v: Visitor = .{ .alloc = counter.allocator() };
    const st = try sofab.decode(msg, &v);

    try std.testing.expect(v.lim);
    // Rejected, never clamped (§6.2.1): not `cap` elements, none.
    try std.testing.expectEqual(@as(usize, 0), v.m.dyn.len);
    // Before the allocation it exists to prevent.
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    // The bytes are well-formed; the refusal is policy, not malformation
    // (§6.3), so the decoder's own outcome is untouched by it.
    try std.testing.expectEqual(sofab.Status.complete, st);
}

test "a count at the cap decodes, and every element lands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [256]u8 = undefined;
    const msg = try arrayMessage(&buf, 1, cap);

    var v: Visitor = .{ .alloc = arena.allocator() };
    _ = try sofab.decode(msg, &v);

    try std.testing.expect(!v.lim);
    try std.testing.expectEqual(cap, v.m.dyn.len);
    for (0..cap) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), v.m.dyn[i]);
}

test "a skipped field is never capped (MESSAGE_SPEC §7.3)" {
    // The same over-cap array, at an id the schema declares `string`. §7.3
    // skips the occurrence, and §6.2.1's "a skipped field is never capped"
    // means the decode must stay COMPLETE rather than become a policy
    // rejection: nothing was going to be allocated for it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    var buf: [256]u8 = undefined;
    const msg = try arrayMessage(&buf, 2, cap + 12);

    var v: Visitor = .{ .alloc = counter.allocator() };
    const st = try sofab.decode(msg, &v);

    try std.testing.expect(!v.lim);
    try std.testing.expectEqual(sofab.Status.complete, st);
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqualStrings("", v.m.name);
}

test "the cap does not reach a field the same message bounds elsewhere" {
    // Two arrays in one message: the capped one is refused, the field at an id
    // the visitor does not cap is untouched by it. A cap is per call site, not
    // per decode -- there is no decoder-level limit to bind a sibling.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [256]u8 = undefined;
    var vals: [16]u64 = undefined;
    for (0..vals.len) |i| vals[i] = i;
    var os = sofab.OStream.init(&buf);
    try os.writeArrayUnsigned(2, vals[0..]); // not this visitor's array field
    try os.writeArrayUnsigned(1, vals[0..]); // over the cap
    const msg = buf[0..os.bytesUsed()];

    var v: Visitor = .{ .alloc = arena.allocator() };
    const st = try sofab.decode(msg, &v);

    try std.testing.expect(v.lim);
    try std.testing.expectEqual(@as(usize, 0), v.m.dyn.len);
    try std.testing.expectEqual(sofab.Status.complete, st);
}
