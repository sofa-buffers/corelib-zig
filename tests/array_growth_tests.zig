//! Sequence-array growth: geometry and the id-keyed placement rules
//! (CORELIB_PLAN §7.2 item 8, SofaBuffers ARCHITECTURE §9.5).
//!
//! A sequence array's length is *highest present id + 1* (MESSAGE_SPEC §5.1), so
//! its size is known only when the array ends and its container grows as
//! elements arrive. That is the one allocation shape where growth is conformant,
//! and it lives in the static helper layer (`sofab.arrays`), never in the codec
//! (§6.6.1).
//!
//! Item 8 asks for the geometry to be measured "where the language offers" an
//! allocation-counting facility. Zig does: an allocator is a value, so a
//! counting one wraps any other. This file uses it to pin that filling an array
//! element by element costs **O(log n) allocations**, not one per element —
//! against the arena of `sofab.arrays`' allocator contract, which *abandons* the
//! block it grew out of, the copies of an exactly-sized growth are the peak
//! memory rather than garbage.

const std = @import("std");
const sofab = @import("sofab");
const arrays = sofab.arrays;

/// An allocator that forwards to a child and counts what it was asked for.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    calls: usize = 0,
    bytes: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(buf, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }
};

test "growth geometry: filling n elements costs O(log n) allocations, not n" {
    // The shape the generated decode path takes: `m.string_array = &.{}` and
    // then one `setElem` per arriving element (§7.2 item 8).
    for ([_]usize{ 100, 1000, 4000 }) |n| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var counter: CountingAllocator = .{ .child = arena.allocator() };
        const a = counter.allocator();

        var s: []const []const u8 = &.{};
        for (0..n) |i| arrays.setElem([]const u8, a, &s, i, "", "0123456789abcdef");

        // The value is exactly as long as the ids demand — the geometry is in
        // the block behind it, never in the length.
        try std.testing.expectEqual(n, s.len);

        // Doubling: at most one allocation per power of two, plus one.
        const bound = std.math.log2_int_ceil(usize, n + 1) + 1;
        errdefer std.debug.print(
            "n={d}: {d} allocations ({d} bytes), bound {d}\n",
            .{ n, counter.calls, counter.bytes, bound },
        );
        try std.testing.expect(counter.calls <= bound);
        // And the bytes handed out stay within a constant factor of the live
        // payload — the property an exactly-sized growth loses (it asked for
        // 128,032,000 bytes at n=4000, against 64,000 bytes of live elements).
        try std.testing.expect(counter.bytes <= 4 * n * @sizeOf([]const u8));
    }
}

test "growth geometry: a sparse array pays for its length, not for its ids" {
    // One element at a high id: the container must reach id + 1 in a handful of
    // doublings, not by one reallocation per id, and nothing between them is
    // copied more than a constant number of times.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };
    const a = counter.allocator();

    var s: []const u32 = &.{};
    for ([_]usize{ 0, 5, 6, 100, 4095 }) |id| arrays.setElem(u32, a, &s, id, 0, @intCast(id));

    try std.testing.expectEqual(@as(usize, 4096), s.len);
    try std.testing.expect(counter.calls <= 6);
    for ([_]usize{ 0, 5, 6, 100, 4095 }) |id| try std.testing.expectEqual(@as(u32, @intCast(id)), s[id]);
}

test "an id gap is filled with the element default and shifts nothing (§7.2 item 8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const []const u8 = &.{};
    arrays.setElem([]const u8, a, &s, 0, "", "zero");
    arrays.setElem([]const u8, a, &s, 3, "", "three");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("zero", s[0]);
    try std.testing.expectEqualStrings("", s[1]);
    try std.testing.expectEqualStrings("", s[2]);
    try std.testing.expectEqualStrings("three", s[3]);

    // A lower id delivered afterwards lands in its own slot rather than
    // appending, and does not disturb its neighbours.
    arrays.setElem([]const u8, a, &s, 1, "", "one");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("one", s[1]);
    try std.testing.expectEqualStrings("three", s[3]);

    // A repeated id replaces (MESSAGE_SPEC §7.4), never appends.
    arrays.setElem([]const u8, a, &s, 3, "", "THREE");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("THREE", s[3]);
}

test "a rejected id leaves the container unextended, and a lower id still lands" {
    // The cap's *value* belongs to generated code (§6.2.1: "the codec never
    // invents a limit of its own"), but the comparison is `setElemCapped`'s —
    // §6.2.1 permits a corelib to take the number as an argument and check it.
    // What the helper owes is that nothing was extended on the way to the
    // refusal: no allocator call, no length change.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };
    const a = counter.allocator();

    const cap: usize = 8;
    var s: []const u32 = &.{};
    try arrays.setElemCapped(u32, a, &s, cap - 1, 0, 7, cap); // the last legal id
    try std.testing.expectEqual(cap, s.len);

    const before_len = s.len;
    const before_calls = counter.calls;
    try std.testing.expectError(
        sofab.Error.LimitExceeded,
        arrays.setElemCapped(u32, a, &s, cap, 0, 9, cap),
    );
    try std.testing.expectEqual(before_len, s.len);
    try std.testing.expectEqual(before_calls, counter.calls);

    // …and the container is still usable for a lower id.
    try arrays.setElemCapped(u32, a, &s, 2, 0, 42, cap);
    try std.testing.expectEqual(cap, s.len);
    try std.testing.expectEqual(@as(u32, 42), s[2]);
    try std.testing.expectEqual(@as(u32, 7), s[cap - 1]);
}

test "grow keeps the elements it already held across a reallocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: []const u32 = &.{};
    for (0..5) |i| arrays.setElem(u32, a, &s, i, 0, @intCast(i + 1));
    // Crosses two capacity boundaries at once.
    try std.testing.expect(arrays.grow(u32, a, &s, 40, 0));
    try std.testing.expectEqual(@as(usize, 40), s.len);
    for (0..5) |i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), s[i]);
    for (5..40) |i| try std.testing.expectEqual(@as(u32, 0), s[i]);
}
