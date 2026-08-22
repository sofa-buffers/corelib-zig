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

// ---------------------------------------------------------------------------
// README structure guard (CORELIB_PLAN §9)
//
// The tests above check what the README *says* about the generated-object
// layer. These check the document itself: the section list §9 prescribes, the
// header and badge blocks of §9.1/§9.2, the absence of the API chapter §9.4
// forbids, the examples §9.5 lists, the UTF-8 knob §6.4 requires *of this
// port*, the constant §9.6 places in the memory chapter, and the internal
// links. A chapter can keep its heading and lose the fact a reader came for,
// and none of the tests above notice that.
//
// §6.4 applies here in full: Zig's `string` is `[]const u8`, a **byte-container**
// type, so this port MUST expose the `SOFAB_STRICT_UTF8` knob *and* the
// `utf8_valid` primitive that generated code calls. The exemption §6.4 grants —
// omitting the option, documented as always-ON — is for Unicode-string targets
// (Rust, Java, C#, JavaScript, Python) and is not available to this one.
// ---------------------------------------------------------------------------

/// One Markdown heading outside a fenced code block.
const Heading = struct {
    level: usize,
    text: []const u8,
    line: usize,
};

var heading_storage: [128]Heading = undefined;

/// Every heading in the README, in document order. Lines inside ``` fences are
/// not headings, however many `#` they start with.
fn headings() []const Heading {
    var n: usize = 0;
    var fenced = false;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, readme, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            fenced = !fenced;
            continue;
        }
        if (fenced or !std.mem.startsWith(u8, line, "#")) continue;
        var level: usize = 0;
        while (level < line.len and line[level] == '#') level += 1;
        if (level >= line.len or line[level] != ' ') continue;
        heading_storage[n] = .{
            .level = level,
            .text = std.mem.trim(u8, line[level..], " \t#"),
            .line = line_no,
        };
        n += 1;
    }
    return heading_storage[0..n];
}

/// GitHub's heading-anchor slug: lower-case, drop everything that is not
/// alphanumeric / space / `-` / `_`, then spaces become `-`.
fn slugify(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower) or lower == '-' or lower == '_') {
            out[n] = lower;
            n += 1;
        } else if (lower == ' ') {
            out[n] = '-';
            n += 1;
        }
    }
    return out[0..n];
}

/// The body of the `## ` chapter titled `title`, heading line included.
fn chapter(title: []const u8) ![]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\n## {s}\n", .{title});
    const start = std.mem.indexOf(u8, readme, needle) orelse {
        std.debug.print("README has no `## {s}` chapter (CORELIB_PLAN §9)\n", .{title});
        return error.MissingChapter;
    };
    const rest = readme[start + 1 ..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    return rest[0..end];
}

test "the top-level sections are §9's list, in §9's order" {
    // §9: "Do not change the section ordering and do not invent new top-level
    // sections." The list is the whole point of the shared shape — a reader who
    // knows one port's README can navigate any other.
    const expected = [_][]const u8{
        "SofaBuffers Zig library",
        "Why this design",
        "Usage",
        "Memory handling",
        "Build & test",
        "Benchmarks",
    };
    var seen: usize = 0;
    for (headings()) |h| {
        if (h.level != 2) continue;
        if (seen >= expected.len) {
            std.debug.print(
                "README:{d}: extra top-level section `## {s}` (CORELIB_PLAN §9)\n",
                .{ h.line, h.text },
            );
            return error.UnexpectedSection;
        }
        if (!std.mem.eql(u8, h.text, expected[seen])) {
            std.debug.print(
                "README:{d}: top-level section {d} is `{s}`, §9 prescribes `{s}`\n",
                .{ h.line, seen + 1, h.text, expected[seen] },
            );
            return error.WrongSectionOrder;
        }
        seen += 1;
    }
    if (seen != expected.len) {
        std.debug.print(
            "README has {d} of §9's {d} top-level sections; `## {s}` is missing\n",
            .{ seen, expected.len, expected[seen] },
        );
        return error.MissingSection;
    }
}

test "the §9.1 header block is intact" {
    // Centered logo, the family title, the tagline in both halves, and the link
    // back to the organization — identical across every port.
    for ([_][]const u8{
        "<p align=\"center\"><img src=\"assets/sofabuffers_logo.png\" alt=\"SofaBuffers\" height=\"140\"></p>",
        "\n# SofaBuffers\n",
        "<b>Structured Objects For Anyone</b><br>",
        "<i>... so optimized, feels amazing.</i>",
        "https://github.com/sofa-buffers)",
    }) |part| {
        if (std.mem.indexOf(u8, readme, part) == null) {
            std.debug.print("README §9.1 header block is missing: {s}\n", .{part});
            return error.BrokenHeaderBlock;
        }
    }
}

test "the §9.2 badge block carries CI, coverage and Docs, in that order" {
    const opening = try chapter("SofaBuffers Zig library");
    var cursor: usize = 0;
    for ([_][]const u8{ "[![CI]", "[![Coverage]", "[![Docs]" }) |badge| {
        const at = std.mem.indexOfPos(u8, opening, cursor, badge) orelse {
            std.debug.print(
                "README `## SofaBuffers Zig library` is missing the {s} badge, " ++
                    "or carries it out of §9.2's CI/coverage/Docs order\n",
                .{badge},
            );
            return error.BadBadgeBlock;
        };
        cursor = at + badge.len;
    }
    // §9.4: the Docs badge is the *only* pointer to API documentation, so it
    // has to point at the published reference.
    try std.testing.expect(std.mem.indexOf(u8, opening, "https://sofa-buffers.github.io/corelib-zig/") != null);
    // §9.2 also asks for the repository link and the toolchain floor.
    try std.testing.expect(std.mem.indexOf(u8, opening, "https://github.com/sofa-buffers/corelib-zig)") != null);
    try std.testing.expect(std.mem.indexOf(u8, opening, "Zig 0.16.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, opening, "zig fetch --save") != null);
}

test "no API-documentation section at any heading level (§9.4)" {
    // §9.4: the Docs badge is the single entry point; a README chapter that
    // duplicates the generated reference is a second one that drifts.
    var buf: [256]u8 = undefined;
    for (headings()) |h| {
        const slug = slugify(h.text, &buf);
        for ([_][]const u8{
            "api-reference",
            "api-documentation",
            "api-docs",
            "source-documentation",
        }) |banned| {
            if (std.mem.indexOf(u8, slug, banned) != null) {
                std.debug.print(
                    "README:{d}: `{s}` is the API chapter CORELIB_PLAN §9.4 forbids\n",
                    .{ h.line, h.text },
                );
                return error.ApiDocSection;
            }
        }
    }
}

test "the Usage chapter still shows every example §9.5 lists" {
    const usage = try chapter("Usage");
    // §9.5's list, mapped onto this port's subsections. The marker is the call
    // that makes the example the example: a subsection can survive a rewrite
    // with its heading and lose the code.
    const required = [_]struct { heading: []const u8, marker: []const u8 }{
        // simple encode, and the OStream wrapper
        .{ .heading = "### Serialize\n", .marker = "sofab.OStream.init(" },
        // a message larger than the buffer, streamed through a flush sink
        .{ .heading = "### Serialize stream\n", .marker = "sofab.OStream.initFlush(" },
        // simple decode
        .{ .heading = "### Deserialize\n", .marker = "sofab.decode(" },
        // the IStream push-feed wrapper
        .{ .heading = "### Deserialize stream\n", .marker = "sofab.IStream.init()" },
        // generated object code, one-shot and streaming
        .{ .heading = "### Code generator\n", .marker = "sofabgen --lang zig" },
    };
    for (required) |req| {
        const at = std.mem.indexOf(u8, usage, req.heading) orelse {
            std.debug.print(
                "README `## Usage` lost the `{s}` example CORELIB_PLAN §9.5 requires\n",
                .{std.mem.trim(u8, req.heading, "# \n")},
            );
            return error.MissingUsageExample;
        };
        const body_end = std.mem.indexOfPos(u8, usage, at + req.heading.len, "\n### ") orelse usage.len;
        const body = usage[at..body_end];
        if (std.mem.indexOf(u8, body, req.marker) == null) {
            std.debug.print(
                "README `{s}` no longer shows `{s}` (CORELIB_PLAN §9.5)\n",
                .{ std.mem.trim(u8, req.heading, "# \n"), req.marker },
            );
            return error.EmptyUsageExample;
        }
        if (std.mem.indexOf(u8, body, "```zig") == null) {
            std.debug.print(
                "README `{s}` has no runnable Zig block (CORELIB_PLAN §9.5)\n",
                .{std.mem.trim(u8, req.heading, "# \n")},
            );
            return error.UnrunnableUsageExample;
        }
    }
}

test "the strict-UTF-8 knob is documented (§6.4)" {
    // Byte-container target: the option and the primitive are both mandatory
    // here (see the note at the top of this block). What a caller must be able
    // to read off the README: the canonical option name, this port's spelling
    // of it, the primitive generated code calls, and the default.
    for ([_][]const u8{
        "SOFAB_STRICT_UTF8",
        "-Dstrict_utf8=false",
        "sofab.utf8Valid(",
        "sofab.STRICT_UTF8",
    }) |fact| {
        if (std.mem.indexOf(u8, readme, fact) == null) {
            std.debug.print("README does not document `{s}` (CORELIB_PLAN §6.4)\n", .{fact});
            return error.MissingUtf8Knob;
        }
    }
    // The knob is a validation policy and defaults to ON; both are facts §6.4
    // makes normative, and both change how a reader configures a deployment.
    try std.testing.expect(std.ascii.indexOfIgnoreCase(readme, "on by default") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(readme, "never a wire-format switch") != null);
}

test "MIN_OUTPUT_BUFFER is stated in the Memory handling chapter (§9.6)" {
    // §9.6 puts it *here* on purpose: it is the number a caller needs before it
    // can size a streaming buffer, and this is the chapter they read to find
    // out who allocates what. Stated anywhere else, it is not where they look.
    const memory = try chapter("Memory handling");
    if (std.mem.indexOf(u8, memory, "MIN_OUTPUT_BUFFER") == null) {
        std.debug.print(
            "README `## Memory handling` does not state MIN_OUTPUT_BUFFER (CORELIB_PLAN §9.6)\n",
            .{},
        );
        return error.MinOutputBufferNotInMemoryChapter;
    }
    // §5.1 wants the value itself, the streaming-only scope, and — since this
    // port grants none — the pass-through answer.
    for ([_][]const u8{ "is `1`", "without** a sink", "pass" }) |fact| {
        if (std.mem.indexOf(u8, memory, fact) == null) {
            std.debug.print(
                "README `## Memory handling` no longer states `{s}` (CORELIB_PLAN §5.1, §9.6)\n",
                .{fact},
            );
            return error.IncompleteOutputBufferContract;
        }
    }
    // §9.6's other half: who owns the decoded bytes, per decode path.
    try std.testing.expect(std.mem.indexOf(u8, memory, "decode") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "feed") != null);
}

test "every in-document link resolves to a heading" {
    var buf: [256]u8 = undefined;
    var rest: []const u8 = readme;
    var checked: usize = 0;
    while (std.mem.indexOf(u8, rest, "](#")) |at| {
        const target_start = at + "](#".len;
        const close = std.mem.indexOfScalarPos(u8, rest, target_start, ')') orelse
            return error.UnterminatedLink;
        const target = rest[target_start..close];
        rest = rest[close..];
        checked += 1;

        var found = false;
        for (headings()) |h| {
            if (std.mem.eql(u8, slugify(h.text, &buf), target)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print(
                "README link `](#{s})` resolves to no heading in the document\n",
                .{target},
            );
            return error.DanglingAnchor;
        }
    }
    // The check is worthless if the document stops carrying internal links.
    try std.testing.expect(checked > 0);
}
