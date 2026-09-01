//! Shared test helpers: a recording visitor and small byte utilities for
//! crafting and comparing wire messages.

const std = @import("std");
const sofab = @import("sofab");

pub const Id = sofab.Id;

/// One decoded event, recorded in order by `Recorder`.
pub const Event = union(enum) {
    unsigned: struct { id: Id, value: u64 },
    signed: struct { id: Id, value: i64 },
    /// Floats stored as raw bits so comparisons are exact (incl. NaN payloads).
    fp32: struct { id: Id, bits: u32 },
    fp64: struct { id: Id, bits: u64 },
    str: struct { id: Id, data: []const u8 },
    blob: struct { id: Id, data: []const u8 },
    array_begin: struct { id: Id, kind: sofab.ArrayKind, count: usize },
    sequence_begin: struct { id: Id },
    sequence_end,

    pub fn eql(a: Event, b: Event) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .unsigned => |x| x.id == b.unsigned.id and x.value == b.unsigned.value,
            .signed => |x| x.id == b.signed.id and x.value == b.signed.value,
            .fp32 => |x| x.id == b.fp32.id and x.bits == b.fp32.bits,
            .fp64 => |x| x.id == b.fp64.id and x.bits == b.fp64.bits,
            .str => |x| x.id == b.str.id and std.mem.eql(u8, x.data, b.str.data),
            .blob => |x| x.id == b.blob.id and std.mem.eql(u8, x.data, b.blob.data),
            .array_begin => |x| x.id == b.array_begin.id and
                x.kind == b.array_begin.kind and x.count == b.array_begin.count,
            .sequence_begin => |x| x.id == b.sequence_begin.id,
            .sequence_end => true,
        };
    }
};

pub fn expectEventsEqual(want: []const Event, got: []const Event) !void {
    errdefer std.debug.print("expected {d} events, got {d}\n", .{ want.len, got.len });
    try std.testing.expectEqual(want.len, got.len);
    for (want, got, 0..) |w, g, i| {
        if (!w.eql(g)) {
            std.debug.print("event {d} mismatch:\n  want {any}\n  got  {any}\n", .{ i, w, g });
            return error.TestExpectedEqual;
        }
    }
}

/// A visitor that records every decoded field as an `Event`, reassembling
/// chunked string/blob payloads into whole buffers (arena-allocated).
pub const Recorder = struct {
    arena: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    // in-progress chunked string/blob accumulator
    pending: ?struct { id: Id, is_blob: bool, data: []u8 } = null,

    pub fn init(arena: std.mem.Allocator) Recorder {
        return .{ .arena = arena };
    }

    fn push(self: *Recorder, e: Event) void {
        self.events.append(self.arena, e) catch @panic("oom");
    }

    fn accumulate(self: *Recorder, id: Id, is_blob: bool, total: usize, offset: usize, chunk: []const u8) void {
        if (offset == 0) {
            self.pending = .{
                .id = id,
                .is_blob = is_blob,
                .data = self.arena.alloc(u8, total) catch @panic("oom"),
            };
        }
        const p = &self.pending.?;
        @memcpy(p.data[offset..][0..chunk.len], chunk);
        if (offset + chunk.len == total) {
            self.push(if (p.is_blob)
                .{ .blob = .{ .id = p.id, .data = p.data } }
            else
                .{ .str = .{ .id = p.id, .data = p.data } });
            self.pending = null;
        }
    }

    pub fn unsigned(self: *Recorder, id: Id, value: u64) void {
        self.push(.{ .unsigned = .{ .id = id, .value = value } });
    }
    pub fn signed(self: *Recorder, id: Id, value: i64) void {
        self.push(.{ .signed = .{ .id = id, .value = value } });
    }
    pub fn fp32(self: *Recorder, id: Id, value: f32) void {
        self.push(.{ .fp32 = .{ .id = id, .bits = @bitCast(value) } });
    }
    pub fn fp64(self: *Recorder, id: Id, value: f64) void {
        self.push(.{ .fp64 = .{ .id = id, .bits = @bitCast(value) } });
    }
    pub fn string(self: *Recorder, id: Id, total: usize, offset: usize, chunk: []const u8) void {
        self.accumulate(id, false, total, offset, chunk);
    }
    pub fn blob(self: *Recorder, id: Id, total: usize, offset: usize, chunk: []const u8) void {
        self.accumulate(id, true, total, offset, chunk);
    }
    pub fn arrayBegin(self: *Recorder, id: Id, kind: sofab.ArrayKind, count: usize) void {
        self.push(.{ .array_begin = .{ .id = id, .kind = kind, .count = count } });
    }
    pub fn sequenceBegin(self: *Recorder, id: Id) void {
        self.push(.{ .sequence_begin = .{ .id = id } });
    }
    pub fn sequenceEnd(self: *Recorder) void {
        self.push(.sequence_end);
    }
};

/// A callback kind a visitor can decline to declare — the *only* way a
/// receiver in this port refuses a field, since a duck-typed visitor has no
/// per-id decline API. `array` names `arrayBegin` (the header hook; the
/// elements still arrive through the scalar callbacks), `sequence` names the
/// `sequenceBegin`/`sequenceEnd` pair.
pub const Callback = enum { unsigned, signed, fp32, fp64, string, blob, array, sequence };

/// A recording visitor that declares every callback **except** the one named by
/// `omit`.
///
/// This is what makes the decoder do the skipping. `IStream` dispatches through
/// `@hasDecl`, so a missing callback means the decoder still parses the field's
/// bytes — its length word, its element count, its whole sub-sequence — and
/// then discards them instead of delivering them (CORELIB_PLAN §5.2). Every
/// field that follows is therefore read from an offset the skip computed, which
/// is exactly the property the shared suite's `skip_ids` vectors are built to
/// check.
///
/// The distinction against `SkipRecorder` matters: that one receives everything
/// and drops what it does not want, so it exercises decoding, not skipping.
/// This one never receives the field at all.
///
/// Each arm is written out rather than generated: a Zig struct cannot declare a
/// method conditionally, and the *absence* of the declaration is the whole
/// signal, so every omission has to be its own type.
pub fn Declining(comptime omit: Callback) type {
    return switch (omit) {
        .unsigned => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .signed => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .fp32 => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .fp64 => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .string => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .blob => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .array => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn sequenceBegin(self: *@This(), id: Id) void {
                self.rec.sequenceBegin(id);
            }
            pub fn sequenceEnd(self: *@This()) void {
                self.rec.sequenceEnd();
            }
        },
        .sequence => struct {
            rec: Recorder,

            pub fn init(arena: std.mem.Allocator) @This() {
                return .{ .rec = Recorder.init(arena) };
            }
            pub fn events(self: *const @This()) []const Event {
                return self.rec.events.items;
            }
            pub fn unsigned(self: *@This(), id: Id, value: u64) void {
                self.rec.unsigned(id, value);
            }
            pub fn signed(self: *@This(), id: Id, value: i64) void {
                self.rec.signed(id, value);
            }
            pub fn fp32(self: *@This(), id: Id, value: f32) void {
                self.rec.fp32(id, value);
            }
            pub fn fp64(self: *@This(), id: Id, value: f64) void {
                self.rec.fp64(id, value);
            }
            pub fn string(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.string(id, total, offset, chunk);
            }
            pub fn blob(self: *@This(), id: Id, total: usize, offset: usize, chunk: []const u8) void {
                self.rec.blob(id, total, offset, chunk);
            }
            pub fn arrayBegin(self: *@This(), id: Id, kind: sofab.ArrayKind, count: usize) void {
                self.rec.arrayBegin(id, kind, count);
            }
        },
    };
}

/// A receiver that knows only flat fields and therefore cannot descend into a
/// nested scope: everything inside a sequence must be auto-skipped by the
/// decoder (CORELIB_PLAN §5.2/§6), so this visitor may only ever record the
/// *top-level* fields of a message.
pub const FlatRecorder = Declining(.sequence);

/// A visitor modelling a receiver that ignores a set of field `skip_ids`.
/// Scalars/arrays with a skipped id are dropped; a skipped `sequenceBegin`
/// drops the whole nested sequence by tracking depth until the matching end.
///
/// **This is an event filter, not a skip.** It declares every callback, so the
/// decoder hands it every field and it discards the ones whose id it was told
/// to ignore — which proves those fields *decode*, not that anything was
/// skipped. It is here because the shared vectors state their skip set as ids
/// and this is the only way a visitor can express an id set at all. The
/// decoder's own skip path is driven by `Declining` instead, and the shared
/// vector suite runs both over every `skip_ids` vector.
pub const SkipRecorder = struct {
    rec: Recorder,
    skip: []const Id,
    depth: u32 = 0,
    skip_until: ?u32 = null,

    pub fn init(arena: std.mem.Allocator, skip: []const Id) SkipRecorder {
        return .{ .rec = Recorder.init(arena), .skip = skip };
    }

    pub fn events(self: *const SkipRecorder) []const Event {
        return self.rec.events.items;
    }

    fn skipping(self: *const SkipRecorder) bool {
        return self.skip_until != null;
    }

    fn dropId(self: *const SkipRecorder, id: Id) bool {
        return self.skipping() or std.mem.indexOfScalar(Id, self.skip, id) != null;
    }

    pub fn unsigned(self: *SkipRecorder, id: Id, value: u64) void {
        if (!self.dropId(id)) self.rec.unsigned(id, value);
    }
    pub fn signed(self: *SkipRecorder, id: Id, value: i64) void {
        if (!self.dropId(id)) self.rec.signed(id, value);
    }
    pub fn fp32(self: *SkipRecorder, id: Id, value: f32) void {
        if (!self.dropId(id)) self.rec.fp32(id, value);
    }
    pub fn fp64(self: *SkipRecorder, id: Id, value: f64) void {
        if (!self.dropId(id)) self.rec.fp64(id, value);
    }
    pub fn string(self: *SkipRecorder, id: Id, total: usize, offset: usize, chunk: []const u8) void {
        if (!self.dropId(id)) self.rec.string(id, total, offset, chunk);
    }
    pub fn blob(self: *SkipRecorder, id: Id, total: usize, offset: usize, chunk: []const u8) void {
        if (!self.dropId(id)) self.rec.blob(id, total, offset, chunk);
    }
    pub fn arrayBegin(self: *SkipRecorder, id: Id, kind: sofab.ArrayKind, count: usize) void {
        // Array elements arrive via the scalar/float callbacks with this id, so
        // a skipped id drops them too — only the header is handled here.
        if (!self.dropId(id)) self.rec.arrayBegin(id, kind, count);
    }
    pub fn sequenceBegin(self: *SkipRecorder, id: Id) void {
        if (!self.skipping()) {
            if (std.mem.indexOfScalar(Id, self.skip, id) != null) {
                self.skip_until = self.depth;
            } else {
                self.rec.sequenceBegin(id);
            }
        }
        self.depth += 1;
    }
    pub fn sequenceEnd(self: *SkipRecorder) void {
        self.depth -= 1;
        if (self.skip_until) |d| {
            if (d == self.depth) self.skip_until = null;
        } else {
            self.rec.sequenceEnd();
        }
    }
};

/// A fixed-capacity flush sink: it concatenates the chunks an `OStream` drains
/// into it, so a streamed encode can be compared byte for byte against the
/// one-shot bytes. `capacity` must exceed the message under test.
pub fn Collector(comptime capacity: usize) type {
    return struct {
        data: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn push(ctx: ?*anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            // Loud on overflow, in every optimize mode: a release build would
            // otherwise scribble past the array and the comparison downstream
            // would report a byte mismatch instead of "the sink is too small".
            if (self.len + chunk.len > capacity) @panic("Collector capacity exceeded — raise it, never drop bytes");
            @memcpy(self.data[self.len..][0..chunk.len], chunk);
            self.len += chunk.len;
        }

        /// Everything drained so far, in order.
        pub fn bytes(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };
}

pub fn hexToBytes(arena: std.mem.Allocator, hex: []const u8) []u8 {
    const out = arena.alloc(u8, hex.len / 2) catch @panic("oom");
    return std.fmt.hexToBytes(out, hex) catch @panic("bad hex in test data");
}

/// Append a base-128 varint of `value` to `out` (for crafting raw test inputs).
pub fn pushVarint(out: *std.ArrayList(u8), arena: std.mem.Allocator, value: u64) void {
    var v = value;
    while (true) {
        var b: u8 = @as(u8, @truncate(v)) & 0x7F;
        v >>= 7;
        if (v != 0) b |= 0x80;
        out.append(arena, b) catch @panic("oom");
        if (v == 0) return;
    }
}
