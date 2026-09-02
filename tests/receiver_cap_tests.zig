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
//! Both are asserted by **measuring the allocator**, not by reading the
//! outcome. A decode that commits a megabyte and *then* reports
//! `LimitExceeded` passes every outcome-only assertion while doing precisely
//! what the cap exists to prevent, so a counting allocator is what separates
//! the two.
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
/// The same for `max_dyn_string_len`, and deliberately tiny next to the
/// payloads below: the point is the distance between what is announced and what
/// is allowed to be committed.
const str_cap: usize = 1024;

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
    /// The INVALID latch generated code keeps alongside it. Only an allocation
    /// failure sets it here, and the two must not be confused (§6.3).
    inv: bool = false,
    /// Announced element count and fill index of the array in progress.
    an: usize = 0,
    ai: usize = 0,
    /// Payload reassembly, exactly as generated code holds it: `own` is set on
    /// the streaming path, where a payload completing inside the decoder's
    /// reused carry buffer must be copied rather than borrowed.
    acc: sofab.PayloadAcc = .{},
    own: bool = false,

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
        // The id switch comes FIRST, and the reassembly sits inside the arm
        // that decodes the field. A payload at any other id is one this schema
        // declares as something else, or does not declare at all: it is walked,
        // and materializing it here would buffer a payload nothing reads
        // (§6.2.1, "a skipped field is never capped" — it is not allocated for
        // either).
        if (id != 2) return;
        // The cap goes IN, at the announced length, ahead of the copy. Nothing
        // is taken for a payload this refuses.
        const v = self.acc.takeCapped(self.alloc, total, offset, chunk, !self.own, str_cap) catch |e| {
            switch (e) {
                error.LimitExceeded => self.lim = true,
                error.OutOfMemory => self.inv = true,
            }
            return;
        } orelse return; // still incomplete: more chunks to come
        self.m.name = v;
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
    // `.complete` — but not because a policy rejection leaves the outcome
    // alone. §6.3 calls this rejection **terminal**, and a refusal the decoder
    // can see does end the decode: raising `error.LimitExceeded` out of
    // `fixlenBegin` latches it, and every later `feed` raises that same code
    // (src/istream.zig).
    // This refusal the decoder never sees. `arrayBegin` is infallible by
    // design, so the cap is compared inside the callback and the verdict is
    // held in `v.lim` for generated `decode` to report; the decoder consumed a
    // well-formed message whole, and `.complete` is its truthful answer about
    // the bytes. That a cap enforced on this route cannot terminate the decode
    // is a gap in the callback contract, not a property of policy rejections.
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

// ---------------------------------------------------------------------------
// string/blob payloads: the cap at the length header, and the skip that never
// reaches it
// ---------------------------------------------------------------------------

/// A `len`-byte string field at `id`, encoded through a small scratch buffer so
/// the message may be far larger than any buffer this test owns.
fn stringMessage(gpa: std.mem.Allocator, id: sofab.Id, len: usize) ![]u8 {
    const payload = try gpa.alloc(u8, len);
    defer gpa.free(payload);
    @memset(payload, 'x');

    var sink: sofab.CollectingSink = .{ .alloc = gpa };
    errdefer sink.deinit();
    var scratch: [4096]u8 = undefined;
    var os = sofab.OStream.initFlush(&scratch, 0, &sink, sofab.CollectingSink.push);
    try os.writeString(id, payload);
    _ = os.flush();
    return sink.toOwnedSlice();
}

/// Feed `msg` to a streaming decoder in `chunk`-byte pieces, counting every
/// allocation the visitor makes.
fn feedCounting(v: *Visitor, msg: []const u8, chunk: usize) !sofab.Status {
    var is = sofab.IStream.init();
    var st: sofab.Status = .complete;
    var i: usize = 0;
    while (i < msg.len) : (i += chunk) {
        st = try is.feed(msg[i..@min(i + chunk, msg.len)], v);
    }
    return st;
}

const MIB: usize = 1 << 20;

test "an over-cap string payload is refused at the length header, before it is buffered" {
    // The failure this pins: reassembling first and comparing afterwards
    // commits the whole megabyte and only then reports the refusal — the cap
    // fires, and the allocation it exists to prevent has already happened.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    const msg = try stringMessage(std.testing.allocator, 2, MIB);
    defer std.testing.allocator.free(msg);

    var v: Visitor = .{ .alloc = counter.allocator(), .own = true };
    const st = try feedCounting(&v, msg, 64 * 1024);

    try std.testing.expect(v.lim);
    try std.testing.expect(!v.inv);
    // Before the allocation it exists to prevent — not one byte of the payload.
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
    // Rejected, never clamped: no `str_cap`-byte prefix landed either.
    try std.testing.expectEqualStrings("", v.m.name);
    // The bytes are well-formed; the refusal is policy, not malformation.
    try std.testing.expectEqual(sofab.Status.complete, st);
}

test "a skipped string payload is walked, not buffered and not capped" {
    // The same megabyte, at an id this schema declares `array<u32>`. §7.3 skips
    // the occurrence; §6.2.1's "a skipped field is never capped" then means the
    // decode stays COMPLETE — and the reason it may stay complete is that
    // nothing was allocated for it, which is what the counter checks.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    const msg = try stringMessage(std.testing.allocator, 1, MIB);
    defer std.testing.allocator.free(msg);

    var v: Visitor = .{ .alloc = counter.allocator(), .own = true };
    const st = try feedCounting(&v, msg, 64 * 1024);

    try std.testing.expect(!v.lim);
    try std.testing.expect(!v.inv);
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
    try std.testing.expectEqual(sofab.Status.complete, st);
}

test "an over-cap payload arriving whole in one feed is refused just as early" {
    // The split path is not the only one that commits: on the streaming path a
    // payload that never straddles a chunk boundary is still COPIED, because it
    // may point into the decoder's reused carry buffer. The cap has to be ahead
    // of that copy too, which is why it lives inside `takeCapped` rather than in
    // front of the split branch only.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    const msg = try stringMessage(std.testing.allocator, 2, MIB);
    defer std.testing.allocator.free(msg);

    var v: Visitor = .{ .alloc = counter.allocator(), .own = true };
    const st = try feedCounting(&v, msg, msg.len); // one feed, whole message

    try std.testing.expect(v.lim);
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqual(sofab.Status.complete, st);
}

test "a string payload under the cap decodes, split across chunks or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try stringMessage(std.testing.allocator, 2, str_cap);
    defer std.testing.allocator.free(msg);

    for ([_]usize{ 7, 512, 1 << 20 }) |chunk| {
        var v: Visitor = .{ .alloc = arena.allocator(), .own = true };
        const st = try feedCounting(&v, msg, chunk);
        try std.testing.expect(!v.lim);
        try std.testing.expect(!v.inv);
        try std.testing.expectEqual(str_cap, v.m.name.len);
        try std.testing.expectEqual(@as(u8, 'x'), v.m.name[str_cap - 1]);
        try std.testing.expectEqual(sofab.Status.complete, st);
    }
}

test "the contiguous path still borrows: a payload under the cap costs nothing" {
    // `own = false` is the one-shot `decode` shape, where the caller's buffer
    // outlives the message. The cap is compared all the same, but an accepted
    // payload is handed back unallocated.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: CountingAllocator = .{ .child = arena.allocator() };

    const msg = try stringMessage(std.testing.allocator, 2, 64);
    defer std.testing.allocator.free(msg);

    var v: Visitor = .{ .alloc = counter.allocator() };
    const st = try sofab.decode(msg, &v);

    try std.testing.expect(!v.lim);
    try std.testing.expectEqual(@as(usize, 64), v.m.name.len);
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqual(sofab.Status.complete, st);
}
