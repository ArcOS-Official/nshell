const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const llvm = b.option(bool, "llvm", "enables llvm");
    const lld = b.option(bool, "lld", "enables lld");

    const exe = b.addExecutable(.{
        .name = "nshell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = llvm,
        .use_lld = lld,
    });

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    const ls_dep = b.dependency("dvui_layer_shell", .{ .target = target, .optimize = optimize });
    const nilebank_dep = b.dependency("nilebank", .{
        .target = target,
    });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("layershell", ls_dep.module("dvui-layer-shell"));
    exe.root_module.addImport("nilebank", nilebank_dep.module("nilebank"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_lld = lld,
        .use_llvm = llvm,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_exe_tests.step);

    // Separate test module for State.zig. State returns real dvui types,
    // but the headless tests resolve `@import("dvui")` to a link-light shim
    // (see src/dvui_shim.zig): the real backend module pulls SDL3/C objects
    // into the link, which this toolchain cannot link.
    const dvui_shim = b.createModule(.{
        .root_source_file = b.path("src/dvui_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const state_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_test_module.addImport("nilebank", nilebank_dep.module("nilebank"));
    state_test_module.addImport("dvui", dvui_shim);

    const state_tests = b.addTest(.{
        .root_module = state_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_state_tests = b.addRunArtifact(state_tests);

    const test_state_step = b.step("test-state", "Run State tests (no GUI)");
    test_state_step.dependOn(&run_state_tests.step);

    // Headless Launcher parser tests – also link-light via dvui_shim
    const launcher_test_module = b.createModule(.{
        .root_source_file = b.path("src/Launcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    launcher_test_module.addImport("dvui", dvui_shim);
    const launcher_tests = b.addTest(.{
        .root_module = launcher_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_launcher_tests = b.addRunArtifact(launcher_tests);
    const test_launcher_step = b.step("test-launcher", "Run Launcher parser tests (no GUI)");
    test_launcher_step.dependOn(&run_launcher_tests.step);
    test_state_step.dependOn(&run_launcher_tests.step);

    // Headless icon/search bench – link-light via dvui_shim (no GUI link).
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("dvui", dvui_shim);
    const bench_exe = b.addExecutable(.{
        .name = "bench-icons",
        .root_module = bench_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run Launcher icon/search bench (no GUI)");
    bench_step.dependOn(&run_bench.step);

    // Headless HubUi logic tests (JSON scenarios in test/) – link-light via
    // dvui_shim. Only HubUi's pure helpers are exercised (hubFrame itself is
    // generic and never instantiated here, so no GUI link is needed).
    const hub_ui_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_hub_ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    hub_ui_test_module.addImport("nilebank", nilebank_dep.module("nilebank"));
    hub_ui_test_module.addImport("dvui", dvui_shim);
    const hub_ui_tests = b.addTest(.{
        .root_module = hub_ui_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_hub_ui_tests = b.addRunArtifact(hub_ui_tests);
    const test_hub_ui_step = b.step("test-hub-ui", "Run HubUi logic tests (no GUI)");
    test_hub_ui_step.dependOn(&run_hub_ui_tests.step);
    test_state_step.dependOn(&run_hub_ui_tests.step);
}
