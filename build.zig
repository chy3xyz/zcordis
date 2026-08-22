const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Cordis Native library (single root module) ──────────────────────
    // All subdirectories share one module namespace, so files cross-import
    // via relative `@import("../core/scope.zig")` paths — mirroring the
    // zeepseek layout that we reuse for proven Zig 0.17 patterns.
    const lib_mod = b.addModule("cordis", .{
        .root_source_file = b.path("src/cordis.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cordis",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build the cordis native library");
    lib_step.dependOn(&lib.step);

    // ── Example: basic composition demo ─────────────────────────────────
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport("cordis", lib_mod);

    const example = b.addExecutable(.{
        .name = "zcordis-basic",
        .root_module = example_mod,
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the basic composition example");
    run_step.dependOn(&run_example.step);

    // ── C ABI plugin: shared library loaded at runtime ──────────────────
    const greet_mod = b.createModule(.{
        .root_source_file = b.path("examples/plugins/greet_plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const greet_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "greet-plugin",
        .root_module = greet_mod,
    });
    b.installArtifact(greet_plugin);

    // ── Example: dynamic loader (phase 2) ───────────────────────────────
    const loader_mod = b.createModule(.{
        .root_source_file = b.path("examples/loader.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    loader_mod.addImport("cordis", lib_mod);
    const loader_exe = b.addExecutable(.{
        .name = "zcordis-loader",
        .root_module = loader_mod,
    });
    b.installArtifact(loader_exe);

    const run_loader = b.addRunArtifact(loader_exe);
    run_loader.addArtifactArg(greet_plugin);
    run_loader.step.dependOn(b.getInstallStep());
    const loader_step = b.step("run-loader", "Load a C ABI plugin dynamically");
    loader_step.dependOn(&run_loader.step);

    // ── Example: WASM plugin (phase 3) ──────────────────────────────────
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("examples/wasm_loader.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wasm_mod.addImport("cordis", lib_mod);
    const wasm_exe = b.addExecutable(.{
        .name = "zcordis-wasm",
        .root_module = wasm_mod,
    });
    b.installArtifact(wasm_exe);

    const run_wasm = b.addRunArtifact(wasm_exe);
    run_wasm.step.dependOn(b.getInstallStep());
    const wasm_step = b.step("run-wasm", "Run a WASM plugin in the interpreter");
    wasm_step.dependOn(&run_wasm.step);

    // ── Example: DeepSeek-Harness-style agent runtime (everything is a plugin) ──
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("examples/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    harness_mod.addImport("cordis", lib_mod);
    const harness_exe = b.addExecutable(.{
        .name = "zcordis-harness",
        .root_module = harness_mod,
    });
    b.installArtifact(harness_exe);

    const run_harness = b.addRunArtifact(harness_exe);
    run_harness.step.dependOn(b.getInstallStep());
    const harness_step = b.step("run-harness", "Run the DeepSeek-Harness-style agent example");
    harness_step.dependOn(&run_harness.step);

    // ── WASM fuzz driver (standalone, deep runs) ────────────────────────
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/wasm_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuzz_mod.addImport("cordis", lib_mod);
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-wasm",
        .root_module = fuzz_mod,
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.step.dependOn(b.getInstallStep());
    const fuzz_step = b.step("fuzz-wasm", "Run the WASM interpreter fuzz driver (args: [iterations] [seed])");
    fuzz_step.dependOn(&run_fuzz.step);

    // ── C plugin header (single source of truth: src/abi/c.zig) ────────
    // Emit `zig-out/include/cordis_plugin.h` so C/C++/Rust plugin authors can
    // implement the ABI without touching Zig.
    const abi_c = @import("src/abi/c.zig");
    const header_files = b.addWriteFiles();
    const plugin_header = header_files.add("cordis_plugin.h", abi_c.c_header);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(plugin_header, "cordis_plugin.h").step);

    // ── Tests ───────────────────────────────────────────────────────────
    // 1. Per-module inline tests, pulled in by `src/cordis.zig`'s `test {}`.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/cordis.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_build = b.addTest(.{ .root_module = test_mod });
    const test_run = b.addRunArtifact(test_build);

    // 2. Integration tests under `tests/`, exercising the public API. They
    //    import the `cordis` module exactly as a downstream consumer would.
    const itest_mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    itest_mod.addImport("cordis", lib_mod);
    const itest_build = b.addTest(.{ .root_module = itest_mod });
    const itest_run = b.addRunArtifact(itest_build);

    const test_step = b.step("test", "Run all unit + integration tests");
    test_step.dependOn(&test_run.step);
    test_step.dependOn(&itest_run.step);
}
