//! The shared `sequence_growth` cases (CORELIB_PLAN §7.1, §7.2 item 8).
//!
//! A wrapper array carries no length: MESSAGE_SPEC §5.1 makes it *highest
//! present id + 1*, so its container grows as elements arrive. The growth
//! belongs to the static helper / generated layer (§6.6.1) and never to the
//! codec — this port ships that layer as `sofab.arrays`, and the collector
//! below is that layer driven through the public visitor API exactly as
//! generated code drives it. Its growth **geometry** is measured in
//! `array_growth_tests.zig`.
//!
//! What the codec owes, and what these cases pin, is §6.2.1's other half:
//!
//! > for a **sequence array** it surfaces the **index** of the element in hand …
//! > the visitor decides.
//!
//! So the decoder must hand over each element's id, unrenumbered and
//! uncompacted, before the container it indexes into is extended. This port's
//! `string`/`sequenceBegin` callbacks are infallible by design (as are
//! `corelib-rs`'), so what makes the rejection **terminal** is the visitor
//! latching it: once a cap is exceeded, nothing further lands, which is exactly
//! what `growth_no_partial_extension` asserts by bounding the container's
//! length.
//!
//! The cap's **value** is the collector's, supplied per call — the corelib has
//! none to offer and defaults none. The **comparison** is `sofab.arrays`'
//! (`growCapped`), which §6.2.1 permits: "a corelib MAY take a limit as an
//! argument and perform the check itself". One implementation either way, so
//! the collector does not also guard in front of the call.
//!
//! Cases are keyed by a delivery sequence rather than by bytes, because two
//! ports that grow differently emit identical bytes. Indices are cap-relative:
//! a case's `id_from_cap` is an offset onto *this* port's cap.

const std = @import("std");
const sofab = @import("sofab");

const growth_json = @embedFile("test_vectors");

/// This port's element cap for the block. The vectors require at least 4 and
/// resolve every `*_from_cap` against whatever the port picks. It is the test's
/// stand-in for the `max_dyn_array_count` generated code supplies (§6.2.1) —
/// the corelib has no cap of its own to offer.
const cap: usize = 8;

// ---------------------------------------------------------------------------
// the collector — sofab.arrays, driven the way generated decode drives it
// ---------------------------------------------------------------------------

/// One struct element: an `unsigned` at id 0, per the block's own note.
const Element = struct { value: u64 = 0 };

const Kind = enum { string, structural };

/// The object that holds the array field. A wrapper array's scope is the array,
/// so the ids seen inside it are that array's indices.
fn Collector(comptime kind: Kind) type {
    const T = if (kind == .string) []const u8 else Element;
    const default: T = if (kind == .string) "" else .{};

    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        field_id: sofab.Id,
        out: []const T = &.{},
        /// Set once an element index exceeded the cap. §6.3's terminal policy
        /// rejection: nothing lands after it, and it is *not* `InvalidMessage`.
        limit_exceeded: bool = false,
        depth: usize = 0,
        /// Index of the struct element currently being framed.
        elem: usize = 0,
        in_elem: bool = false,

        pub fn string(self: *Self, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
            _ = .{ total, offset };
            if (kind != .string or self.depth != 1) return;
            if (self.limit_exceeded) return;
            // The slot is reserved first, so the cap is decided at the element
            // index before *anything* is sized — the payload copy below is this
            // harness's own storage (generated decode stores a view instead) and
            // is made only once the index has been admitted.
            const grown = sofab.arrays.growCapped([]const u8, self.alloc, &self.out, id + 1, default, cap) catch {
                self.limit_exceeded = true;
                return;
            };
            if (!grown) return;
            const copy = self.alloc.alloc(u8, chunk.len) catch return;
            @memcpy(copy, chunk);
            sofab.arrays.at(self.out, id).* = copy;
        }

        pub fn unsigned(self: *Self, id: sofab.Id, value: u64) void {
            if (kind != .structural or !self.in_elem or id != 0) return;
            if (self.limit_exceeded) return;
            sofab.arrays.at(self.out, self.elem).value = value;
        }

        pub fn sequenceBegin(self: *Self, id: sofab.Id) void {
            self.depth += 1;
            if (self.depth == 2 and kind == .structural) {
                if (self.limit_exceeded) return;
                const grown = sofab.arrays.growCapped(Element, self.alloc, &self.out, id + 1, default, cap) catch {
                    self.limit_exceeded = true;
                    return;
                };
                if (!grown) return;
                self.elem = id;
                self.in_elem = true;
            }
        }

        pub fn sequenceEnd(self: *Self) void {
            if (self.depth == 2) self.in_elem = false;
            self.depth -= 1;
        }
    };
}

// ---------------------------------------------------------------------------
// case plumbing
// ---------------------------------------------------------------------------

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return v.object.get(key);
}

/// Cap-relative or absolute, whichever the case states: `id` / `length` are
/// absolute, `id_from_cap` / `length_from_cap` are offsets onto this port's cap.
fn resolveNamed(entry: std.json.Value, comptime key: []const u8) usize {
    if (get(entry, key)) |v| return @intCast(v.integer);
    const rel = get(entry, key ++ "_from_cap").?.integer;
    return @intCast(@as(i64, @intCast(cap)) + rel);
}

fn parseCases(arena: std.mem.Allocator) []const std.json.Value {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, growth_json, .{}) catch
        @panic("failed to parse test_vectors.json");
    const block = doc.object.get("sequence_growth") orelse return &.{};
    return block.array.items;
}

/// The message the delivery sequence describes. `writeSequenceEndKeep` frames
/// the array explicitly, so the empty case is a frame with nothing in it rather
/// than no field at all.
fn build(buf: []u8, case: std.json.Value, is_struct: bool) ![]const u8 {
    var os = sofab.OStream.init(buf);
    const field_id: sofab.Id = @intCast(get(case, "field_id").?.integer);
    try os.writeSequenceBeginLazy(field_id);
    for (get(case, "deliver").?.array.items) |entry| {
        const index: sofab.Id = @intCast(resolveNamed(entry, "id"));
        if (is_struct) {
            try os.writeSequenceBeginLazy(index);
            try os.writeUnsigned(0, @intCast(get(entry, "value").?.integer));
            try os.writeSequenceEndKeep();
        } else {
            try os.writeString(index, get(entry, "value").?.string);
        }
    }
    try os.writeSequenceEndKeep();
    return buf[0..os.bytesUsed()];
}

fn runCase(arena: std.mem.Allocator, case: std.json.Value, comptime kind: Kind) !void {
    var buf: [4096]u8 = undefined;
    const wire = try build(&buf, case, kind == .structural);
    const expect = get(case, "expect").?;

    var col: Collector(kind) = .{
        .alloc = arena,
        .field_id = @intCast(get(case, "field_id").?.integer),
    };
    // The codec's own outcome is about the *bytes*, which are well-formed in
    // every case here — a limit rejection is the receiver's, never INVALID
    // (§6.2.1, §6.3).
    try std.testing.expectEqual(sofab.Status.complete, try sofab.decode(wire, &col));

    if (std.mem.eql(u8, get(expect, "outcome").?.string, "limit_exceeded")) {
        try std.testing.expect(col.limit_exceeded);
        const max: usize = @intCast(get(expect, "max_length").?.integer);
        try std.testing.expect(col.out.len <= max);
        return;
    }

    try std.testing.expect(!col.limit_exceeded);
    try std.testing.expectEqual(resolveNamed(expect, "length"), col.out.len);
    if (get(expect, "default_ids")) |gaps| {
        for (gaps.array.items) |g| {
            const i: usize = @intCast(g.integer);
            switch (kind) {
                .string => try std.testing.expectEqualStrings("", col.out[i]),
                .structural => try std.testing.expectEqual(@as(u64, 0), col.out[i].value),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------

test "the sequence_growth block is present and gated on dynamic_arrays (§7.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = parseCases(arena_state.allocator());
    // "A port runs every block its `requires` gating does not exclude." This
    // port grows (`sofab.arrays`), so `dynamic_arrays` does not exclude it and
    // a silently empty block would mean the asset went stale again.
    try std.testing.expect(cases.len > 0);
    for (cases) |c| {
        var gated = false;
        for (get(c, "requires").?.array.items) |r| {
            if (std.mem.eql(u8, r.string, "dynamic_arrays")) gated = true;
        }
        try std.testing.expect(gated);
    }
    // Every case assumes a cap of at least 4 (the block's own note).
    try std.testing.expect(cap >= 4);
}

test "every sequence_growth case (§7.2 item 8)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var ran: usize = 0;
    for (cases) |case| {
        const name = get(case, "name").?.string;
        errdefer std.debug.print("sequence_growth case [{s}] failed\n", .{name});
        const et = get(case, "element_type").?.string;
        if (std.mem.eql(u8, et, "struct")) {
            try runCase(arena, case, .structural);
        } else {
            try runCase(arena, case, .string);
        }
        ran += 1;
    }
    try std.testing.expectEqual(cases.len, ran);
}
