//! The full ~2 GiB RandomX dataset, built from the cache by JIT-compiled
//! SuperscalarHash code shared across threads (or by the portable
//! SuperscalarHash executor when the JIT is off).

const std = @import("std");
const config = @import("config.zig");
const Cache = @import("cache.zig").Cache;
const jit = @import("jit/x86.zig");
const memory = @import("memory.zig");

pub const Dataset = struct {
    memory: []align(std.heap.page_size_min) u8,
    region: memory.Region,
    jit: bool,

    pub const size = config.dataset_size;
    pub const item_count = config.dataset_items;

    pub fn create(gpa: std.mem.Allocator, options: memory.Options) !*Dataset {
        const self = try gpa.create(Dataset);
        errdefer gpa.destroy(self);
        self.region = try memory.alloc(size, options);
        self.memory = self.region.bytes;
        self.jit = options.jit;
        return self;
    }

    pub fn destroy(self: *Dataset, gpa: std.mem.Allocator) void {
        self.region.free();
        gpa.destroy(self);
    }

    /// Computes every item from `cache` using `threads` threads.
    pub fn init(self: *Dataset, cache: *const Cache, threads: usize) !void {
        var compiler: ?jit.Compiler = if (self.jit) try jit.Compiler.init() else null;
        defer if (compiler) |*c| c.deinit();
        if (compiler) |*c| {
            c.generateSuperscalarHash(&cache.programs);
            c.generateDatasetInitCode();
        }
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
            handles[t] = if (compiler) |*c|
                try std.Thread.spawn(.{}, initRange, .{ c.datasetInitFn(), &cache_memory, self.memory.ptr, start, end })
            else
                try std.Thread.spawn(.{}, initRangePortable, .{ cache, self.memory.ptr, start, end });
            spawned += 1;
        }
    }

    fn initRange(func: jit.DatasetInitFn, cache_memory: *const [*]const u8, out: [*]u8, start: u64, end: u64) void {
        func(cache_memory, out + start * config.dataset_item_size, start, end);
    }

    fn initRangePortable(cache: *const Cache, out: [*]u8, start: u64, end: u64) void {
        const batch = 16;
        var n = start;
        while (n < end) {
            var items: [batch][8]u64 = undefined;
            const count = @min(batch, end - n);
            if (count == batch) cache.datasetItems(batch, n, &items) else {
                for (items[0..count], 0..) |*item, k| item.* = cache.datasetItem(n + k);
            }
            for (items[0..count], 0..) |item, k| {
                const p = out[(n + k) * config.dataset_item_size ..][0..config.dataset_item_size];
                for (item, 0..) |x, i| std.mem.writeInt(u64, p[i * 8 ..][0..8], x, .little);
            }
            n += count;
        }
    }
};
