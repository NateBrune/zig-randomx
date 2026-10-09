//! Verifies the RandomX test vectors and measures single-thread hash speed.
//!
//!   randomx-bench [--light] [--interpret] [--v1] [--hashes N] [--threads N] [--no-huge-pages] [--chain]
//!
//! --interpret runs programs (and dataset initialization) without the JIT.
//! --v1 hashes with RandomX v1 instead of v2.
//! --chain hashes sequentially (x = hash(x)), as a time-lock would; the
//! default hashes independent nonces, one at a time (no pipelining).

const std = @import("std");
const randomx = @import("randomx");

const Vector = struct { input: []const u8, want: []const u8 };

const vectors = [_]Vector{
    .{ .input = "This is a test", .want = "22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f" },
    .{ .input = "Lorem ipsum dolor sit amet", .want = "9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf" },
    .{ .input = "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua", .want = "4d6b063a1a603751d525f18a171336a4002f2f06df6c17e4b25fe17e17796e42" },
};

const vectors_v1 = [_]Vector{
    .{ .input = "This is a test", .want = "639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f" },
    .{ .input = "Lorem ipsum dolor sit amet", .want = "300a0adb47603dedb42228ccb2b211104f4da45af709cd7547cd049e9489c969" },
    .{ .input = "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua", .want = "c36d4ed4191e617309867ed66a443be4075014e2b061bcdaf9ce7b721d2b77a8" },
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var light = false;
    var chain = false;
    var options: randomx.Options = .{};
    var hashes: usize = 0;
    var threads: usize = std.Thread.getCpuCount() catch 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--light")) {
            light = true;
        } else if (std.mem.eql(u8, args[i], "--interpret")) {
            options.jit = false;
        } else if (std.mem.eql(u8, args[i], "--v1")) {
            options.version = .v1;
        } else if (std.mem.eql(u8, args[i], "--chain")) {
            chain = true;
        } else if (std.mem.eql(u8, args[i], "--no-huge-pages")) {
            options.huge_pages = false;
        } else if (std.mem.eql(u8, args[i], "--hashes") and i + 1 < args.len) {
            i += 1;
            hashes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
            i += 1;
            threads = try std.fmt.parseInt(usize, args[i], 10);
        }
    }
    if (hashes == 0) hashes = if (light) 20 else 200;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // Allocate the dataset before the cache: it is the region that benefits
    // most from huge pages, and a small huge page pool should go to it.
    var dataset: ?*randomx.Dataset = null;
    defer if (dataset) |ds| ds.destroy(gpa);
    if (!light) dataset = try randomx.Dataset.create(gpa, options);

    var t = std.Io.Clock.awake.now(io);
    const cache = try randomx.Cache.create(gpa, options);
    defer cache.destroy(gpa);
    cache.init("test key 000");
    try out.print("cache initialized in {d} ms\n", .{since(io, &t)});
    try out.flush();

    if (dataset) |ds| {
        try ds.init(cache, threads);
        try out.print("dataset initialized in {d} ms ({d} threads)\n", .{ since(io, &t), threads });
        try out.flush();
    }

    const vm = try randomx.Vm.create(gpa, if (dataset) |ds| .{ .fast = ds } else .{ .light = cache }, options);
    defer vm.destroy(gpa);

    var ok = true;
    const checks: []const Vector = switch (options.version) {
        .v1 => &vectors_v1,
        .v2 => &vectors,
    };
    for (checks) |v| {
        var h: [32]u8 = undefined;
        vm.hash(v.input, &h);
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, v.want);
        const pass = std.mem.eql(u8, &h, &want);
        ok = ok and pass;
        try out.print("{s}  {x}  \"{s}\"\n", .{ if (pass) "ok  " else "FAIL", h, v.input });
    }
    if (!ok) return 1;

    var huge_buf: [32]u8 = undefined;
    try out.print("pages: dataset {s}, cache {s}, scratchpad {s}; transparent huge pages in use: {s}\n", .{
        if (dataset) |ds| @tagName(ds.region.kind) else "-",
        @tagName(cache.region.kind),
        @tagName(vm.scratchpad_region.kind),
        if (randomx.memory.hugePageBytes(io)) |b| std.fmt.bufPrint(&huge_buf, "{d} MiB", .{b / (1024 * 1024)}) catch "?" else "unknown",
    });
    try out.flush();

    _ = since(io, &t);
    var h: [32]u8 = @splat(0);
    var nonce: [8]u8 = undefined;
    for (0..hashes) |n| {
        if (chain) {
            vm.hash(&h, &h);
        } else {
            std.mem.writeInt(u64, &nonce, n, .little);
            vm.hash(&nonce, &h);
        }
    }
    const ms = since(io, &t);
    try out.print("{s}, {s} mode, {s}, {s}: {d} hashes in {d} ms = {d:.1} H/s on one thread\n", .{
        @tagName(options.version),
        if (light) "light" else "fast",
        if (options.jit) "JIT" else "interpreter",
        if (chain) "chained" else "independent",
        hashes,
        ms,
        @as(f64, @floatFromInt(hashes)) * 1000 / @as(f64, @floatFromInt(@max(ms, 1))),
    });
    return 0;
}

fn since(io: std.Io, t: *std.Io.Timestamp) i64 {
    const now = std.Io.Clock.awake.now(io);
    defer t.* = now;
    return @intCast(@divTrunc(now.nanoseconds - t.nanoseconds, std.time.ns_per_ms));
}
