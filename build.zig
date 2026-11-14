const std = @import("std");
const zig_hook = @import("zig_hook");

pub fn build(b: *std.Build) void {
    _ = zig_hook.addDartExecutable(b, .{
        .name = "process_group_helper",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{
            .preferred_optimize_mode = .ReleaseSmall,
        }),
    });
}
