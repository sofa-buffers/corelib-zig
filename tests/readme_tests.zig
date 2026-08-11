//! README ↔ code checks for the generated-object layer (CORELIB_PLAN §6.1.1, §9).
//!
//! §6.1.1 closes the name set of the generated surface: `encode` / `decode` /
//! `try_decode` and `serialize` / `deserialize` / `decoder`, casing adapted,
//! words never. Every invented spelling it lists — `serialize_to`, `to_bytes`,
//! `from_bytes`, `decode_from`, `decode_into`, `marshal`, `unmarshal` — is one
//! more name a developer has to learn per language for an identical operation.
//! §9 then requires every API name the README states to match the code as it
//! stands today, and §9.5 requires the generator section to show the one-shot
//! `encode()` / `decode()` helpers *and* the streaming `serialize` / `decoder()`
//! path.
//!
//! A README example is not compiled by `zig build test`, so nothing stopped the
//! section from documenting an API that neither this corelib nor the generator
//! has. These tests close that: the forbidden spellings must not appear, the
//! canonical ones must, and every line of the section's Zig must stand — and
//! compile, and run — in `readme_generated_example.zig`.

const std = @import("std");

/// The shipped README, embedded verbatim (build.zig hands it over as a module).
const readme = @embedFile("readme");
/// The compiled mirror of the section's code.
const example = @embedFile("readme_generated_example.zig");
/// The shipped Callgrind driver, embedded so the README cannot document a
/// command the repo does not ship (build.zig hands it over as a module).
const run_callgrind_sh = @embedFile("run_callgrind_sh");

/// The `### Code generator` section: from its heading to the next `## ` chapter.
const section = blk: {
    @setEvalBranchQuota(200_000);
    const start = std.mem.indexOf(u8, readme, "### Code generator") orelse
        @compileError("README has no `### Code generator` section (CORELIB_PLAN §9.5)");
    const rest = readme[start..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    break :blk rest[0..end];
};

/// The `## Benchmarks` section: from its heading to the next `## ` chapter.
const benchmarks = blk: {
    @setEvalBranchQuota(200_000);
    const start = std.mem.indexOf(u8, readme, "## Benchmarks") orelse
        @compileError("README has no `## Benchmarks` section (CORELIB_PLAN §9.8)");
    const rest = readme[start + "## Benchmarks".len ..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    break :blk rest[0..end];
};

/// The command line `bench/run_callgrind.sh` documents for itself, taken from
/// its own `# Usage:` header — the one spelling the README has to agree with.
const callgrind_usage = blk: {
    @setEvalBranchQuota(200_000);
    const at = std.mem.indexOf(u8, run_callgrind_sh, "Usage:") orelse
        @compileError("bench/run_callgrind.sh has no `Usage:` line to check the README against");
    const rest = run_callgrind_sh[at + "Usage:".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    break :blk std.mem.trim(u8, rest[0..end], " \t\r");
};

test "the Benchmarks section documents all three tools §10 ships" {
    // §10: `perf` (per-op cost), `bench` (MB/s) and `run_callgrind.sh` (Ir/op).
    // §9.8: how to run each, and what each measures. A tool that stands in the
    // repo, works, and is never named here cannot be discovered by a reader.
    for ([_][]const u8{
        "zig build perf",
        "zig build bench",
        callgrind_usage, // `bash bench/run_callgrind.sh`
    }) |cmd| {
        if (std.mem.indexOf(u8, benchmarks, cmd) == null) {
            std.debug.print(
                "README `## Benchmarks` never shows how to run `{s}` (CORELIB_PLAN §9.8, §10)\n",
                .{cmd},
            );
            return error.MissingBenchmarkTool;
        }
    }

    // What each measures, in the terms §10 defines them in — plus the one
    // prerequisite the Callgrind driver exits on when it is missing.
    for ([_][]const u8{
        "cycles/op",
        "MB/s",
        "Ir/op",
        "valgrind",
    }) |term| {
        if (std.ascii.indexOfIgnoreCase(benchmarks, term) == null) {
            std.debug.print(
                "README `## Benchmarks` does not say what `{s}` covers (CORELIB_PLAN §9.8)\n",
                .{term},
            );
            return error.MissingBenchmarkMeasure;
        }
    }
}

test "the README never spells an operation §6.1.1 closed out" {
    // `unmarshal` is covered by `marshal`; the search is case-insensitive so a
    // prose `Marshal` or a `ToBytes` in an example counts too.
    for ([_][]const u8{
        "marshal",
        "serialize_to",
        "to_bytes",
        "from_bytes",
        "decode_from",
        "decode_into",
    }) |banned| {
        if (std.ascii.indexOfIgnoreCase(readme, banned)) |at| {
            std.debug.print(
                "README:{d}: `{s}` is a spelling CORELIB_PLAN §6.1.1 closes out\n",
                .{ lineOf(at), banned },
            );
            return error.NonCanonicalName;
        }
    }
}

test "the generator section documents the names the generator emits (§6.1.1)" {
    // The one-shot pair, the streaming pair, and the schema-derived constant —
    // spelled as `generators/zig/backend.go` emits them.
    for ([_][]const u8{
        "pub fn serialize(self: *const Point, os: *sofab.OStream) sofab.Error!void",
        "pub fn encode(self: *const Point, alloc: std.mem.Allocator)",
        "pub fn decode(alloc: std.mem.Allocator, data: []const u8) DecodeError!Point",
        "pub fn decoder(out: *Point, alloc: std.mem.Allocator) Decoder",
        "pub const MAX_SIZE: usize",
    }) |sig| {
        if (std.mem.indexOf(u8, section, sig) == null) {
            std.debug.print("README `### Code generator` is missing: {s}\n", .{sig});
            return error.MissingGeneratedApi;
        }
    }
    // A constant the generator does not emit is as wrong as a missing one.
    try std.testing.expect(std.mem.indexOf(u8, readme, "max_size") == null);

    // §9.5: the section must show the streaming path, not just the helpers.
    for ([_][]const u8{ ".serialize(&os)", ".feed(", "dec.finish()", ".incomplete" }) |streaming| {
        if (std.mem.indexOf(u8, section, streaming) == null) {
            std.debug.print("README `### Code generator` shows no streaming `{s}`\n", .{streaming});
            return error.MissingStreamingPath;
        }
    }
}

test "every line of the section's Zig stands in the compiled mirror" {
    var blocks: usize = 0;
    var rest: []const u8 = section;
    while (std.mem.indexOf(u8, rest, "```zig")) |open| {
        const body_start = open + "```zig\n".len;
        const body_len = std.mem.indexOf(u8, rest[body_start..], "```") orelse
            return error.UnterminatedCodeBlock;
        try expectMirrored(rest[body_start..][0..body_len]);
        blocks += 1;
        rest = rest[body_start + body_len ..];
    }
    // The generated code and its usage: two blocks, and the test is worthless
    // if the section silently loses one.
    try std.testing.expectEqual(@as(usize, 2), blocks);
}

/// Assert every non-blank line of `block` occurs, in order, in the example
/// file. Leading indentation is ignored: the README prints the usage flat while
/// the mirror runs it inside a `test` body, and only the code has to match.
fn expectMirrored(block: []const u8) !void {
    var cursor: usize = 0;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const at = std.mem.indexOfPos(u8, example, cursor, line) orelse {
            std.debug.print(
                "README `### Code generator` shows a line that is nowhere in " ++
                    "readme_generated_example.zig (or is out of order):\n  {s}\n",
                .{line},
            );
            return error.ReadmeCodeNotCompiled;
        };
        cursor = at + line.len;
    }
}

/// 1-based line number of `offset` in the README, for a readable failure.
fn lineOf(offset: usize) usize {
    return std.mem.count(u8, readme[0..offset], "\n") + 1;
}
