const std = @import("std");

/// glint build script. The build graph defines:
///   - "glint" public engine library module (rooted at src/root.zig)
///   - "glint" CLI executable (rooted at src/main.zig)
///   - "run" / "test" top-level steps
///   - sokol-zig dependency wired into the engine library module
///
/// Cross-compile examples:
///   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
///   zig build -Dtarget=aarch64-linux-musl
///   zig build -Dtarget=aarch64-macos
///   zig build -Dtarget=x86_64-windows-gnu
///   zig build -Dtarget=wasm32-freestanding (W11+, see doc/roadmap.md)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // sokol-zig provides our window / GPU / audio / input layer. Pinned
    // to a specific commit in build.zig.zon for reproducibility.
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokol_mod = sokol_dep.module("sokol");

    // Public engine library. Anything cart authors or downstream embedders
    // can rely on must be re-exported through src/root.zig.
    const mod = b.addModule("glint", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "sokol", .module = sokol_mod },
        },
    });

    // CLI executable. main.zig sees the engine via @import("glint").
    const exe = b.addExecutable(.{
        .name = "glint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glint", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // `zig build run -- <args>` invokes the installed binary with passthrough args.
    const run_step = b.step("run", "Run the glint CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests cover both the library face (root.zig + everything it transitively
    // imports) and the CLI dispatch (main.zig). Two separate test executables
    // because each test exe roots in a single module.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
