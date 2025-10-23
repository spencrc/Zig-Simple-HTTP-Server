const std = @import("std");

//TAKEN FROM HERE: https://codeberg.org/Luciogi/zig-http-server-from-scratch/src/branch/main/build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "http_server",
        .root_module = exe_mod,
    });

    var static_dir = std.fs.cwd().openDir("src/static", .{ .iterate = true }) catch @panic("openIterableDir");
    defer static_dir.close();
    var walker = static_dir.walk(b.allocator) catch @panic("walk");
    defer walker.deinit();
    //const copy_write_files = b.addWriteFiles();
    var file = std.fs.cwd().createFile("src/static.zig", .{}) catch @panic("failed to create file");
    defer file.close();

    // var allocating = std.io.Writer.Allocating.init(b.allocator);
    // defer allocating.deinit();

    var writer = file.writer(&.{});
    const writer_interface = &writer.interface;

    _ = writer_interface.writeAll(
        \\const std = @import("std");
        \\pub const FileData = struct { contents: []const u8, mime_type: []const u8 };
        \\pub const files = std.StaticStringMap(FileData).initComptime(.{
    ) catch @panic("write failed");

    while (walker.next() catch @panic("walk")) |entry| {
        if (entry.kind == .file) {
            writer_interface.print(".{{\"/{s}\", FileData{{ .contents = @embedFile(\"static/{s}\"), .mime_type = \"{s}\" }}}},\n", .{ entry.basename, entry.basename, get_mime_type(entry.basename) }) catch @panic("write failed");
        }
    }

    _ = writer_interface.writeAll("});") catch @panic("write failed");
    //std.debug.print("=== Generated src/static.zig ===\n{s}\n===============================\n", .{allocating.written()});

    //const copy_ouput = copy_write_files.add("src/static.zig", allocating.written());
    //exe.root_module.addAnonymousImport("static", .{ .root_source_file = copy_ouput });

    exe.root_module.addAnonymousImport("config", .{
        .root_source_file = b.path("config.zon"),
    });

    b.installArtifact(exe);

    const run_artifact = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the project");
    run_step.dependOn(&run_artifact.step);
}

fn get_mime_type(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".css")) return "text/css";
    if (std.mem.endsWith(u8, name, ".html")) return "text/html";
    if (std.mem.endsWith(u8, name, ".js")) return "application/javascript";
    return "text/plain";
}
