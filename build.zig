const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const randomx = b.addModule("randomx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The JIT's fixed code fragments.
    randomx.addAssemblyFile(b.path("src/jit/x86_static.S"));

    const tests = b.addTest(.{ .root_module = randomx });
    const test_step = b.step("test", "Run the RandomX test vectors");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const bench = b.addExecutable(.{
        .name = "randomx-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "randomx", .module = randomx }},
        }),
    });
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run the hashing benchmark").dependOn(&run_bench.step);

    const verify = b.addExecutable(.{
        .name = "randomx-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "randomx", .module = randomx }},
        }),
    });
    b.installArtifact(verify);
}
