//! The RandomX cache (256 MiB of Argon2d memory plus 8 SuperscalarHash
//! programs) and dataset item generation (dataset.cpp).

const std = @import("std");
const config = @import("config.zig");
const argon2 = @import("argon2.zig");
const superscalar = @import("superscalar.zig");
const memory = @import("memory.zig");

pub const Cache = struct {
    memory: []argon2.Block,
    region: memory.Region,
    programs: [config.cache_accesses]superscalar.Program,
    /// Incremented by every `init`; 0 means not initialized yet. VMs use it
    /// to notice a new key.
    generation: u64,

    pub fn create(gpa: std.mem.Allocator, options: memory.Options) !*Cache {
        const self = try gpa.create(Cache);
        errdefer gpa.destroy(self);
        self.region = try memory.alloc(config.cache_size, options);
        self.memory = std.mem.bytesAsSlice(argon2.Block, self.region.bytes);
        self.generation = 0;
        return self;
    }

    pub fn destroy(self: *Cache, gpa: std.mem.Allocator) void {
        self.region.free();
        gpa.destroy(self);
    }

    pub fn init(self: *Cache, key: []const u8) void {
        argon2.fillCache(self.memory, key);
        var gen = superscalar.Blake2Generator.init(key, 0);
        for (&self.programs) |*p| superscalar.generate(p, &gen);
        self.generation += 1;
    }

    pub fn bytes(self: *const Cache) []const u8 {
        return std.mem.sliceAsBytes(self.memory);
    }

    /// Computes dataset item `item_number` (64 bytes) from the cache.
    pub fn datasetItem(self: *const Cache, item_number: u64) [8]u64 {
        const mul0: u64 = 6364136223846793005;
        const adds = [_]u64{ 0, 9298411001130361340, 12065312585734608966, 9306329213124626780, 5281919268842080866, 10536153434571861004, 3398623926847679864, 9549104520008361294 };
        var rl: [8]u64 = undefined;
        rl[0] = (item_number +% 1) *% mul0;
        for (1..8) |i| rl[i] = rl[0] ^ adds[i];

        const mem = self.bytes();
        const mask: u64 = config.cache_size / config.dataset_item_size - 1;
        var register_value = item_number;
        for (&self.programs) |*prog| {
            const mix = mem[(register_value & mask) * config.dataset_item_size ..][0..64];
            superscalar.execute(&rl, prog);
            for (&rl, 0..) |*r, q| r.* ^= std.mem.readInt(u64, mix[q * 8 ..][0..8], .little);
            register_value = rl[prog.address_register];
        }
        return rl;
    }
};
