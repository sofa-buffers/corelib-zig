//! Dev-environment ↔ tooling checks (CORELIB_PLAN §10, §11.1, §13).
//!
//! §13 requires `perf`, `bench` and `run_callgrind.sh` to be present **and
//! runnable**, and §11.1 makes `.devcontainer/Dockerfile` the image the work
//! happens in. A tool whose prerequisite the image does not install ships
//! present but not runnable: `bash bench/run_callgrind.sh` then stops at its
//! own `command -v` guard instead of printing an Ir/op table.
//!
//! Nothing compiled catches that — the image is built by Docker, not by `zig
//! build` — so these tests read the shipped scripts and the shipped Dockerfile
//! and hold them against each other: every external command a tool script
//! guards on, or names as a requirement, has to be installed by the image the
//! README tells a developer to work in.

const std = @import("std");

/// The shipped devcontainer image definition (build.zig hands these over as
/// modules; embedding keeps the test honest about the files that ship).
const dockerfile = @embedFile("dockerfile");
/// The Callgrind driver — the §10 tool with an external prerequisite.
const run_callgrind_sh = @embedFile("run_callgrind_sh");
/// The coverage driver, which names its prerequisites in a `Requires:` header.
const coverage_sh = @embedFile("coverage_sh");

test "the devcontainer installs every command run_callgrind.sh guards on" {
    // Derived, not listed: whatever the script refuses to run without is what
    // the image has to provide. Today that is `valgrind`.
    var found: usize = 0;
    var rest: []const u8 = run_callgrind_sh;
    while (std.mem.indexOf(u8, rest, "command -v ")) |at| {
        rest = rest[at + "command -v ".len ..];
        const tool = rest[0..(std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len)];
        if (tool.len == 0) continue;
        found += 1;
        try expectInstalled(tool, "bench/run_callgrind.sh");
    }
    // The guard the script is known to carry; if it ever loses it, the loop
    // above would pass vacuously.
    try std.testing.expect(found >= 1);
    try std.testing.expect(std.mem.indexOf(u8, run_callgrind_sh, "command -v valgrind") != null);
}

test "the devcontainer installs every command coverage.sh requires" {
    // `# Requires: kcov, jq  (apt-get install kcov jq)` — the names before the
    // parenthetical are the commands the script calls.
    const at = std.mem.indexOf(u8, coverage_sh, "Requires:") orelse
        return error.CoverageScriptHasNoRequiresHeader;
    var line: []const u8 = coverage_sh[at + "Requires:".len ..];
    line = line[0..(std.mem.indexOfScalar(u8, line, '\n') orelse line.len)];
    line = line[0..(std.mem.indexOfScalar(u8, line, '(') orelse line.len)];

    var names = std.mem.splitScalar(u8, line, ',');
    while (names.next()) |raw| {
        const tool = std.mem.trim(u8, raw, " \t\r");
        if (tool.len == 0) continue;
        try expectInstalled(tool, "coverage.sh");
    }
}

test "the Dockerfile's comments name the base image it actually builds on" {
    // Comment rot is how the image drifts from what a reader believes it is:
    // the kcov note outlived two Ubuntu releases while still explaining itself
    // in terms of the old one. Every `Ubuntu <version>` the file mentions has
    // to be the version in its own `FROM`.
    const from = std.mem.indexOf(u8, dockerfile, "FROM ubuntu:") orelse
        return error.DockerfileHasNoUbuntuBase;
    const tail = dockerfile[from + "FROM ubuntu:".len ..];
    const base = std.mem.trim(u8, tail[0..(std.mem.indexOfAny(u8, tail, " \t\r\n") orelse tail.len)], " \t\r");

    var rest: []const u8 = dockerfile;
    var offset: usize = 0;
    while (std.ascii.indexOfIgnoreCase(rest[offset..], "ubuntu ")) |rel| {
        const at = offset + rel;
        offset = at + "ubuntu ".len;
        const after = rest[offset..];
        const version = after[0..(std.mem.indexOfAny(u8, after, " \t\r\n)") orelse after.len)];
        // Only a version-shaped word is a claim about the base image.
        if (version.len == 0 or !std.ascii.isDigit(version[0])) continue;
        if (!std.mem.eql(u8, version, base)) {
            std.debug.print(
                ".devcontainer/Dockerfile says \"Ubuntu {s}\" but builds on ubuntu:{s}\n",
                .{ version, base },
            );
            return error.StaleBaseImageComment;
        }
    }
}

/// Assert the devcontainer image provides `tool`, naming the script that needs
/// it in the failure. Installation shape is deliberately not prescribed — apt
/// for most, a pinned source build for kcov — only that the image sets it up.
fn expectInstalled(tool: []const u8, needed_by: []const u8) !void {
    if (std.mem.indexOf(u8, dockerfile, tool) == null) {
        std.debug.print(
            "{s} needs `{s}`, but .devcontainer/Dockerfile never installs it: the tool " ++
                "ships present but not runnable in the documented dev environment " ++
                "(CORELIB_PLAN §11.1, §13)\n",
            .{ needed_by, tool },
        );
        return error.DevcontainerMissingPrerequisite;
    }
}
