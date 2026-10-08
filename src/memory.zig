//! Large allocations (dataset, cache, scratchpad), backed by huge pages when
//! possible.
//!
//! RandomX reads the dataset and scratchpad at random addresses; with 4 KiB
//! pages most of those reads also miss the TLB. 2 MiB pages avoid that.
//!
//! Linux offers two mechanisms, tried in this order:
//!  1. Explicit huge pages (`MAP_HUGETLB`): guaranteed 2 MiB pages from a pool
//!     that root must reserve first (`sysctl vm.nr_hugepages=N`).
//!  2. Transparent huge pages (`madvise(MADV_HUGEPAGE)`): no setup, but the
//!     kernel only backs what it can find contiguous memory for.

const std = @import("std");
const builtin = @import("builtin");

pub const huge_page_size = 2 * 1024 * 1024;

pub const Options = struct {
    /// Use huge pages when available: explicit first, then transparent.
    /// Falls back to normal pages silently.
    huge_pages: bool = true,
};

pub const PageKind = enum {
    /// Normal 4 KiB pages.
    normal,
    /// Transparent huge pages were requested; coverage is best effort.
    transparent,
    /// Every page is an explicit 2 MiB huge page.
    explicit,
};

/// A page-aligned region, 2 MiB aligned when huge pages were requested.
pub const Region = struct {
    bytes: []align(std.heap.page_size_min) u8,
    /// The whole mapping, which may be larger than `bytes` for alignment.
    mapping: []align(std.heap.page_size_min) u8,
    kind: PageKind,

    pub fn free(self: Region) void {
        std.posix.munmap(self.mapping);
    }
};

pub fn alloc(size: usize, options: Options) !Region {
    if (options.huge_pages and builtin.os.tag == .linux) {
        if (allocExplicit(size)) |r| return r else |_| {}
        return allocTransparent(size);
    }
    const mapping = try map(size, false);
    return .{ .bytes = mapping[0..size], .mapping = mapping, .kind = .normal };
}

fn map(len: usize, hugetlb: bool) ![]align(std.heap.page_size_min) u8 {
    return std.posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = hugetlb },
        -1,
        0,
    );
}

/// Fails (typically `error.OutOfMemory`) when the reserved pool is too small.
fn allocExplicit(size: usize) !Region {
    const len = std.mem.alignForward(usize, size, huge_page_size);
    const mapping = try map(len, true);
    return .{ .bytes = mapping[0..size], .mapping = mapping, .kind = .explicit };
}

fn allocTransparent(size: usize) !Region {
    // Over-allocate so a 2 MiB-aligned start exists; THP only applies to
    // aligned 2 MiB ranges.
    const mapping = try map(size + huge_page_size, false);
    const start = std.mem.alignForward(usize, @intFromPtr(mapping.ptr), huge_page_size);
    const bytes: []align(std.heap.page_size_min) u8 = @alignCast(@as([*]u8, @ptrFromInt(start))[0..size]);
    // Best effort: the kernel may have transparent huge pages disabled.
    std.posix.madvise(bytes.ptr, size, std.os.linux.MADV.HUGEPAGE) catch {};
    return .{ .bytes = bytes, .mapping = mapping, .kind = .transparent };
}

/// Bytes of this process backed by transparent huge pages, from
/// /proc/self/smaps_rollup (Linux), for diagnostics. Explicit huge pages
/// are not counted here.
pub fn hugePageBytes(io: std.Io) ?u64 {
    var buf: [4096]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, "/proc/self/smaps_rollup", &buf) catch return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "AnonHugePages:")) continue;
        var it = std.mem.tokenizeAny(u8, line["AnonHugePages:".len..], " \tkB");
        const kb = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        return kb * 1024;
    }
    return null;
}
