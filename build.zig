const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const llvm = b.option(bool, "llvm", "enables llvm");
    const lld = b.option(bool, "lld", "enables lld");

    // System sd-bus API via translateC (src/sd_bus.h -> <systemd/sd-bus.h>).
    // Imported as `@import("sd_bus")` by src/Dbus.zig; linked as -lsystemd.
    const sd_bus_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/sd_bus.h"),
        .target = target,
        .optimize = optimize,
    });
    const sd_bus_mod = sd_bus_tc.createModule();
    // Declarations only: must not pull -lc into the libc-free headless test
    // binaries (test-state, test-net). Final binaries link libc + systemd
    // via their own modules.
    sd_bus_mod.link_libc = false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),

        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    exe_mod.addImport("sd_bus", sd_bus_mod);
    const exe = b.addExecutable(.{
        .name = "nshell",
        .root_module = exe_mod,
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
    // icon library (sized SVG->TVG at runtime). wire_dvui=false so the tabler
    // module uses our dvui instance below: shared types (dvui.Size) and the
    // per-window TVG cache. Its own dvui pin differs from ours.
    const tabler_dep = b.dependency("tabler_zig", .{
        .target = target,
        .optimize = optimize,
        .wire_dvui = false,
    });
    const tabler_mod = tabler_dep.module("tabler");
    tabler_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("tabler", tabler_mod);
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
    state_test_module.addImport("sd_bus", sd_bus_mod);

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

    const bench_net_module = b.createModule(.{
        .root_source_file = b.path("src/bench_net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_net_module.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    bench_net_module.addImport("sd_bus", sd_bus_mod);
    const bench_net_exe = b.addExecutable(.{
        .name = "bench-net",
        .root_module = bench_net_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_bench_net = b.addRunArtifact(bench_net_exe);
    const bench_net_step = b.step("bench-net", "Run NetworkManager/BlueZ bench (needs system bus)");
    bench_net_step.dependOn(&run_bench_net.step);

    // Headless network-panel layout probe (src/layout_probe.zig): runs the
    // REAL hubFrame against dvui's link-light testing backend (backend =
    // .custom + our own backend module from dvui's src/backends/testing.zig),
    // with every C-heavy option off (stb_truetype fonts, no freetype/sdl/
    // tree_sitter). Prints measured widget geometry for the password row so
    // layout issues can be diagnosed without a Wayland session.
    const dvui_custom_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
        .libc = true,
        .freetype = false,
        .@"tiny-file-dialogs" = false,
        .@"stb-image" = false,
        .@"tree-sitter" = false,
    });
    const dvui_custom_mod = dvui_custom_dep.module("dvui");
    const testing_backend_mod = dvui_custom_dep.builder.createModule(.{
        .root_source_file = dvui_custom_dep.path("src/backends/testing.zig"),
        .target = target,
        .optimize = optimize,
    });
    testing_backend_mod.addImport("dvui", dvui_custom_mod);
    dvui_custom_mod.addImport("backend", testing_backend_mod);

    const probe_tabler_mod = b.createModule(.{
        .root_source_file = b.path("src/tabler_probe_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_tabler_mod.addImport("dvui", dvui_custom_mod);

    const probe_module = b.createModule(.{
        .root_source_file = b.path("src/layout_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    probe_module.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    // dvui's stb_image impl: the testing backend never decodes images, but
    // Texture.ImageSource/Color.PMAImage get analyzed and reference
    // stbi_*; ship the impl so the link resolves (stb-image was disabled in
    // the dep options only to keep translate-c light).
    probe_module.addCSourceFile(.{
        .file = dvui_custom_dep.path("vendor/stb/stb_image_impl.c"),
    });
    probe_module.addImport("dvui", dvui_custom_mod);
    probe_module.addImport("sd_bus", sd_bus_mod);
    probe_module.addImport("tabler", probe_tabler_mod);
    probe_module.addImport("nilebank", nilebank_dep.module("nilebank"));
    const probe_exe = b.addExecutable(.{
        .name = "layout-probe",
        .root_module = probe_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_probe = b.addRunArtifact(probe_exe);
    const probe_step = b.step("layout-probe", "Dump network panel geometry headlessly (no GUI)");
    probe_step.dependOn(&run_probe.step);

    // Headless HubUi logic tests (JSON scenarios in test/) – link-light via
    // dvui_shim. Only HubUi's pure helpers are exercised (hubFrame itself is
    // generic and never instantiated here, so no GUI link is needed).
    // `@import("tabler")` in HubUi.zig/Icons.zig resolves to a stub (see
    // src/tabler_shim.zig): the real tabler module needs dvui's SVG->TVG
    // pipeline, which the shim omits; tests never call Icons.iconPx.
    const tabler_shim = b.createModule(.{
        .root_source_file = b.path("src/tabler_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    tabler_shim.addImport("dvui", dvui_shim);
    const hub_ui_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_hub_ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    hub_ui_test_module.addImport("nilebank", nilebank_dep.module("nilebank"));
    hub_ui_test_module.addImport("dvui", dvui_shim);
    hub_ui_test_module.addImport("tabler", tabler_shim);
    hub_ui_test_module.addImport("sd_bus", sd_bus_mod);
    const hub_ui_tests = b.addTest(.{
        .root_module = hub_ui_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_hub_ui_tests = b.addRunArtifact(hub_ui_tests);
    const test_hub_ui_step = b.step("test-hub-ui", "Run HubUi logic tests (no GUI)");
    test_hub_ui_step.dependOn(&run_hub_ui_tests.step);
    test_state_step.dependOn(&run_hub_ui_tests.step);

    // Net unit tests (src/Net.zig). Needs the sd_bus import: Net.zig reaches
    // it via Dbus.zig, whose C calls are stubbed out in test builds, so no
    // live bus is required.
    const net_test_module = b.createModule(.{
        .root_source_file = b.path("src/Net.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_test_module.addImport("sd_bus", sd_bus_mod);
    const net_tests = b.addTest(.{
        .root_module = net_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_net_tests = b.addRunArtifact(net_tests);
    const test_net_step = b.step("test-net", "Run Net unit tests (no GUI, no bus)");
    test_net_step.dependOn(&run_net_tests.step);
    test_state_step.dependOn(&run_net_tests.step);

    // Aliased-icon helper tests (src/Icons.zig). Only the pure threshold
    // helper is exercised: iconPx needs a window, which the headless
    // builds don't have (tabler resolves to the stub, dvui to the shim).
    const icons_test_module = b.createModule(.{
        .root_source_file = b.path("src/Icons.zig"),
        .target = target,
        .optimize = optimize,
    });
    icons_test_module.addImport("dvui", dvui_shim);
    icons_test_module.addImport("tabler", tabler_shim);
    const icons_tests = b.addTest(.{
        .root_module = icons_test_module,
        .use_llvm = llvm,
        .use_lld = lld,
    });
    const run_icons_tests = b.addRunArtifact(icons_tests);
    const test_icons_step = b.step("test-icons", "Run Icons threshold tests (no GUI)");
    test_icons_step.dependOn(&run_icons_tests.step);
    test_state_step.dependOn(&run_icons_tests.step);
}
