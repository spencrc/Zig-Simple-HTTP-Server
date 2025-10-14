const std = @import("std");
const assetpack = @import("assetpack");

//TAKEN FROM HERE: https://codeberg.org/Luciogi/zig-http-server-from-scratch/src/branch/main/build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "static", .module = assetpack.pack(b, b.path("static"), .{}) },
        },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_artifact = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the project");
    run_step.dependOn(&run_artifact.step);
}
