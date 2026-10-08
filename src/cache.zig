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
        var out: [1][8]u64 = undefined;
        self.datasetItems(1, item_number, &out);
        return out[0];
    }

    /// Computes `n` consecutive dataset items starting at `first`. Batching
    /// shares the SuperscalarHash instruction dispatch between items.
    pub fn datasetItems(self: *const Cache, comptime n: usize, first: u64, out: *[n][8]u64) void {
        const mul0: u64 = 6364136223846793005;
        const adds = [_]u64{ 0, 9298411001130361340, 12065312585734608966, 9306329213124626780, 5281919268842080866, 10536153434571861004, 3398623926847679864, 9549104520008361294 };
        var register_value: [n]u64 = undefined;
        for (out, &register_value, 0..) |*rl, *rv, k| {
            const item_number = first + k;
            rl[0] = (item_number +% 1) *% mul0;
            for (1..8) |i| rl[i] = rl[0] ^ adds[i];
            rv.* = item_number;
        }

        const mem = self.bytes();
        const mask: u64 = config.cache_size / config.dataset_item_size - 1;
        for (&self.programs) |*prog| {
            superscalar.executeMany(n, out, prog);
            for (out, &register_value) |*rl, *rv| {
                const mix = mem[(rv.* & mask) * config.dataset_item_size ..][0..64];
                for (rl, 0..) |*r, q| r.* ^= std.mem.readInt(u64, mix[q * 8 ..][0..8], .little);
                rv.* = rl[prog.address_register];
            }
        }
    }
};
