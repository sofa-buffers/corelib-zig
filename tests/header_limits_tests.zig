//! The shared `header_limits` cases (CORELIB_PLAN §6.2.1, §6.3; MESSAGE_SPEC
//! §5.2, §7.1).
//!
//! The block carries one shape no other can: bytes that **declare** a length or
//! a count and then **end**, with not one payload byte behind them.
//!
//! ```text
//! 02 a2 06   then EOF
//! ^^ id 0, wire type 2 (fixlen)
//!    ^^^^^ length word (100 << 3) | 2  ->  a 100-byte STRING is declared
//!            ... and the message ends.
//! ```
//!
//! A ceiling is decided **at that word**, before the payload is asked for, so
//! the answer is the ceiling's and it is **terminal**. `INCOMPLETE` — which
//! §5.2.1 defines as the outcome more bytes *can* change, and §5.2.4 has a
//! streaming caller read as "feed me the next chunk" — is a false statement
//! about the state once a ceiling has fired.
//!
//! **Which ceiling speaks is the subject.** A case carries `schema` or `limits`,
//! never both, because §6.2.1 forbids applying a receiver cap to a field the
//! schema already bounds — and the two give opposite answers on the same word:
//!
//! | the case states | the ceiling | a breach is |
//! |---|---|---|
//! | `"schema": { "maxlen": N }` | the schema bound | `invalid` (MESSAGE_SPEC §7.1) |
//! | `"limits": { "max_dyn_…": N }` | the receiver cap | `limit_exceeded` (§6.2.1) |
//!
//! `header_string_schema_bounded` and `header_string_over_cap` carry the
//! identical bytes and differ only in which ceiling the case configures; the
//! test at the bottom of this file asserts that pair on its own, because a port
//! that routes both into one category passes every other case here.
//!
//! **Where this port answers.** Both ceilings are announced to the visitor at
//! the header word and raised from there — `fixlenBegin` for a length,
//! `arrayBegin` for a count (`src/istream.zig`) — which is what makes the
//! verdict terminal: the decoder sees the refusal, latches it, and every later
//! `feed` repeats it instead of resynchronizing on the bytes that follow. The
//! comparison itself is the corelib's, as §6.2.1 permits ("a corelib MAY take a
//! limit as an argument and perform the check itself"): `PayloadAcc.beginCapped`
//! for a payload length, `arrays.allocNCapped` for an element count. The cap's
//! *value* is the receiver's, supplied by the case and held nowhere.
//!
//! **`requires` means SKIP here, for every tag** — not the reduced-build
//! rejection a *vector* gets. These cases assert a rejection with a specific
//! category, so a build that cannot represent the construct would reject it for
//! an unrelated reason and appear to pass while testing nothing.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const vectors_json = @embedFile("test_vectors");

// ---------------------------------------------------------------------------
// capability gating
// ---------------------------------------------------------------------------

/// The tags a `header_limits` case can ask for. Unlike in `vectors_tests.zig`,
/// an unsatisfied tag SKIPS the case rather than turning it into a negative one.
const Capability = enum {
    /// a `string`/`blob` (or float) field — anything carrying a length word.
    fixlen,
    /// an array field, i.e. anything carrying a count word.
    array,
    /// a value or length outside the 32-bit range.
    int64,
    /// A **profile** capability: generated code carries §6.2.1 receiver caps
    /// *distinct from* schema bounds. This port ships exactly that — the capped
    /// half of its helper surface (`PayloadAcc.takeCapped` / `beginCapped`,
    /// `arrays.allocNCapped` / `growCapped` / `setElemCapped`) exists for the
    /// fields a schema leaves unbounded, and answers `LimitExceeded` rather than
    /// the `INVALID` a schema `maxlen` breach gets. So the tag is satisfied and
    /// the capped cases run.
    receiver_caps,

    fn parse(tag: []const u8) Capability {
        return std.meta.stringToEnum(Capability, tag) orelse {
            std.debug.print("unknown `requires` capability tag: {s}\n", .{tag});
            @panic("teach this suite the capability tag rather than ignoring it");
        };
    }

    fn supported(self: Capability) bool {
        return switch (self) {
            .fixlen, .array, .int64, .receiver_caps => true,
        };
    }
};

fn skipped(case: std.json.Value) bool {
    const reqs = get(case, "requires") orelse return false;
    for (reqs.array.items) |r| {
        if (!Capability.parse(r.string).supported()) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// the ceiling a case configures
// ---------------------------------------------------------------------------

/// Which ceiling the case put in front of the field, and its value. Exactly one
/// of `schema` / `limits` is present in a case, so exactly one arm is live.
const Ceiling = union(enum) {
    /// A schema `maxlen` on the field's declared type. Its breach is INVALID:
    /// the schema says these bytes are not a value of that field (§7.1).
    schema_maxlen: usize,
    /// `max_dyn_string_len` — a receiver cap, whose breach is a policy
    /// rejection of well-formed bytes (§6.2.1, §6.3).
    string_cap: usize,
    /// `max_dyn_blob_len`. §6.2.1 keeps blob and string on separate caps
    /// because a deployment may accept a megabyte of opaque bytes and no such
    /// quantity of text, so both enforcement points have to be wired.
    blob_cap: usize,
    /// `max_dyn_array_count` — the same rule for a count word.
    array_cap: usize,

    fn of(case: std.json.Value) Ceiling {
        if (get(case, "schema")) |s| {
            std.debug.assert(get(case, "limits") == null); // §6.2.1: never both
            return .{ .schema_maxlen = @intCast(get(s, "maxlen").?.integer) };
        }
        const limits = get(case, "limits") orelse @panic("case states neither `schema` nor `limits`");
        var it = limits.object.iterator();
        const e = it.next() orelse @panic("empty `limits`");
        const v: usize = @intCast(e.value_ptr.*.integer);
        if (std.mem.eql(u8, e.key_ptr.*, "max_dyn_string_len")) return .{ .string_cap = v };
        if (std.mem.eql(u8, e.key_ptr.*, "max_dyn_blob_len")) return .{ .blob_cap = v };
        if (std.mem.eql(u8, e.key_ptr.*, "max_dyn_array_count")) return .{ .array_cap = v };
        std.debug.print("unknown receiver cap: {s}\n", .{e.key_ptr.*});
        @panic("teach this suite the cap rather than running the case without one");
    }
};

// ---------------------------------------------------------------------------
// the receiver — generated decode's shape, with the ceiling at the header word
// ---------------------------------------------------------------------------

/// The visitor a generated decoder emits for one schema-unbounded (or
/// schema-bounded) field: an id test first, the ceiling compared at the header,
/// and nothing sized before it has answered.
///
/// Both `fixlenBegin` and `arrayBegin` are declared fallible, which is what puts
/// the verdict on the decoder's own error channel and so makes it terminal
/// (§6.3). A cap compared in `string()` instead never runs for these cases at
/// all: the message ends at the length word, so no payload chunk is ever
/// delivered.
const Receiver = struct {
    alloc: std.mem.Allocator,
    field_id: sofab.Id,
    ceiling: Ceiling,
    acc: sofab.PayloadAcc = .{},
    /// Elements/payload actually taken. Asserted to stay empty on a rejection:
    /// a ceiling refuses, it never clamps to its own value (§6.2.1).
    taken: usize = 0,

    pub fn fixlenBegin(
        self: *Receiver,
        id: sofab.Id,
        subtype: sofab.FixlenType,
        total: usize,
    ) sofab.Error!void {
        if (id != self.field_id) return;
        switch (self.ceiling) {
            // MESSAGE_SPEC §7.3: the bound belongs to the declared type, so an
            // arrival of another kind is skipped, not measured against it.
            .schema_maxlen => |maxlen| {
                if (subtype == .string and total > maxlen) return sofab.Error.InvalidMessage;
            },
            .string_cap => |cap| {
                if (subtype == .string) self.acc.beginCapped(total, cap) catch
                    return sofab.Error.LimitExceeded;
            },
            .blob_cap => |cap| {
                if (subtype == .blob) self.acc.beginCapped(total, cap) catch
                    return sofab.Error.LimitExceeded;
            },
            .array_cap => {},
        }
    }

    pub fn arrayBegin(
        self: *Receiver,
        id: sofab.Id,
        _: sofab.ArrayKind,
        count: usize,
    ) sofab.Error!void {
        if (id != self.field_id) return;
        switch (self.ceiling) {
            .array_cap => |cap| {
                // The destination is sized here, behind the cap — the check runs
                // before the allocation it exists to prevent.
                const dst = sofab.arrays.allocNCapped(u64, self.alloc, count, cap) catch
                    return sofab.Error.LimitExceeded;
                self.taken = dst.len;
            },
            else => {},
        }
    }

    pub fn string(self: *Receiver, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        if (id != self.field_id) return;
        _ = .{ total, offset };
        self.taken += chunk.len;
    }

    pub fn blob(self: *Receiver, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        if (id != self.field_id) return;
        _ = .{ total, offset };
        self.taken += chunk.len;
    }
};

// ---------------------------------------------------------------------------
// case plumbing
// ---------------------------------------------------------------------------

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return v.object.get(key);
}

fn parseCases(arena: std.mem.Allocator) []const std.json.Value {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, vectors_json, .{}) catch
        @panic("failed to parse test_vectors.json");
    const block = doc.object.get("header_limits") orelse return &.{};
    return block.array.items;
}

/// The three outcomes a case can state, plus the `complete` a decoder would
/// report if it swallowed the header whole — kept distinct so a wrong answer
/// prints as itself rather than as "not incomplete".
const Outcome = enum {
    complete,
    incomplete,
    invalid,
    limit_exceeded,

    fn parse(s: []const u8) Outcome {
        return std.meta.stringToEnum(Outcome, s) orelse {
            std.debug.print("unknown expect.outcome: {s}\n", .{s});
            @panic("teach this suite the outcome rather than passing the case");
        };
    }
};

fn classify(e: sofab.Error) Outcome {
    return switch (e) {
        sofab.Error.InvalidMessage => .invalid,
        sofab.Error.LimitExceeded => .limit_exceeded,
        // §6.3 keeps the codes apart; anything else here is a harness bug, not
        // a verdict about the bytes.
        else => {
            std.debug.print("unexpected error from feed: {s}\n", .{@errorName(e)});
            @panic("a header ceiling answers with LimitExceeded or InvalidMessage");
        },
    };
}

/// Feed the case's bytes — as `chunks` where it states them, else in one call —
/// and report the outcome. Feeding stops at the first refusal, which is what a
/// caller does.
fn feedCase(is: *sofab.IStream, r: *Receiver, chunks: []const []const u8) Outcome {
    var last: sofab.Status = .complete;
    for (chunks) |c| {
        last = is.feed(c, r) catch |e| return classify(e);
    }
    return switch (last) {
        .complete => .complete,
        .incomplete => .incomplete,
        .invalid => .invalid,
    };
}

/// The chunks a case is fed in: its `chunks` list, or the whole `serialized`.
fn chunksOf(arena: std.mem.Allocator, case: std.json.Value) []const []const u8 {
    if (get(case, "chunks")) |cs| {
        const out = arena.alloc([]const u8, cs.array.items.len) catch @panic("OOM");
        for (cs.array.items, 0..) |c, i| out[i] = common.hexToBytes(arena, c.string);
        return out;
    }
    const one = arena.alloc([]const u8, 1) catch @panic("OOM");
    one[0] = common.hexToBytes(arena, get(case, "serialized").?.string);
    return one;
}

/// Feed `chunk` to a decoder that has already refused, and require the same
/// verdict back. Consuming the bytes instead — answering `.complete` or
/// `.incomplete` about them — is the failure `expect.terminal` names.
fn expectReRaise(is: *sofab.IStream, r: *Receiver, chunk: []const u8, want: Outcome) !void {
    if (is.feed(chunk, r)) |st| {
        std.debug.print(
            "a terminal refusal consumed a further feed instead of re-raising: {s}\n",
            .{@tagName(st)},
        );
        return error.TestExpectedTerminalVerdict;
    } else |e| {
        try std.testing.expectEqual(want, classify(e));
    }
}

fn runCase(arena: std.mem.Allocator, case: std.json.Value) !Outcome {
    const expect = get(case, "expect").?;
    const want = Outcome.parse(get(expect, "outcome").?.string);

    var r: Receiver = .{
        .alloc = arena,
        .field_id = @intCast(get(case, "field_id").?.integer),
        .ceiling = Ceiling.of(case),
    };
    var is = sofab.IStream.init();
    const got = feedCase(&is, &r, chunksOf(arena, case));
    try std.testing.expectEqual(want, got);

    if (want == .incomplete) {
        // The control half of the block. `expect.terminal` is absent precisely
        // because INCOMPLETE is the state more bytes can lift, so nothing is
        // asserted about a further feed beyond it not being a rejection.
        try std.testing.expect(get(expect, "terminal") == null);
        return got;
    }

    // Refused, never clamped to the ceiling's own value (§6.2.1).
    try std.testing.expectEqual(@as(usize, 0), r.taken);

    if (get(expect, "terminal")) |t| {
        try std.testing.expect(t.bool);
        // Terminal means the verdict is latched: a further feed **re-raises**
        // rather than consuming. Both probes matter — the empty one is how a
        // caller re-asks where the decoder stands, and the non-empty one is the
        // real hazard: `00 2a` would decode as unsigned id 0 = 42 on a decoder
        // that resynchronized on the bytes behind the refused header.
        try expectReRaise(&is, &r, &.{}, got);
        try expectReRaise(&is, &r, &[_]u8{ 0x00, 0x2a }, got);
        try std.testing.expectEqual(@as(usize, 0), r.taken);
    }
    return got;
}

// ---------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------

test "the header_limits block is present, and every case names its ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = parseCases(arena_state.allocator());
    // A silently empty block would mean the asset went stale: this port runs
    // every case in it, so an absent block is a copy that regressed.
    try std.testing.expect(cases.len > 0);

    for (cases) |c| {
        // Exactly one ceiling per case — §6.2.1 forbids capping a field the
        // schema already bounds, so a case carrying both would be unrunnable.
        const has_schema = get(c, "schema") != null;
        const has_limits = get(c, "limits") != null;
        try std.testing.expect(has_schema != has_limits);
        _ = Ceiling.of(c);
        // Every tag resolves; an unknown one panics rather than being ignored.
        _ = skipped(c);
        // `terminal` appears only on a rejection: it is the property INCOMPLETE
        // by definition does not have.
        const expect = get(c, "expect").?;
        if (get(expect, "terminal") != null)
            try std.testing.expect(Outcome.parse(get(expect, "outcome").?.string) != .incomplete);
    }
}

test "every rejection in header_limits is paired with an in-cap control" {
    // The block's own rule, asserted rather than assumed: "a port that rejects
    // every short read passes all six rejection cases and is badly broken". A
    // control is the same ceiling — same kind, same value — at a length it
    // admits, and it must expect `incomplete`. A missing one is a bug in the
    // block, so this test names the case it could not pair.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = parseCases(arena_state.allocator());

    var rejections: usize = 0;
    var controls: usize = 0;
    for (cases) |c| {
        const want = Outcome.parse(get(get(c, "expect").?, "outcome").?.string);
        if (want == .incomplete) {
            controls += 1;
            continue;
        }
        rejections += 1;
        const ceiling = Ceiling.of(c);
        var paired = false;
        for (cases) |o| {
            if (Outcome.parse(get(get(o, "expect").?, "outcome").?.string) != .incomplete) continue;
            if (std.meta.eql(Ceiling.of(o), ceiling)) paired = true;
        }
        if (!paired) std.debug.print("no in-cap control for [{s}]\n", .{get(c, "name").?.string});
        try std.testing.expect(paired);
    }
    try std.testing.expect(rejections > 0);
    try std.testing.expect(controls > 0);
}

test "every header_limits case (§6.2.1, §6.3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var ran: usize = 0;
    var gated: usize = 0;
    var rejected: usize = 0;
    for (cases) |case| {
        const name = get(case, "name").?.string;
        errdefer std.debug.print("header_limits case [{s}] failed\n", .{name});
        if (skipped(case)) {
            gated += 1;
            continue;
        }
        if (try runCase(arena, case) != .incomplete) rejected += 1;
        ran += 1;
    }
    try std.testing.expectEqual(cases.len, ran + gated);
    std.debug.print(
        "\n[header_limits] {d} cases run ({d} rejections, {d} in-ceiling controls), {d} skipped by `requires`\n",
        .{ ran, rejected, ran - rejected, gated },
    );
}

test "the schema bound and the receiver cap stay apart on identical bytes" {
    // The pair the block exists for. Same length word, opposite categories:
    // a schema bound is a statement about validity (MESSAGE_SPEC §7.1), a
    // receiver cap one about capacity (§6.2.1). Asserted here on its own,
    // because a port that routes both into one category passes every other
    // case above.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var capped: ?std.json.Value = null;
    var bounded: ?std.json.Value = null;
    for (cases) |c| {
        const name = get(c, "name").?.string;
        if (std.mem.eql(u8, name, "header_string_over_cap")) capped = c;
        if (std.mem.eql(u8, name, "header_string_schema_bounded")) bounded = c;
    }
    const a = capped orelse @panic("header_string_over_cap missing from the block");
    const b = bounded orelse @panic("header_string_schema_bounded missing from the block");

    // Identical bytes — that is what makes the pair a test of the routing
    // rather than of the parsing.
    try std.testing.expectEqualStrings(
        get(a, "serialized").?.string,
        get(b, "serialized").?.string,
    );
    try std.testing.expectEqual(Outcome.limit_exceeded, try runCase(arena, a));
    try std.testing.expectEqual(Outcome.invalid, try runCase(arena, b));
}
