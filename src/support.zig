//! The types a generated message layer holds: the storage of a `count: N` array
//! field, the sink behind a one-shot `encode()`, and the accumulator behind a
//! payload split across feed chunks.
//!
//! Like the helpers in `arrays.zig`, none of them carry schema knowledge — the
//! capacity is a type parameter, the allocator and the payload length are
//! arguments — so their code has the same shape for every schema. That is what
//! makes them library types rather than emitted ones (ARCHITECTURE §8): a copy
//! per generated module is a copy that drifts, and the rationale for each
//! decision here would have to be re-emitted into every user's source tree
//! alongside it.
//!
//! CORELIB_PLAN §5.1 draws the line these types sit on. The generated layer
//! allocates and the corelib does not, so nothing here allocates on its own
//! initiative: every allocation is made through an allocator the caller passes
//! in, at a moment the caller chooses. What moves into the library is the
//! mechanism; which buffer, which allocator, and whether to stream at all stay
//! with the generated layer.

const std = @import("std");

/// Storage for a `count: N` native array field: `N` elements of inline
/// capacity, plus the length actually carried.
///
/// `count` is a **capacity**, never a length (MESSAGE_SPEC §3): the field holds
/// `0..N` elements and the wire count `M` *is* the length, so a bare `[N]T` —
/// which can only ever *be* `N` long — cannot represent the value. This can,
/// without giving up the inline storage that keeps a bounded array
/// allocation-free on both encode and decode.
///
/// The value is `slice()`; the storage past it is spare capacity and never
/// reaches the wire. `.{}` is the **empty** array — which is what a fresh
/// `count: N` field is: `N` is a bound, not a content.
///
/// ```zig
/// var levels: sofab.FixedArray(u32, 4) = .init(&.{ 10, 20 });
/// try os.writeArrayUnsigned(9, levels.slice()); // writes 2 elements, not 4
/// ```
///
/// **The storage is not the API.** `_items` and `_len` carry the leading
/// underscore Zig has in place of access control: a value is built with
/// `init`/`set` and filled by a decoder with `clear`/`push`, so the length can
/// never be left disagreeing with the elements. Generated code used to spell
/// both out by hand — `.{ .items = .{ 10, 20, 0, 0 }, .len = 2 }`, zero padding
/// included — and corelib-cpp removed exactly that shape after an aggregate
/// `v = {a, b, c}` filled the storage, left the length at `0`, and encoded the
/// field as empty.
pub fn FixedArray(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        /// The element type, for a caller holding only the array type.
        pub const Elem = T;
        /// The schema `count`: the most elements this field may carry.
        pub const capacity: usize = N;

        /// Inline storage. Not API — see the type's note; `_items[_len..]` is
        /// spare capacity and holds whatever a previous value left there.
        _items: [N]T = std.mem.zeroes([N]T),
        /// Number of elements the value carries. Not API — `len()` reads it.
        _len: usize = 0,

        /// A value holding `vals`, truncated to the capacity `N`. Evaluable at
        /// comptime, so it is also the form a declared default takes:
        /// `levels: FixedArray(u32, 4) = .init(&.{ 10, 20 })`.
        pub fn init(vals: []const T) Self {
            var self: Self = .{};
            self.set(vals);
            return self;
        }

        /// The array's value: exactly the elements the wire carries.
        pub fn slice(self: *const Self) []const T {
            return self._items[0..self._len];
        }

        /// How many elements the value carries — never the capacity `N`.
        pub fn len(self: *const Self) usize {
            return self._len;
        }

        /// Replace the value with `vals`, truncated to the capacity `N`.
        pub fn set(self: *Self, vals: []const T) void {
            const n = @min(vals.len, N);
            @memcpy(self._items[0..n], vals[0..n]);
            self._len = n;
        }

        /// Drop every element, keeping the capacity: what a decoder does when
        /// an array header for this field arrives, before its elements do.
        pub fn clear(self: *Self) void {
            self._len = 0;
        }

        /// Store the next decoded element, flagging `inv` when it does not fit.
        ///
        /// An element past the capacity `N` makes the message malformed: a wire
        /// count above the schema `count` is `INVALID` and must be rejected,
        /// never clamped (MESSAGE_SPEC §7.1). This is `arrays.putChecked` for a
        /// destination that carries its own index.
        pub fn push(self: *Self, v: T, inv: *bool) void {
            if (self._len >= N) {
                inv.* = true;
                return;
            }
            self._items[self._len] = v;
            self._len += 1;
        }
    };
}

/// Flush sink behind a one-shot `encode()`: drains an `OStream`'s scratch
/// buffer into a growable byte list.
///
/// This is the **unbounded-schema** shape of CORELIB_PLAN §5.1 — a scratch
/// buffer installed *with* a sink, because there `MAX_SIZE` is a configured
/// ceiling rather than a size the message cannot reach, and sizing from it
/// would truncate a larger message. The bounded shape needs no sink at all:
/// allocate `MAX_SIZE`, install it with `OStream.init`, encode in one pass.
///
/// The corelib still allocates no output buffer of its own: the caller
/// constructs the sink with its own allocator and hands it over like any other
/// flush target.
///
/// ```zig
/// var sink: sofab.CollectingSink = .{ .alloc = alloc };
/// defer sink.deinit();
/// var scratch: [512]u8 = undefined;
/// var os = sofab.OStream.initFlush(&scratch, 0, &sink, sofab.CollectingSink.push);
/// try value.serialize(&os);
/// _ = os.flush();
/// const message = try sink.toOwnedSlice();
/// ```
pub const CollectingSink = struct {
    /// Allocator the collected bytes come from — the caller's, always.
    alloc: std.mem.Allocator,
    /// The bytes collected so far. A prefix of the message while the encode is
    /// still running, and after a failed drain.
    list: std.ArrayList(u8) = .empty,
    /// Set when a drain could not be stored. A flush callback has no way to
    /// report an error — the encoder is told where bytes go, not whether they
    /// arrived — so the failure is recorded here and read once at the end
    /// instead of after every drain.
    failed: bool = false,

    /// The `FlushFn` to install. `ctx` is the sink itself:
    /// `OStream.initFlush(&scratch, 0, &sink, CollectingSink.push)`.
    pub fn push(ctx: ?*anyopaque, data: []const u8) void {
        const self: *CollectingSink = @ptrCast(@alignCast(ctx.?));
        self.list.appendSlice(self.alloc, data) catch {
            self.failed = true;
        };
    }

    /// Hand the collected message to the caller, who then owns it.
    ///
    /// A lost drain reports `error.OutOfMemory` rather than returning the bytes
    /// that did fit: what is left is a *prefix* of the message, and returning
    /// partial output as if it were complete is what §5.1 forbids an encode
    /// path to do. The sink is left empty either way, so a `deinit` after this
    /// call is safe and frees nothing.
    pub fn toOwnedSlice(self: *CollectingSink) std.mem.Allocator.Error![]u8 {
        if (self.failed) {
            self.list.clearAndFree(self.alloc);
            return error.OutOfMemory;
        }
        return self.list.toOwnedSlice(self.alloc);
    }

    /// Release the collected bytes. Unnecessary after a successful
    /// `toOwnedSlice`, and free under an arena — but the sink of an encode that
    /// failed midway still holds a buffer.
    pub fn deinit(self: *CollectingSink) void {
        self.list.deinit(self.alloc);
    }
};

/// Accumulator for one `string`/`blob` payload that arrives in pieces.
///
/// A decode destination wants one contiguous payload, whatever the feed
/// chunking was. On the one-shot path a payload always arrives whole and the
/// caller borrows it directly; this is the other case — the chunk boundary that
/// splits a payload in two — and it holds the pieces until the announced
/// `total` has arrived.
///
/// The completed payload is handed back as its **own** allocation, never as a
/// view into this buffer. A destination *keeps* the slice it is given — a
/// wrapper-array element outlives the callback that placed it — while this
/// buffer is scratch that the next split payload clears, appends to, and may
/// reallocate. A view into it would alias every payload stored earlier onto the
/// newest one, and a growing buffer would rebase them onto the old block: a
/// stale length past the live bytes, and a freed read under an allocator that
/// releases.
pub const PayloadAcc = struct {
    /// The pieces of the payload being assembled. Not API: the completed
    /// payload leaves through `push`, as its own allocation.
    _buf: std.ArrayList(u8) = .empty,

    /// Take the next chunk of a payload `total` bytes long, starting `offset`
    /// bytes into it. Returns `null` while the payload is still incomplete, and
    /// on the chunk that completes it the whole payload, freshly allocated and
    /// owned by the caller.
    ///
    /// `offset == 0` starts a new payload and drops whatever the previous one
    /// left behind: the capacity is kept, the bytes are not.
    ///
    /// Both allocations come from `a`. The scratch is reused for every payload
    /// and released by `deinit`; an arena — what generated code passes here —
    /// frees it together with the message it belongs to.
    pub fn push(
        self: *PayloadAcc,
        a: std.mem.Allocator,
        total: usize,
        offset: usize,
        chunk: []const u8,
    ) std.mem.Allocator.Error!?[]const u8 {
        if (offset == 0) self._buf.clearRetainingCapacity();
        try self._buf.appendSlice(a, chunk);
        if (self._buf.items.len < total) return null;
        return try a.dupe(u8, self._buf.items[0..total]);
    }

    /// Release the scratch buffer. Payloads already handed out are unaffected:
    /// each is its own allocation.
    pub fn deinit(self: *PayloadAcc, a: std.mem.Allocator) void {
        self._buf.deinit(a);
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const OStream = @import("ostream.zig").OStream;

test "a fresh count:N array is empty, not N long" {
    const A = FixedArray(u32, 3);
    var a: A = .{};
    try std.testing.expectEqual(u32, A.Elem);
    try std.testing.expectEqual(@as(usize, 3), A.capacity);
    try std.testing.expectEqual(@as(usize, 0), a.len());
    try std.testing.expectEqualSlices(u32, &.{}, a.slice());
}

test "the literal form is a declared default, length and elements together" {
    // The shape generated code spelled out by hand as `.{ .items = .{ 10, 20,
    // 0, 0 }, .len = 2 }`: one call, evaluated at comptime, no padding to keep
    // in sync.
    const Msg = struct {
        levels: FixedArray(u32, 4) = .init(&.{ 10, 20 }),
    };
    const m: Msg = .{};
    try std.testing.expectEqual(@as(usize, 2), m.levels.len());
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, m.levels.slice());
    // The capacity behind the value is spare, and zeroed rather than stale.
    try std.testing.expectEqual(@as(u32, 0), m.levels._items[3]);
}

test "set truncates at the capacity and replaces the whole value" {
    var a: FixedArray(u32, 3) = .{};
    a.set(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, a.slice());
    // A shorter value is the whole value: the old tail is spare capacity again
    // and never reaches the wire.
    a.set(&.{9});
    try std.testing.expectEqualSlices(u32, &.{9}, a.slice());
}

test "push flags an over-count element instead of clamping" {
    var a: FixedArray(u32, 2) = .{};
    var inv = false;
    a.push(1, &inv);
    a.push(2, &inv);
    try std.testing.expect(!inv);
    a.push(3, &inv); // one past the schema count (MESSAGE_SPEC §7.1)
    try std.testing.expect(inv);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, a.slice());
}

test "clear refills from the start, keeping the capacity" {
    // The decode order for a repeated field: an array header clears the
    // destination, its elements then arrive one by one.
    var a: FixedArray(u32, 3) = .init(&.{ 1, 2, 3 });
    var inv = false;
    a.clear();
    try std.testing.expectEqual(@as(usize, 0), a.len());
    a.push(7, &inv);
    try std.testing.expect(!inv);
    try std.testing.expectEqualSlices(u32, &.{7}, a.slice());
}

test "CollectingSink collects every drain into one message" {
    var sink: CollectingSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();

    // A scratch far smaller than the message, so the sink is drained several
    // times over: the collected bytes must be what the one-shot path produces
    // (CORELIB_PLAN §5.1).
    var scratch: [4]u8 = undefined;
    var os = OStream.initFlush(&scratch, 0, &sink, CollectingSink.push);
    try os.writeUnsigned(1, 300);
    try os.writeString(2, "streamed through a four-byte buffer");
    try os.writeSigned(3, -7);
    _ = os.flush();

    var whole: [64]u8 = undefined;
    var one_shot = OStream.init(&whole);
    try one_shot.writeUnsigned(1, 300);
    try one_shot.writeString(2, "streamed through a four-byte buffer");
    try one_shot.writeSigned(3, -7);

    try std.testing.expect(!sink.failed);
    const message = try sink.toOwnedSlice();
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualSlices(u8, whole[0..one_shot.bytesUsed()], message);
}

test "CollectingSink reports a lost drain instead of a truncated message" {
    // The bytes that did fit are a PREFIX of the message; handing them back
    // would be partial output passed off as complete (§5.1).
    var sink: CollectingSink = .{ .alloc = std.testing.failing_allocator };
    defer sink.deinit();
    CollectingSink.push(&sink, "one");
    try std.testing.expect(sink.failed);
    try std.testing.expectError(error.OutOfMemory, sink.toOwnedSlice());
}

test "PayloadAcc assembles a payload split across chunks" {
    var acc: PayloadAcc = .{};
    defer acc.deinit(std.testing.allocator);
    const a = std.testing.allocator;

    try std.testing.expect(try acc.push(a, 9, 0, "abc") == null);
    try std.testing.expect(try acc.push(a, 9, 3, "def") == null);
    const payload = (try acc.push(a, 9, 6, "ghi")).?;
    defer a.free(@constCast(payload));
    try std.testing.expectEqualStrings("abcdefghi", payload);
}

test "a completed payload survives the next one, bytes and address" {
    // The reason it is duplicated rather than viewed: a destination keeps the
    // slice it was given, and the scratch behind it is cleared, appended to and
    // reallocated by every payload that follows.
    var acc: PayloadAcc = .{};
    defer acc.deinit(std.testing.allocator);
    const a = std.testing.allocator;

    try std.testing.expect(try acc.push(a, 4, 0, "ab") == null);
    const first = (try acc.push(a, 4, 2, "cd")).?;
    defer a.free(@constCast(first));

    // A second payload, long enough to force the scratch to grow.
    const long = "x" ** 4096;
    try std.testing.expect(try acc.push(a, long.len, 0, long[0 .. long.len - 1]) == null);
    const second = (try acc.push(a, long.len, long.len - 1, "y")).?;
    defer a.free(@constCast(second));

    try std.testing.expectEqualStrings("abcd", first);
    try std.testing.expectEqual(long.len, second.len);
    try std.testing.expectEqual(@as(u8, 'y'), second[second.len - 1]);
    // Neither payload is a view into the scratch.
    try std.testing.expect(first.ptr != acc._buf.items.ptr);
    try std.testing.expect(second.ptr != acc._buf.items.ptr);
}

test "a new payload does not inherit the previous one's bytes" {
    var acc: PayloadAcc = .{};
    defer acc.deinit(std.testing.allocator);
    const a = std.testing.allocator;

    try std.testing.expect(try acc.push(a, 6, 0, "abc") == null);
    // A stream that ends mid-payload leaves those bytes behind; the next
    // payload starts at offset 0 and must not carry them.
    const next = (try acc.push(a, 2, 0, "hi")).?;
    defer a.free(@constCast(next));
    try std.testing.expectEqualStrings("hi", next);
}

test "PayloadAcc reports an allocation failure rather than swallowing it" {
    var acc: PayloadAcc = .{};
    defer acc.deinit(std.testing.failing_allocator);
    try std.testing.expectError(
        error.OutOfMemory,
        acc.push(std.testing.failing_allocator, 3, 0, "abc"),
    );
}
