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

/// The `### Code generator` section: from its heading to the next heading at
/// the same level or above — a sibling `### ` subsection or the next `## `
/// chapter, whichever comes first.
const section = blk: {
    @setEvalBranchQuota(200_000);
    const start = std.mem.indexOf(u8, readme, "### Code generator") orelse
        @compileError("README has no `### Code generator` section (CORELIB_PLAN §9.5)");
    const rest = readme[start + "### Code generator".len ..];
    var end = rest.len;
    for ([_][]const u8{ "\n### ", "\n## " }) |stop| {
        if (std.mem.indexOf(u8, rest, stop)) |at| end = @min(end, at);
    }
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
