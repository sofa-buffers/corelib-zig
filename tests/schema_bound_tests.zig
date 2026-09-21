//! A **schema-bounded** wrapper array, driven through a real decode
//! (MESSAGE_SPEC §5.1, §7.1; CORELIB_PLAN §6.2.1, §7.2 item 8).
//!
//! `sequence_growth_tests.zig` drives the other half of the same helper surface:
//! an array the schema leaves unbounded, where the RECEIVER cap governs the
//! element index and a breach is `LimitExceeded`. These cases are its twin under
//! the other `arrays.Bound` — a declared `count:`, whose breach is `INVALID`
//! because the wire contradicts the schema both peers agreed on. One rule, one
//! implementation, two verdicts; a port that collapses them reads to a
//! differential fuzzer as a wire divergence.
//!
//! The visitor below is the shape generated decode takes for
//! `tags: array<string>, count: 4, maxlen: 8`:
//!
//! * `fixlenBegin` decides both bounds at the **length word**, index first: an
//!   element that is not this array's element at all must not have its length
//!   measured against the element bound. Deciding them there is what keeps a
//!   message that ends right after the word `INVALID` rather than `INCOMPLETE`
//!   (§5.2) — `payload_over_maxlen_truncated_at_the_word` is that case.
//! * `string()` then places the payload through `arrays.placeElem`, which
//!   carries the same `count` bound: the check runs before any growth, so a
//!   refused id leaves the container unextended and a lower id delivered
//!   afterwards still lands.
//! * The element `maxlen` is deliberately NOT one of `arrays.Bound`'s cases.
//!   There is no sizing call in the corelib for it to ride, and the verdict has
//!   to be taken at the length word, so it stays where the generator emits it.

const std = @import("std");
const sofab = @import("sofab");
const arrays = sofab.arrays;

/// The "schema": field id 1 is `array<string>` with `count: 4`, each element
/// `maxlen: 8`.
const field_id: sofab.Id = 1;
const tags_bound: arrays.Bound = .{ .schema = 4 };
const elem_maxlen: usize = 8;

const Msg = struct { tags: []const []const u8 = &.{} };

const Visitor = struct {
    alloc: std.mem.Allocator,
    m: Msg = .{},
    /// The sticky INVALID latch generated code keeps for the callbacks that are
    /// infallible by design (`string` is one).
    inv: bool = false,
    depth: usize = 0,
    acc: sofab.PayloadAcc = .{},

    pub fn sequenceBegin(self: *Visitor, id: sofab.Id) void {
        self.depth += 1;
        // Entering the array's own scope: the field is reset, so a re-opened
        // array replaces rather than continuing (§7.4).
        if (self.depth == 1 and id == field_id) self.m.tags = &.{};
    }

    pub fn sequenceEnd(self: *Visitor) void {
        self.depth -= 1;
    }

    pub fn fixlenBegin(
        self: *Visitor,
        id: sofab.Id,
        subtype: sofab.FixlenType,
        total: usize,
    ) sofab.Error!void {
        // §7.3: the bounds belong to the declared type, so an arrival of another
        // kind is skipped rather than measured against them.
        if (self.depth != 1 or subtype != .string) return;
        try arrays.overIndex(tags_bound, id);
        if (total > elem_maxlen) return sofab.Error.InvalidMessage;
    }

    pub fn string(self: *Visitor, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        if (self.depth != 1) return;
        const text = (self.acc.take(self.alloc, total, offset, chunk, true) catch return) orelse return;
        arrays.placeElem([]const u8, tags_bound, self.alloc, &self.m.tags, id, "", text) catch {
            self.inv = true;
        };
    }
};

/// Encode one wrapper array of `(id, text)` elements into `buf`, and hand back
/// the bytes.
fn encode(buf: []u8, elems: []const struct { id: sofab.Id, text: []const u8 }) ![]const u8 {
    var os = sofab.OStream.init(buf);
    try os.writeSequenceBeginLazy(field_id);
    for (elems) |e| try os.writeString(e.id, e.text);
    try os.writeSequenceEnd();
    return buf[0..os.bytesUsed()];
}

fn run(arena: std.mem.Allocator, bytes: []const u8) !struct { status: sofab.Status, v: Visitor } {
    var v: Visitor = .{ .alloc = arena };
    const status = try sofab.decode(bytes, &v);
    return .{ .status = status, .v = v };
}

test "a schema-bounded wrapper array: every id up to the bound lands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const bytes = try encode(&buf, &.{
        .{ .id = 0, .text = "a" },
        .{ .id = 1, .text = "bb" },
        .{ .id = 2, .text = "ccc" },
        .{ .id = 3, .text = "dddd" }, // the last legal index for `count: 4`
    });

    const r = try run(arena.allocator(), bytes);
    try std.testing.expectEqual(sofab.Status.complete, r.status);
    try std.testing.expect(!r.v.inv);
    try std.testing.expectEqual(@as(usize, 4), r.v.m.tags.len);
    try std.testing.expectEqualStrings("dddd", r.v.m.tags[3]);
}

test "an omitted interior element decodes as a gap, not as a shift (§2, §5.1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    // A conformant encoder omits an interior element equal to the element
    // default, so ids 1 and 2 are simply absent from the wire.
    const bytes = try encode(&buf, &.{
        .{ .id = 0, .text = "first" },
        .{ .id = 3, .text = "last" },
    });

    const r = try run(arena.allocator(), bytes);
    try std.testing.expectEqual(sofab.Status.complete, r.status);
    try std.testing.expectEqual(@as(usize, 4), r.v.m.tags.len);
    try std.testing.expectEqualStrings("first", r.v.m.tags[0]);
    try std.testing.expectEqualStrings("", r.v.m.tags[1]);
    try std.testing.expectEqualStrings("", r.v.m.tags[2]);
    try std.testing.expectEqualStrings("last", r.v.m.tags[3]);
}

test "an id at the schema count is INVALID, and the array is not extended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    // `count: 4` is a CAPACITY, so id 4 is the first one past it.
    const bytes = try encode(&buf, &.{
        .{ .id = 0, .text = "kept" },
        .{ .id = 4, .text = "over" },
    });

    var v: Visitor = .{ .alloc = arena.allocator() };
    try std.testing.expectError(sofab.Error.InvalidMessage, sofab.decode(bytes, &v));
    // §7.2 item 8: the refusal ran before any growth, so the element that had
    // already landed is all the container holds — it was not extended to 5 on
    // the way out.
    try std.testing.expectEqual(@as(usize, 1), v.m.tags.len);
    try std.testing.expectEqualStrings("kept", v.m.tags[0]);
}

test "the refusal is terminal: no later feed resynchronizes past it (§6.3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const bytes = try encode(&buf, &.{.{ .id = 9, .text = "over" }});

    var v: Visitor = .{ .alloc = arena.allocator() };
    var is = sofab.IStream.init();
    try std.testing.expectError(sofab.Error.InvalidMessage, is.feed(bytes, &v));
    // A whole, perfectly valid message afterwards is refused just the same.
    var buf2: [128]u8 = undefined;
    const good = try encode(&buf2, &.{.{ .id = 0, .text = "ok" }});
    try std.testing.expectError(sofab.Error.InvalidMessage, is.feed(good, &v));
}

test "an element payload over maxlen is INVALID at the length word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const bytes = try encode(&buf, &.{
        .{ .id = 0, .text = "12345678" }, // exactly `maxlen`: admitted
        .{ .id = 1, .text = "123456789" }, // one byte over
    });

    var v: Visitor = .{ .alloc = arena.allocator() };
    try std.testing.expectError(sofab.Error.InvalidMessage, sofab.decode(bytes, &v));
    try std.testing.expectEqual(@as(usize, 1), v.m.tags.len);
    try std.testing.expectEqualStrings("12345678", v.m.tags[0]);
}

test "an over-maxlen element truncated at its length word is INVALID, not INCOMPLETE" {
    // MESSAGE_SPEC §5.2: INVALID dominates INCOMPLETE. The bound is decided at
    // the length word, so the verdict stands even though not one payload byte
    // ever arrived — a check made after the read could not fire here at all.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const whole = try encode(&buf, &.{.{ .id = 0, .text = "123456789" }});
    // Drop the 9 payload bytes and the sequence-end byte behind them: the input
    // now ends immediately after the element's length word.
    const at_the_word = whole[0 .. whole.len - 10];

    var v: Visitor = .{ .alloc = arena.allocator() };
    try std.testing.expectError(sofab.Error.InvalidMessage, sofab.decode(at_the_word, &v));
    try std.testing.expectEqual(@as(usize, 0), v.m.tags.len);

    // THE CONTROL: the same shape at a length the bound admits is INCOMPLETE,
    // so the bound cannot be passing the case above by rejecting every short
    // read.
    const short = try encode(&buf, &.{.{ .id = 0, .text = "12345678" }});
    var v2: Visitor = .{ .alloc = arena.allocator() };
    const status = try sofab.decode(short[0 .. short.len - 9], &v2);
    try std.testing.expectEqual(sofab.Status.incomplete, status);
}

test "an over-index element truncated at its length word is INVALID too" {
    // The index twin of the case above, and the reason `overIndex` is published
    // beside the three placement helpers: `placeElem` would bound this id as
    // well, but `string()` is never reached for a message that stops here.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const whole = try encode(&buf, &.{.{ .id = 7, .text = "12345678" }});
    const at_the_word = whole[0 .. whole.len - 9];

    var v: Visitor = .{ .alloc = arena.allocator() };
    try std.testing.expectError(sofab.Error.InvalidMessage, sofab.decode(at_the_word, &v));
    try std.testing.expectEqual(@as(usize, 0), v.m.tags.len);
}
