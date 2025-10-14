//TAKEN FROM HERE: https://codeberg.org/Luciogi/zig-http-server-from-scratch/src/branch/main/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{ .name = "http_server", .root_module = b.createModule(.{ .root_source_file = b.path("./src/main.zig"), .target = b.graph.host }) });

    b.installArtifact(exe);
    const run_artifact = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the project");
    run_step.dependOn(&run_artifact.step);
}
