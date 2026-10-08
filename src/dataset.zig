//! The full ~2 GiB RandomX dataset, built from the cache by JIT-compiled
//! SuperscalarHash code shared across threads.

const std = @import("std");
const config = @import("config.zig");
const Cache = @import("cache.zig").Cache;
const jit = @import("jit/x86.zig");
const memory = @import("memory.zig");

pub const Dataset = struct {
    memory: []align(std.heap.page_size_min) u8,
    region: memory.Region,

    pub const size = config.dataset_size;
    pub const item_count = config.dataset_items;

    pub fn create(gpa: std.mem.Allocator, options: memory.Options) !*Dataset {
        const self = try gpa.create(Dataset);
        errdefer gpa.destroy(self);
        self.region = try memory.alloc(size, options);
        self.memory = self.region.bytes;
        return self;
    }

    pub fn destroy(self: *Dataset, gpa: std.mem.Allocator) void {
        self.region.free();
        gpa.destroy(self);
    }

    /// Computes every item from `cache` using `threads` threads.
    pub fn init(self: *Dataset, cache: *const Cache, threads: usize) !void {
        var compiler = try jit.Compiler.init();
        defer compiler.deinit();
        compiler.generateSuperscalarHash(&cache.programs);
        compiler.generateDatasetInitCode();
        const func = compiler.datasetInitFn();
        const cache_memory: [*]const u8 = cache.bytes().ptr;

        const n = @max(threads, 1);
        const per = item_count / n;
        var handles: [256]std.Thread = undefined;
        const count = @min(n, handles.len);
        var spawned: usize = 0;
        defer for (handles[0..spawned]) |h| h.join();
        for (0..count) |t| {
            const start = t * per;
            const end = if (t == count - 1) item_count else start + per;
            handles[t] = try std.Thread.spawn(.{}, initRange, .{ func, &cache_memory, self.memory.ptr, start, end });
            spawned += 1;
        }
    }

    fn initRange(func: jit.DatasetInitFn, cache_memory: *const [*]const u8, out: [*]u8, start: u64, end: u64) void {
        func(cache_memory, out + start * config.dataset_item_size, start, end);
    }
};
