const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // This port is the high-speed build of the family: `--release` resolves to
    // ReleaseFast, the configuration the library is tuned for (`zig build
    // --release=fast`). A plain `zig build` stays Debug for development.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // The public module. Users depend on the package `sofa_buffers_corelib` and
    // import the namespace `sofab` (family convention, ARCHITECTURE §6).
    const sofab = b.addModule("sofab", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact for non-Zig consumers of `zig build`.
    const lib = b.addLibrary(.{
        .name = "sofab",
        .root_module = sofab,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // --- tests ---------------------------------------------------------------
    // The LLVM backend keeps the tests' DWARF readable by kcov (the default
    // self-hosted x86_64 backend yields 0% coverage there).
    // In-source unit tests (varint/ostream/istream internals).
    const unit_tests = b.addTest(.{ .name = "unit-tests", .root_module = sofab, .use_llvm = true });

    // Conformance suite: shared test vectors + chunked/malformed/skip scenarios.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("sofab", sofab);
    // Embed the shared cross-language vectors verbatim from assets/.
    tests_mod.addAnonymousImport("test_vectors", .{
        .root_source_file = b.path("assets/test_vectors.json"),
    });
    const conformance_tests = b.addTest(.{ .name = "conformance-tests", .root_module = tests_mod, .use_llvm = true });

    const test_step = b.step("test", "Run unit + conformance tests (incl. shared vectors)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(conformance_tests).step);

    // Install the test binaries without running them, so coverage.sh can
    // execute them under kcov.
    const install_tests = b.step("install-tests", "Install test binaries (for coverage runs)");
    install_tests.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);
    install_tests.dependOn(&b.addInstallArtifact(conformance_tests, .{}).step);

    // --- benchmarks (BENCH_SPEC.md) -------------------------------------------
    // Always built ReleaseFast: the numbers must reflect the shipping config.
    inline for (.{ "bench", "perf" }) |tool| {
        const mod = b.createModule(.{
            .root_source_file = b.path("bench/" ++ tool ++ ".zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        mod.addImport("sofab", b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }));
        const exe = b.addExecutable(.{ .name = tool, .root_module = mod });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        const step = b.step(tool, if (std.mem.eql(u8, tool, "bench"))
            "Run the throughput benchmark (MB/s, CPU time)"
        else
            "Run the per-op cost benchmark (cycles/op + MB/s)");
        step.dependOn(&run.step);
    }

    // --- docs ------------------------------------------------------------------
    const docs_obj = b.addObject(.{ .name = "sofab", .root_module = sofab });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate the API documentation (zig-out/docs)");
    docs_step.dependOn(&install_docs.step);
}
