//! CORELIB_ZIG-01 — a receiver-cap refusal is **terminal**, and the decoder
//! must say so afterwards.
//!
//! CORELIB_PLAN §6.3 puts `LimitExceeded` in the error table as "a **terminal**,
//! receiver-local **policy** rejection", and states two paragraphs down that it
//! "**terminates** a decode on *well-formed* input". It leaves the *surfacing*
//! open — "either a **fourth decode outcome**, or a **terminal failure** carrying
//! the `LimitExceeded` code on the error channel" — but not the terminality, and
//! not the code: "Either way it **MUST NOT** be reported as `InvalidMessage`."
//!
//! What terminal costs the decoder is exactly what §5.2.1 costs it for `INVALID`
//! ("regardless of what follows … no — terminal") and what `src/istream.zig`
//! already implements for `error.InvalidMessage`: the verdict is latched, so the
//! status accessor keeps reporting it and a further `feed` repeats it instead of
//! resynchronizing on the bytes that follow the refused construct. §5.2.3's
//! ordering ("a decoder **MUST NOT** report `INCOMPLETE` for input it has already
//! determined malformed") sets the floor these tests measure against: answering
//! `COMPLETE` about bytes the decoder itself just refused is further still from
//! the required verdict than the `INCOMPLETE` that clause forbids.
//!
//! The property that makes this critical is not the status word. A decoder that
//! keeps answering after a terminal refusal re-enters header parsing at a
//! position the byte stream no longer has, and the refused field's **payload**
//! is then read as field headers: the visitor is handed fields the sender never
//! wrote. So these tests assert on the delivered **events**, not only on the
//! status — and they assert it for the message fed whole and fed one byte at a
//! time alike, since a verdict that depends on where the chunk boundaries fell
//! is the divergence MESSAGE_SPEC §7.2 item 4 forbids.

const std = @import("std");
const sofab = @import("sofab");
const common = @import("common.zig");

const Event = common.Event;

/// The receiver's cap, and deliberately tiny: every fixlen field below is
/// longer, so `fixlenBegin` refuses each one. `fixlenBegin` is this port's only
/// fallible visitor callback, hence the only way a receiver cap can be reported
/// *through* the corelib at all (`src/istream.zig:488`).
const cap: usize = 1;

/// A recording visitor that refuses any fixlen field longer than `cap` with the
/// §6.3 policy code. It declares every callback, so anything the decoder decides
/// to deliver is recorded — which is the point: the events are the evidence.
const CappingRecorder = struct {
    rec: common.Recorder,
    /// How many times the cap actually fired. A fix that surfaces the rejection
    /// as a fourth *outcome* rather than on the error channel raises no error at
    /// all, so the tests below read this to know a refusal happened.
    refusals: usize = 0,

    pub fn init(arena: std.mem.Allocator) CappingRecorder {
        return .{ .rec = common.Recorder.init(arena) };
    }
    pub fn events(self: *const CappingRecorder) []const Event {
        return self.rec.events.items;
    }

    pub fn fixlenBegin(self: *CappingRecorder, _: sofab.Id, _: sofab.FixlenType, total: usize) sofab.Error!void {
        if (total > cap) {
            self.refusals += 1;
            return sofab.Error.LimitExceeded;
        }
    }

    pub fn unsigned(self: *CappingRecorder, id: sofab.Id, value: u64) void {
        self.rec.unsigned(id, value);
    }
    pub fn signed(self: *CappingRecorder, id: sofab.Id, value: i64) void {
        self.rec.signed(id, value);
    }
    pub fn fp32(self: *CappingRecorder, id: sofab.Id, value: f32) void {
        self.rec.fp32(id, value);
    }
    pub fn fp64(self: *CappingRecorder, id: sofab.Id, value: f64) void {
        self.rec.fp64(id, value);
    }
    pub fn string(self: *CappingRecorder, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        self.rec.string(id, total, offset, chunk);
    }
    pub fn blob(self: *CappingRecorder, id: sofab.Id, total: usize, offset: usize, chunk: []const u8) void {
        self.rec.blob(id, total, offset, chunk);
    }
    pub fn arrayBegin(self: *CappingRecorder, id: sofab.Id, kind: sofab.ArrayKind, count: usize) void {
        self.rec.arrayBegin(id, kind, count);
    }
    pub fn sequenceBegin(self: *CappingRecorder, id: sofab.Id) void {
        self.rec.sequenceBegin(id);
    }
    pub fn sequenceEnd(self: *CappingRecorder) void {
        self.rec.sequenceEnd();
    }
};

/// §6.3 leaves the *surfacing* of the terminal rejection open, so this accepts
/// either shape: any outcome that is not `COMPLETE` and not `INCOMPLETE` — a
/// fourth decode outcome, or the `.invalid`-style latched verdict — passes.
/// `.complete` and `.incomplete` are the two answers the clause rules out: both
/// say "the bytes so far are fine, keep going" about a field the decoder refused.
fn expectTerminalStatus(where: []const u8, st: sofab.Status) !void {
    switch (st) {
        .complete, .incomplete => {
            std.debug.print(
                "{s}: status is .{s} after a LimitExceeded refusal; " ++
                    "CORELIB_PLAN §6.3 calls that rejection terminal\n",
                .{ where, @tagName(st) },
            );
            return error.TestUnexpectedResult;
        },
        else => {},
    }
}

/// A `feed` made *after* the refusal. It must re-report the terminal verdict —
/// on the error channel with the `LimitExceeded` code (never `InvalidMessage`,
/// §6.3), or as a non-COMPLETE/non-INCOMPLETE outcome — and never resume decoding.
fn expectTerminalFeed(where: []const u8, is: *sofab.IStream, chunk: []const u8, v: *CappingRecorder) !void {
    const st = is.feed(chunk, v) catch |e| {
        if (e != error.LimitExceeded) {
            std.debug.print("{s}: feed after the refusal raised {s}; §6.3 requires LimitExceeded\n", .{ where, @errorName(e) });
            return error.TestUnexpectedResult;
        }
        return;
    };
    try expectTerminalStatus(where, st);
}

/// Feed `msg` in `chunk`-byte pieces, refusing every fixlen field over `cap`,
/// and return once the whole message has been offered. Feeds made before the
/// refusal are ordinary; every feed after it must already be terminal.
fn feedRefusing(is: *sofab.IStream, v: *CappingRecorder, msg: []const u8, chunk: usize) !void {
    var i: usize = 0;
    while (i < msg.len) : (i += chunk) {
        const piece = msg[i..@min(i + chunk, msg.len)];
        if (v.refusals > 0) {
            try expectTerminalFeed("feed after the refusal", is, piece, v);
            continue;
        }
        const st = is.feed(piece, v) catch |e| {
            if (e != error.LimitExceeded) return e;
            continue;
        };
        // No error: either nothing was refused yet, or this port surfaces the
        // rejection as an outcome instead — in which case it must be terminal.
        if (v.refusals > 0) try expectTerminalStatus("the refusing feed", st);
    }
}

// CORELIB_ZIG-01 (a)+(b)+(c) at top level.
// Pins CORELIB_PLAN §6.3 — `LimitExceeded` is "a terminal, receiver-local policy
// rejection" that "terminates a decode" — read with §5.2.1 (a terminal verdict is
// "regardless of what follows") and §5.2.3 (a decoder must not report a
// keep-going outcome about input it has already refused).
test "CORELIB_ZIG-01: a LimitExceeded refusal is terminal — the status holds, a further feed does not resume, and no field the sender never wrote is delivered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // header (1 << 3) | 2 = 0x0a → id 1, fixlen; word (2 << 3) | 2 = 0x12 → a
    // 2-byte `string`; then its payload, "hi". The payload is chosen so the
    // resynchronisation is visible rather than silent: read as field headers,
    // 'h' = 0x68 is (13 << 3) | 0 → an unsigned field at id 13, and 'i' = 0x69
    // is its value, 105. That fabricated `unsigned(13, 105)` is the field the
    // sender never wrote, and it is what makes this critical rather than cosmetic.
    const msg = [_]u8{ 0x0a, 0x12, 'h', 'i' };
    const payload = msg[2..];

    // The same bytes, fed whole and fed in pieces: §7.2 item 4 requires the two
    // paths to agree, so every assertion below is made for each split.
    for ([_]usize{ msg.len, 2, 1 }) |chunk| {
        var v = CappingRecorder.init(arena.allocator());
        var is = sofab.IStream.init();

        try feedRefusing(&is, &v, &msg, chunk);
        try std.testing.expectEqual(@as(usize, 1), v.refusals);

        // (a) the status accessor still reports the terminal verdict.
        try expectTerminalStatus("status after the refusal", is.status());

        // (b) a further feed re-reports it instead of decoding more — an empty
        //     end-of-input probe and real bytes alike. Feeding the refused
        //     field's own payload is the caller behaviour the port documents as
        //     legitimate ("must not poison the decoder", src/istream.zig:286-290).
        try expectTerminalFeed("empty end-of-input probe", &is, &.{}, &v);
        try expectTerminalFeed("feed of the refused payload", &is, payload, &v);
        try expectTerminalStatus("status after the further feeds", is.status());

        // (c) and nothing reached the visitor. The sender wrote one field; the
        //     decoder refused it; therefore no event at all is the only correct
        //     event list, at every chunk size.
        try common.expectEventsEqual(&.{}, v.events());
    }
}

// CORELIB_ZIG-01, the same defect one scope down (the general pass's GEN-07):
// the refusal happens after `parse` has already opened a sequence, so the
// decoder's depth has moved while its byte position has not been recorded.
// Same clauses: §6.3 terminal, §5.2.3 no keep-going outcome after a refusal.
test "CORELIB_ZIG-01: a LimitExceeded refusal inside a sequence is terminal too — the open scope does not turn it into INCOMPLETE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // (1 << 3) | 6 = 0x0e → sequence start, id 1. (3 << 3) | 2 = 0x1a → id 3,
    // fixlen; (10 << 3) | 2 = 0x52 → a 10-byte `string`, refused at the cap.
    // The ten payload bytes then read as field headers inside a scope whose
    // position in the byte stream no longer exists: '0' = 0x30 is (6 << 3) | 0,
    // an unsigned field at id 6 taking '1' = 0x31 = 49 as its value, and so on.
    const msg = [_]u8{ 0x0e, 0x1a, 0x52 } ++ "0123456789".*;
    const payload = msg[3..];

    // The only event the sender actually wrote before the refusal.
    const want = [_]Event{.{ .sequence_begin = .{ .id = 1 } }};

    for ([_]usize{ msg.len, 3, 1 }) |chunk| {
        var v = CappingRecorder.init(arena.allocator());
        var is = sofab.IStream.init();

        try feedRefusing(&is, &v, &msg, chunk);
        try std.testing.expectEqual(@as(usize, 1), v.refusals);

        // (a) an open sequence must not downgrade the terminal verdict to
        //     INCOMPLETE: §5.2.3 forbids a keep-going outcome about refused input.
        try expectTerminalStatus("status after the refusal in a sequence", is.status());

        // (b) no resumption inside the desynchronised scope.
        try expectTerminalFeed("empty end-of-input probe", &is, &.{}, &v);
        try expectTerminalFeed("feed of the refused payload", &is, payload, &v);
        try expectTerminalStatus("status after the further feeds", is.status());

        // (c) the scope's own `sequenceBegin` stands; nothing else does.
        try common.expectEventsEqual(&want, v.events());
    }
}
