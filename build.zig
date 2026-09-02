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
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
