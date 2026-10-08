//! Official test vectors from RandomX's src/tests/tests.cpp.

const std = @import("std");
const testing = std.testing;
const rx = @import("root.zig");

test "cache initialization" {
    const cache = try rx.Cache.create(testing.allocator, .{});
    defer cache.destroy(testing.allocator);
    rx.argon2.fillCache(cache.memory, "test key 000");
    const words: []align(1) const u64 = std.mem.bytesAsSlice(u64, cache.bytes());
    try testing.expectEqual(@as(u64, 0x191e0e1d23c02186), words[0]);
    try testing.expectEqual(@as(u64, 0xf1b62fe6210bf8b1), words[1568413]);
    try testing.expectEqual(@as(u64, 0x1f47f056d05cd99b), words[33554431]);
}

test "SuperscalarHash generator" {
    const refs = [_][]const u8{
        "d3a4a6623738756f77e6104469102f082eff2a3e60be7ad696285ef7dfc72a61",
        "f5e7e0bbc7e93c609003d6359208688070afb4a77165a552ff7be63b38dfbc86",
        "85ed8b11734de5b3e9836641413a8f36e99e89694f419c8cd25c3f3f16c40c5a",
        "5dd956292cf5d5704ad99e362d70098b2777b2a1730520be52f772ca48cd3bc0",
        "6f14018ca7d519e9b48d91af094c0f2d7e12e93af0228782671a8640092af9e5",
        "134be097c92e2c45a92f23208cacd89e4ce51f1009a0b900dbe83b38de11d791",
        "268f9392c20c6e31371a5131f82bd7713d3910075f2f0468baafaa1abd2f3187",
        "c668a05fd909714ed4a91e8d96d67b17e44329e88bc71e0672b529a3fc16be47",
        "99739351315840963011e4c5d8e90ad0bfed3facdcb713fe8f7138fbf01c4c94",
        "14ab53d61880471f66e80183968d97effd5492b406876060e595fcf9682f9295",
    };
    var gen = rx.superscalar.Blake2Generator.init("test key 000", 0);
    var prog: rx.superscalar.Program = undefined;
    for (refs) |ref| {
        rx.superscalar.generate(&prog, &gen);
        var h: [32]u8 = undefined;
        std.crypto.hash.blake2.Blake2b256.hash(std.mem.sliceAsBytes(prog.slice()), &h, .{});
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, ref);
        try testing.expectEqualSlices(u8, &want, &h);
    }
}

test "reciprocal" {
    const cases = [_][2]u64{
        .{ 3, 12297829382473034410 },     .{ 13, 11351842506898185609 },
        .{ 33, 17887751829051686415 },    .{ 65537, 18446462603027742720 },
        .{ 15000001, 10316166306300415204 }, .{ 3845182035, 10302264209224146340 },
        .{ 0xffffffff, 9223372039002259456 },
    };
    for (cases) |c| try testing.expectEqual(c[1], rx.superscalar.reciprocal(@intCast(c[0])));
}

test "dataset initialization" {
    const cache = try rx.Cache.create(testing.allocator, .{});
    defer cache.destroy(testing.allocator);
    cache.init("test key 000");
    try testing.expectEqual(@as(u64, 0x680588a85ae222db), cache.datasetItem(0)[0]);
    try testing.expectEqual(@as(u64, 0x7943a1f6186ffb72), cache.datasetItem(10000000)[0]);
    try testing.expectEqual(@as(u64, 0x9035244d718095e1), cache.datasetItem(20000000)[0]);
    try testing.expectEqual(@as(u64, 0x145a5091f7853099), cache.datasetItem(30000000)[0]);
}

test "AesGenerator1R" {
    var state: [64]u8 = @splat(0);
    _ = try std.fmt.hexToBytes(state[0..32], "6c19536eb2de31b6c0065f7f116e86f960d8af0c57210a6584c3237b9d064dc7");
    var out: [64]u8 = undefined;
    rx.aes.fill1Rx4(&state, &out);
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "fa89397dd6ca422513aeadba3f124b5540324c4ad4b6db434394307a17c833ab");
    try testing.expectEqualSlices(u8, &want, state[0..32]);
}

const HashCase = struct { key: []const u8, input: []const u8, hex_input: bool = false, want: []const u8 };

// RandomX v2 expectations from tests.cpp ("interpreter v2" / "compiler v2").
const hash_cases = [_]HashCase{
    .{ .key = "test key 000", .input = "This is a test", .want = "22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f" },
    .{ .key = "test key 000", .input = "Lorem ipsum dolor sit amet", .want = "9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf" },
    .{ .key = "test key 000", .input = "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua", .want = "4d6b063a1a603751d525f18a171336a4002f2f06df6c17e4b25fe17e17796e42" },
    .{ .key = "test key 001", .input = "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua", .want = "97024134686ce27d362ea8d86d8ef16483ac272abdabd46ef13359400777fe5e" },
    .{ .key = "test key 001", .hex_input = true, .input = "0b0b98bea7e805e0010a2126d287a2a0cc833d312cb786385a7c2f9de69d25537f584a9bc9977b00000000666fd8753bf61a8631f12984e3fd44f4014eca629276817b56f32e9b68bd82f416", .want = "c8e92c5f7c1946fecf06bc382b92e3111da38ee3e6a5ad90704e1a9d8aaf6e76" },
};

test "hash test vectors (light mode, JIT)" {
    const gpa = testing.allocator;
    const cache = try rx.Cache.create(gpa, .{});
    defer cache.destroy(gpa);
    var last_key: []const u8 = "";
    const vm = try rx.Vm.create(gpa, .{ .light = cache }, .{});
    defer vm.destroy(gpa);
    for (hash_cases) |c| {
        if (!std.mem.eql(u8, c.key, last_key)) {
            cache.init(c.key);
            last_key = c.key;
        }
        var buf: [256]u8 = undefined;
        const input = if (c.hex_input) try std.fmt.hexToBytes(&buf, c.input) else c.input;
        var out: [32]u8 = undefined;
        vm.hash(input, &out);
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, c.want);
        try testing.expectEqualSlices(u8, &want, &out);
    }
}

test "JIT dataset initialization matches the reference items" {
    const gpa = testing.allocator;
    const cache = try rx.Cache.create(gpa, .{});
    defer cache.destroy(gpa);
    cache.init("test key 000");

    const jit = @import("jit/x86.zig");
    var compiler = try jit.Compiler.init();
    defer compiler.deinit();
    compiler.generateSuperscalarHash(&cache.programs);
    compiler.generateDatasetInitCode();
    const cache_memory: [*]const u8 = cache.bytes().ptr;

    for ([_]u64{ 0, 10000000, 20000000, 30000000, rx.Dataset.item_count - 8 }) |start| {
        var buf: [8][8]u64 align(64) = undefined;
        compiler.datasetInitFn()(&cache_memory, std.mem.asBytes(&buf), start, start + 8);
        for (buf, 0..) |item, k| try testing.expectEqual(cache.datasetItem(start + k), item);
    }
    try testing.expectEqual(@as(u64, 0x680588a85ae222db), blk: {
        var one: [8]u64 align(64) = undefined;
        compiler.datasetInitFn()(&cache_memory, std.mem.asBytes(&one), 0, 1);
        break :blk one[0];
    });
}

test "hashing preserves the caller's MXCSR and does not depend on it" {
    const gpa = testing.allocator;
    const cache = try rx.Cache.create(gpa, .{});
    defer cache.destroy(gpa);
    cache.init("test key 000");
    const vm = try rx.Vm.create(gpa, .{ .light = cache }, .{});
    defer vm.destroy(gpa);

    const vm_mod = @import("vm.zig");
    const saved = vm_mod.getMxcsrForTest();
    defer vm_mod.setMxcsrForTest(saved);

    // Round toward minus infinity, without FTZ/DAZ: unlike RandomX's default.
    const caller_mode: u32 = 0x1f80 | (1 << 13);
    vm_mod.setMxcsrForTest(caller_mode);
    var out: [32]u8 = undefined;
    vm.hash("Lorem ipsum dolor sit amet", &out);
    try testing.expectEqual(caller_mode, vm_mod.getMxcsrForTest());

    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf");
    try testing.expectEqualSlices(u8, &want, &out);
}

test "hashing in place (input aliases output) matches" {
    const gpa = testing.allocator;
    const cache = try rx.Cache.create(gpa, .{});
    defer cache.destroy(gpa);
    cache.init("test key 000");
    const vm = try rx.Vm.create(gpa, .{ .light = cache }, .{});
    defer vm.destroy(gpa);

    var x: [32]u8 = @splat(7);
    var separate: [32]u8 = undefined;
    vm.hash(&x, &separate);
    vm.hash(&x, &x);
    try testing.expectEqualSlices(u8, &separate, &x);
}
