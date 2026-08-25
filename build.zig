const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // This port is the high-speed build of the family: `--release` resolves to
    // ReleaseFast, the configuration the library is tuned for (`zig build
    // --release=fast`). A plain `zig build` stays Debug for development.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // SOFAB_STRICT_UTF8 (CORELIB_PLAN §6.4) — compile-time UTF-8 validation
    // policy for `string` fields. This is a *validation policy, never a
    // wire-format switch*: it only decides accept-vs-reject and never changes
    // how valid data is encoded. ON (the default) validates on the encode side
    // and makes `utf8Valid` a real validator; OFF folds `utf8Valid` to
    // `return true` and drops the encode-side reject, so none of the validation
    // code is compiled in (zero `.text`/`.rodata` cost) and generated code is
    // identical across build configurations.
    const strict_utf8 = b.option(
        bool,
        "strict_utf8",
        "Enable strict UTF-8 validation of string fields (SOFAB_STRICT_UTF8, default on)",
    ) orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "strict_utf8", strict_utf8);

    // The public module. Users depend on the package `sofa_buffers_corelib` and
    // import the namespace `sofab` (family convention, ARCHITECTURE §6).
    const sofab = b.addModule("sofab", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sofab.addOptions("build_options", build_options);

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
    // Whether the test binary will run on the machine that builds it. The
    // §6.6.4 heap high-water measurement (tests/no_allocation_tests.zig) reads
    // the *process's* peak RSS, which under an emulator is the emulator's — its
    // JIT caches grow as translation warms up, and none of that is the codec's.
    // Only build.zig can tell the two apart, so it says so and the test skips
    // itself elsewhere; every other check in that file is target-independent.
    const host = b.graph.host.result;
    const native_target = target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag;
    const test_options = b.addOptions();
    test_options.addOption(bool, "native_target", native_target);
    tests_mod.addOptions("test_options", test_options);
    // Embed the shared cross-language vectors verbatim from assets/.
    tests_mod.addAnonymousImport("test_vectors", .{
        .root_source_file = b.path("assets/test_vectors.json"),
    });
    // Embed the shipped README, so the generated-object surface it documents is
    // checked against the code that stands here (CORELIB_PLAN §6.1.1, §9).
    tests_mod.addAnonymousImport("readme", .{
        .root_source_file = b.path("README.md"),
    });
    // …and the Callgrind driver, so the command the README prints for the third
    // §10 tool is checked against the script that actually stands here (§9.8).
    tests_mod.addAnonymousImport("run_callgrind_sh", .{
        .root_source_file = b.path("bench/run_callgrind.sh"),
    });
    // …the coverage driver, and the devcontainer image both scripts run in, so
    // no tool can ship "present" while the documented dev environment lacks the
    // prerequisite it refuses to run without (§10, §11.1, §13).
    tests_mod.addAnonymousImport("coverage_sh", .{
        .root_source_file = b.path("coverage.sh"),
    });
    tests_mod.addAnonymousImport("dockerfile", .{
        .root_source_file = b.path(".devcontainer/Dockerfile"),
    });
    // The benchmark workload table, built against the *same* `sofab` module the
    // tests use: BENCH_SPEC's rows, datasets and parity sizes are checked by
    // running them (tests/bench_spec_tests.zig), not by reading the tools'
    // output. A workload that stops encoding what the spec says then fails the
    // suite instead of printing a plausible number.
    const tests_workloads = b.createModule(.{
        .root_source_file = b.path("bench/workloads.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_workloads.addImport("sofab", sofab);
    tests_mod.addImport("bench_workloads", tests_workloads);
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
    //
    // All three tools share one library module and one workload module, so the
    // MB/s table, the per-op report and the Callgrind Ir/op table measure the
    // very same code on the very same data — the property that makes their
    // numbers readable against each other, and against the sibling ports.
    const bench_sofab = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_sofab.addOptions("build_options", build_options);
    const bench_workloads = b.createModule(.{
        .root_source_file = b.path("bench/workloads.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_workloads.addImport("sofab", bench_sofab);

    inline for (.{ "bench", "perf" }) |tool| {
        const mod = b.createModule(.{
            .root_source_file = b.path("bench/" ++ tool ++ ".zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        mod.addImport("sofab", bench_sofab);
        mod.addImport("workloads", bench_workloads);
        const exe = b.addExecutable(.{ .name = tool, .root_module = mod });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        const step = b.step(tool, if (std.mem.eql(u8, tool, "bench"))
            "Run the throughput benchmark (MB/s, CPU time)"
        else
            "Run the per-op cost benchmark (cycles/op + MB/s)");
        step.dependOn(&run.step);
    }

    // --- Callgrind instructions/op (BENCH_SPEC.md) ----------------------------
    // Built, not run: bench/run_callgrind.sh drives the installed binary under
    // valgrind. Symbols are kept so `--toggle-collect=run_<workload>` matches.
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("bench/callgrind.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = false,
        });
        mod.addImport("sofab", bench_sofab);
        mod.addImport("workloads", bench_workloads);
        const exe = b.addExecutable(.{ .name = "callgrind", .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        const step = b.step("callgrind", "Build the Callgrind instructions/op tool (run via bench/run_callgrind.sh)");
        step.dependOn(&install.step);
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
