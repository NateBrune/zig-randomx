//! Differential test against the reference implementation: reads lines of
//! `key_hex input_hex hash_hex` ("-" for empty) on stdin, recomputes each
//! hash and reports mismatches.
//!
//!   ref_hashes 20 500 1 | randomx-verify [--fast] [--threads N]
//!   randomx-verify --dump-dataset KEY [--threads N] > dataset.bin
//!   ref_superscalar 100000 1000000 1 | randomx-verify --superscalar

const std = @import("std");
const randomx = @import("randomx");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var fast = false;
    var dump_key: ?[]const u8 = null;
    var threads: usize = std.Thread.getCpuCount() catch 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--fast")) fast = true;
        if (std.mem.eql(u8, args[i], "--dump-dataset") and i + 1 < args.len) {
            i += 1;
            dump_key = args[i];
        }
        if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
            i += 1;
            threads = try std.fmt.parseInt(usize, args[i], 10);
        }
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "--dump-jit")) {
        // Writes the JIT buffer after one light-mode hash, for disassembly.
        const cache = try randomx.Cache.create(gpa, .{});
        defer cache.destroy(gpa);
        cache.init("test key 000");
        const vm = try randomx.Vm.create(gpa, .{ .light = cache }, .{});
        defer vm.destroy(gpa);
        var h: [32]u8 = undefined;
        vm.hash("This is a test", &h);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = vm.compiler.code });
        return 0;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--superscalar")) return superscalarCheck(io);

    if (dump_key) |key| {
        const cache = try randomx.Cache.create(gpa, .{});
        defer cache.destroy(gpa);
        cache.init(key);
        const ds = try randomx.Dataset.create(gpa, .{});
        defer ds.destroy(gpa);
        try ds.init(cache, threads);
        try std.Io.File.stdout().writeStreamingAll(io, ds.memory);
        return 0;
    }

    var in_buf: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var dataset: ?*randomx.Dataset = null;
    defer if (dataset) |ds| ds.destroy(gpa);
    if (fast) dataset = try randomx.Dataset.create(gpa, .{});
    const cache = try randomx.Cache.create(gpa, .{});
    defer cache.destroy(gpa);
    var vm: ?*randomx.Vm = null;
    defer if (vm) |v| v.destroy(gpa);

    var key_buf: [2048]u8 = undefined;
    var current_key: ?[]u8 = null;
    var checked: usize = 0;
    var failed: usize = 0;
    var keys: usize = 0;
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const key_hex = it.next() orelse continue;
        const input_hex = it.next() orelse continue;
        const hash_hex = it.next() orelse continue;

        var kb: [1000]u8 = undefined;
        const key = try unhex(&kb, key_hex);
        if (current_key == null or !std.mem.eql(u8, current_key.?, key)) {
            @memcpy(key_buf[0..key.len], key);
            current_key = key_buf[0..key.len];
            cache.init(key);
            if (dataset) |ds| try ds.init(cache, threads);
            if (vm == null) vm = try randomx.Vm.create(gpa, if (dataset) |ds| .{ .fast = ds } else .{ .light = cache }, .{});
            keys += 1;
        }

        var ib: [1000]u8 = undefined;
        const input = try unhex(&ib, input_hex);
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, hash_hex);
        var got: [32]u8 = undefined;
        vm.?.hash(input, &got);
        checked += 1;
        if (!std.mem.eql(u8, &got, &want)) {
            failed += 1;
            try out.print("MISMATCH key={s} input={s}\n  want {s}\n  got  {x}\n", .{ key_hex, input_hex, hash_hex, got });
            try out.flush();
        }
    }
    try out.print("{s} mode: {d} hashes across {d} keys checked, {d} mismatches\n", .{ if (fast) "fast" else "light", checked, keys, failed });
    return if (failed == 0 and checked > 0) 0 else 1;
}

fn unhex(buf: []u8, s: []const u8) ![]u8 {
    if (std.mem.eql(u8, s, "-")) return buf[0..0];
    return std.fmt.hexToBytes(buf, s);
}

/// Compares SuperscalarHash programs (FNV-1a digest per key, as computed by
/// ref_superscalar) and reciprocals against the reference.
fn superscalarCheck(io: std.Io) !u8 {
    var in_buf: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var programs: usize = 0;
    var rcps: usize = 0;
    var failed: usize = 0;
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const first = it.next() orelse continue;
        if (std.mem.eql(u8, first, "rcp")) {
            const d = try std.fmt.parseInt(u32, it.next().?, 10);
            const want = try std.fmt.parseInt(u64, it.next().?, 10);
            rcps += 1;
            if (randomx.superscalar.reciprocal(d) != want) {
                failed += 1;
                std.debug.print("reciprocal mismatch for {d}\n", .{d});
            }
            continue;
        }
        var kb: [100]u8 = undefined;
        const key = try unhex(&kb, first);
        const want = try std.fmt.parseInt(u64, it.next().?, 16);
        var gen = randomx.superscalar.Blake2Generator.init(key, 0);
        var h: u64 = 0xcbf29ce484222325;
        var prog: randomx.superscalar.Program = undefined;
        for (0..8) |_| {
            randomx.superscalar.generate(&prog, &gen);
            h = fnv(h, std.mem.sliceAsBytes(prog.slice()));
            h = fnv(h, &.{ prog.address_register, @truncate(prog.size) });
        }
        programs += 8;
        if (h != want) {
            failed += 1;
            std.debug.print("superscalar mismatch for key {s}\n", .{first});
        }
    }
    std.debug.print("{d} SuperscalarHash programs and {d} reciprocals checked, {d} mismatches\n", .{ programs, rcps, failed });
    return if (failed == 0) 0 else 1;
}

fn fnv(h0: u64, bytes: []const u8) u64 {
    var h = h0;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}
