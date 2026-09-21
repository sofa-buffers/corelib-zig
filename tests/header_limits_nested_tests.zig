//! The shared `header_limits_nested` cases — the flat `header_limits` block's
//! one untested axis: the identical truncated over-ceiling header delivered
//! **inside an open sequence** (CORELIB_PLAN §6.2.1, §6.3; MESSAGE_SPEC §5.2,
//! §7.1).
//!
//! ```text
//! 3e 02 a2 06   then EOF
//! ^^ id 7, wire type 6 — a sequence OPENS, and is never closed
//!    ^^ id 0, wire type 2 (fixlen), inside that sequence
//!       ^^^^^ length word (100 << 3) | 2  ->  a 100-byte STRING is declared
//!               ... and the message ends. Frame still open, no payload byte.
//! ```
//!
//! Every case in the flat block puts its field at `field_id 0` in the top-level
//! scope, so a port could bind its ceiling to the top level, cap nothing one
//! frame down, and pass the whole block. These bytes are that gap: the ceiling
//! has to be reached through the port's ordinary nested-sequence decode path.
//!
//! **Why this is its own block, and its own file.** The bytes begin with a
//! sequence header, so a runner that ignores `frames` binds its ceiling at the
//! top level and answers `incomplete` where the case demands `limit_exceeded`.
//! The one new key is `frames`: the chain of sequence field ids the target
//! field is nested in, outermost first (`[7]`, `[7, 3]`). Everything else — the
//! key set, the outcome vocabulary, terminality, the pairing of each rejection
//! with an in-ceiling control, SKIP-on-unsatisfied-tag — is inherited from the
//! flat block, and so is the **leaf**: `header_limits_tests.Leaf` is the very
//! read the flat cases run, wrapped here in a frame chain and otherwise
//! untouched. A nested block with a leaf of its own would test the runner's
//! comparison instead of the library's enforcement point.
//!
//! **The negative control is load-bearing here, not a formality.** These cases
//! end with one or two frames still open, so a decoder has a *second,
//! independent* reason to answer `incomplete` — and, symmetrically, any
//! unrelated refusal of an unclosed frame (a depth guard, a strict-mode path)
//! would answer `limit_exceeded`/`invalid` and sail through the forward pass
//! without the ceiling ever being consulted. The control pass at the bottom of
//! this file re-runs every rejection with the *same kind* of ceiling lifted far
//! above `declared` and requires the answer to **change**. Without it, a runner
//! that never reached the ceiling is indistinguishable from one that did.

const std = @import("std");
const sofab = @import("sofab");
/// The flat block's runner: loader, capability gate, `Ceiling`, `Outcome` and —
/// the point — the leaf read itself. Shared, never reimplemented (see above).
const hl = @import("header_limits_tests.zig");

const get = hl.get;
const Outcome = hl.Outcome;
const Ceiling = hl.Ceiling;

/// The block this file runs. Named once.
const BLOCK = "header_limits_nested";

/// The ceiling the negative control substitutes: far above every `declared` in
/// the block (the largest is 100), and small enough that lifting it cannot
/// provoke an allocation worth worrying about.
const LIFTED = 65536;

// ---------------------------------------------------------------------------
// the receiver — the shared leaf, one or two frames down
// ---------------------------------------------------------------------------

/// The visitor generated code emits for a field nested in a sequence chain.
///
/// Declaring `sequenceBegin` is what opts a visitor into nested scopes in this
/// port (`src/istream.zig`): without it the decoder consumes and discards every
/// sub-sequence whole, because each sequence opens a fresh id namespace and a
/// visitor that cannot name the scope could not tell a child's id from an
/// enclosing field's. So the chain bookkeeping below is the port's ordinary
/// descent, not a special path built for this block.
///
/// Off-chain scopes are counted rather than descended into: a sequence whose id
/// is not the next link is still entered by the decoder, and its children must
/// not be mistaken for the leaf.
const Nested = struct {
    /// The read under test — the flat block's, verbatim.
    leaf: hl.Leaf,
    /// `frames`, outermost first.
    frames: []const sofab.Id,
    /// How many links of the chain are currently entered.
    on: usize = 0,
    /// Sequence scopes entered while off the chain, so their ends are matched.
    stray: usize = 0,

    pub fn sequenceBegin(self: *Nested, id: sofab.Id) void {
        if (self.stray == 0 and self.on < self.frames.len and id == self.frames[self.on]) {
            self.on += 1;
        } else {
            self.stray += 1;
        }
    }

    pub fn sequenceEnd(self: *Nested) void {
        if (self.stray > 0) {
            self.stray -= 1;
        } else if (self.on > 0) {
            self.on -= 1;
        }
    }

    /// True only in the innermost frame of the chain — where the case's
    /// `field_id` lives and where the ceiling is bound.
    fn atLeaf(self: *const Nested) bool {
        return self.stray == 0 and self.on == self.frames.len;
    }

    pub fn fixlenBegin(
        self: *Nested,
        id: sofab.Id,
        subtype: sofab.FixlenType,
        total: usize,
    ) sofab.Error!void {
        if (!self.atLeaf()) return;
        return self.leaf.fixlenBegin(id, subtype, total);
    }

    pub fn arrayBegin(
        self: *Nested,
        id: sofab.Id,
        kind: sofab.ArrayKind,
        count: usize,
    ) sofab.Error!void {
        if (!self.atLeaf()) return;
        return self.leaf.arrayBegin(id, kind, count);
    }

    pub fn string(self: *Nested, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        if (!self.atLeaf()) return;
        self.leaf.string(id, total, offset, chunk);
    }

    pub fn blob(self: *Nested, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        if (!self.atLeaf()) return;
        self.leaf.blob(id, total, offset, chunk);
    }
};

// ---------------------------------------------------------------------------
// case plumbing
// ---------------------------------------------------------------------------

fn parseCases(arena: std.mem.Allocator) []const std.json.Value {
    return hl.parseBlock(arena, BLOCK);
}

/// The sequence chain a case names, outermost first. Non-empty by definition —
/// a case with no frames would be a flat case in the wrong block.
fn framesOf(arena: std.mem.Allocator, case: std.json.Value) []const sofab.Id {
    const list = (get(case, "frames") orelse @panic("a `header_limits_nested` case must state `frames`")).array.items;
    if (list.len == 0) @panic("`frames` is empty: the case belongs in `header_limits`");
    const out = arena.alloc(sofab.Id, list.len) catch @panic("OOM");
    for (list, 0..) |f, i| out[i] = @intCast(f.integer);
    return out;
}

fn receiverFor(arena: std.mem.Allocator, case: std.json.Value, ceiling: Ceiling) Nested {
    return .{
        .leaf = .{
            .alloc = arena,
            .field_id = @intCast(get(case, "field_id").?.integer),
            .ceiling = ceiling,
        },
        .frames = framesOf(arena, case),
    };
}

/// Feed one case's bytes verbatim — `chunks` where it states them, else the
/// whole `serialized` in one call — into a receiver built to its frame chain.
/// Nothing is appended and no frame is closed: the truncation *is* the case.
fn feed(
    arena: std.mem.Allocator,
    case: std.json.Value,
    ceiling: Ceiling,
    is: *sofab.IStream,
    r: *Nested,
) Outcome {
    r.* = receiverFor(arena, case, ceiling);
    return hl.feedCase(is, r, hl.chunksOf(arena, case));
}

/// Run one case as the file states it, with every assertion §4 and §7 of the
/// block's specification ask for. Returns the outcome so the caller can count
/// rejections.
fn runCase(arena: std.mem.Allocator, case: std.json.Value) !Outcome {
    const expect = get(case, "expect").?;
    const want = Outcome.parse(get(expect, "outcome").?.string);

    var is = sofab.IStream.init();
    var r: Nested = undefined;
    const got = feed(arena, case, Ceiling.of(case), &is, &r);
    try std.testing.expectEqual(want, got);

    if (want == .incomplete) {
        // The control half of the block: `expect.terminal` is absent precisely
        // because INCOMPLETE is the state more bytes can lift — here doubly so,
        // with a frame open as well as a payload missing.
        try std.testing.expect(get(expect, "terminal") == null);
        return got;
    }

    // Refused, never clamped to the ceiling's own value (§6.2.1).
    try std.testing.expectEqual(@as(usize, 0), r.leaf.taken);

    if (get(expect, "terminal")) |t| {
        try std.testing.expect(t.bool);
        // Terminality is asserted by **feeding bytes**, not by re-reading a
        // stored status: a decoder that would have consumed the payload and
        // moved on looks terminal to a status query and is caught only here.
        // The empty probe is how a caller re-asks where the decoder stands; the
        // second is the real hazard — the payload the header promised, which
        // would complete the field if anything could.
        try hl.expectReRaise(&is, &r, &.{}, got);
        try hl.expectReRaise(&is, &r, "payload!!", got);
        // Checked *after* the further feed, so a late materialization is caught
        // too.
        try std.testing.expectEqual(@as(usize, 0), r.leaf.taken);
    }
    return got;
}

// ---------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------

test "the header_limits_nested block is present, and every case names a frame chain and one ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    // A missing or empty block is a failure, not a skip: this port runs the
    // block, so its absence means the shared asset went stale here.
    try std.testing.expect(cases.len > 0);
    // The generation of the asset that introduced the block carries eight
    // cases — four rejections, each with its in-ceiling control.
    try std.testing.expect(cases.len >= 8);

    var depth2: usize = 0;
    for (cases) |c| {
        const name = get(c, "name").?.string;
        errdefer std.debug.print("nested case [{s}] is malformed\n", .{name});

        // The new key, and the whole point of the block.
        const frames = framesOf(arena, c);
        try std.testing.expect(frames.len > 0);
        if (frames.len >= 2) depth2 += 1;

        // Exactly one ceiling per case — §6.2.1 forbids capping a field the
        // schema already bounds, so a case carrying both would be unrunnable.
        const has_schema = get(c, "schema") != null;
        const has_limits = get(c, "limits") != null;
        try std.testing.expect(has_schema != has_limits);
        _ = Ceiling.of(c);
        // Every tag resolves; an unknown one panics rather than being ignored.
        _ = hl.skipped(c);
        // `terminal` appears only on a rejection: it is the property INCOMPLETE
        // by definition does not have.
        const expect = get(c, "expect").?;
        if (get(expect, "terminal") != null)
            try std.testing.expect(Outcome.parse(get(expect, "outcome").?.string) != .incomplete);
    }
    // Cases 7 and 8 exist because one level may be special-cased; a block that
    // lost them would stop testing the chain builder past its first link.
    try std.testing.expect(depth2 >= 2);
}

test "every rejection in header_limits_nested is paired with an in-ceiling control at the same depth" {
    // The block's own rule, asserted rather than assumed: a port that rejects
    // every short read *inside a sequence* passes all four rejections and is
    // badly broken. A control is the same ceiling — same kind, same value — at
    // the same frame chain, and it must expect `incomplete`.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

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
        const frames = framesOf(arena, c);
        var paired = false;
        for (cases) |o| {
            if (Outcome.parse(get(get(o, "expect").?, "outcome").?.string) != .incomplete) continue;
            if (!std.meta.eql(Ceiling.of(o), ceiling)) continue;
            if (std.mem.eql(sofab.Id, framesOf(arena, o), frames)) paired = true;
        }
        if (!paired) std.debug.print("no in-ceiling control for [{s}]\n", .{get(c, "name").?.string});
        try std.testing.expect(paired);
    }
    try std.testing.expectEqual(@as(usize, 4), rejections);
    try std.testing.expectEqual(@as(usize, 4), controls);
}

test "every header_limits_nested case (§6.2.1, §6.3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var ran: usize = 0;
    var gated: usize = 0;
    var rejected: usize = 0;
    var depth2_ran: usize = 0;
    for (cases) |case| {
        const name = get(case, "name").?.string;
        errdefer std.debug.print("header_limits_nested case [{s}] failed: {s}\n", .{
            name,
            get(case, "description").?.string,
        });
        if (hl.skipped(case)) {
            // Named, with the tag that gated it: a mis-spelled capability or a
            // probe that answers "unsupported" by accident would otherwise turn
            // this runner into a green no-op.
            gated += 1;
            for ((get(case, "requires") orelse continue).array.items) |r| {
                if (!hl.Capability.parse(r.string).supported())
                    std.debug.print("[header_limits_nested] gated [{s}] on `{s}`\n", .{ name, r.string });
            }
            continue;
        }
        if (try runCase(arena, case) != .incomplete) rejected += 1;
        if (framesOf(arena, case).len >= 2) depth2_ran += 1;
        ran += 1;
    }
    try std.testing.expectEqual(cases.len, ran + gated);
    // Nothing in this build compiles sequences, fixlen fields or arrays out,
    // and the port carries §6.2.1 receiver caps distinct from schema bounds
    // (`receiver_caps`), so every case runs.
    try std.testing.expectEqual(@as(usize, 0), gated);
    try std.testing.expectEqual(@as(usize, 4), rejected);
    // …and the depth-2 pair is among what ran, rather than silently mishandled.
    try std.testing.expect(depth2_ran >= 2);
    std.debug.print(
        "\n[header_limits_nested] {d} cases run ({d} rejections, {d} in-ceiling controls, {d} at depth 2), {d} skipped by `requires`\n",
        .{ ran, rejected, ran - rejected, depth2_ran, gated },
    );
}

test "the schema bound and the receiver cap stay apart on identical nested bytes" {
    // The pair the block turns on: `nested_string_over_cap` and
    // `nested_string_schema_bounded` carry the **same bytes** at the **same
    // depth** and differ only in which ceiling the case configures. A port that
    // routes both into one rejection category passes the other seven cases.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    var capped: ?std.json.Value = null;
    var bounded: ?std.json.Value = null;
    for (cases) |c| {
        const name = get(c, "name").?.string;
        if (std.mem.eql(u8, name, "nested_string_over_cap")) capped = c;
        if (std.mem.eql(u8, name, "nested_string_schema_bounded")) bounded = c;
    }
    const a = capped orelse @panic("nested_string_over_cap missing from the block");
    const b = bounded orelse @panic("nested_string_schema_bounded missing from the block");

    try std.testing.expectEqualStrings(
        get(a, "serialized").?.string,
        get(b, "serialized").?.string,
    );
    try std.testing.expectEqualSlices(
        sofab.Id,
        framesOf(arena, a),
        framesOf(arena, b),
    );
    try std.testing.expectEqual(Outcome.limit_exceeded, try runCase(arena, a));
    try std.testing.expectEqual(Outcome.invalid, try runCase(arena, b));
}

test "negative control: lifting the ceiling changes every nested rejection" {
    // MANDATORY, and the only assertion in this file that can tell "the ceiling
    // fired" from "something else refused an unclosed frame". Each rejection is
    // re-run with the **same kind** of ceiling raised far above `declared` —
    // a schema case gets a lifted schema bound, a cap case a lifted cap, never
    // both — and the answer must no longer be the case's rejection.
    //
    // Inequality, not equality against `incomplete`: what the control proves is
    // that the ceiling *caused* the rejection, not what the alternative answer
    // happens to be. (It is `incomplete` here, because a frame is open — which
    // is exactly the plausible-looking answer that makes this block worth
    // having.)
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = parseCases(arena);

    // Counted independently of the loop below, so a control pass that silently
    // examines nothing — a `continue` that matches everything — cannot pass.
    var admitted_rejections: usize = 0;
    for (cases) |c| {
        if (hl.skipped(c)) continue;
        if (Outcome.parse(get(get(c, "expect").?, "outcome").?.string) != .incomplete)
            admitted_rejections += 1;
    }

    var checked: usize = 0;
    for (cases) |case| {
        if (hl.skipped(case)) continue;
        const name = get(case, "name").?.string;
        const want = Outcome.parse(get(get(case, "expect").?, "outcome").?.string);
        // Only a rejection can be shown to depend on its ceiling.
        if (want == .incomplete) continue;
        // No case in this block declares a size the lifted ceiling would not
        // admit (the flat block's 1 GiB amplification case is the one that
        // cannot be lifted past, and it has no counterpart here) — so this
        // pass covers every rejection, with no exemption.
        const declared: usize = @intCast(get(case, "declared").?.integer);
        try std.testing.expect(declared < LIFTED);

        errdefer std.debug.print("negative control for [{s}] failed\n", .{name});
        var is = sofab.IStream.init();
        var r: Nested = undefined;
        const got = feed(arena, case, Ceiling.of(case).lifted(LIFTED), &is, &r);
        if (got == want) std.debug.print(
            "[{s}] still answers {s} with the ceiling lifted to {d}: the rejection did not come from the ceiling\n",
            .{ name, @tagName(got), LIFTED },
        );
        try std.testing.expect(got != want);
        checked += 1;
    }

    try std.testing.expectEqual(admitted_rejections, checked);
    // Four rejections in the block, all four controllable.
    try std.testing.expect(checked >= 4);
    std.debug.print(
        "\n[header_limits_nested] negative control: {d} rejections re-run with the ceiling lifted to {d}, all changed answer\n",
        .{ checked, LIFTED },
    );
}
