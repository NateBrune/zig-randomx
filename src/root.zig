//! RandomX v2 in Zig, with an x86-64 JIT.
//!
//! ```
//! const cache = try randomx.Cache.create(gpa, .{});
//! cache.init("key");
//! const vm = try randomx.Vm.create(gpa, .{ .light = cache }, .{});
//! var out: [32]u8 = undefined;
//! vm.hash("input", &out);
//! ```

pub const config = @import("config.zig");
pub const argon2 = @import("argon2.zig");
pub const superscalar = @import("superscalar.zig");
pub const aes = @import("aes.zig");
pub const Cache = @import("cache.zig").Cache;
pub const Dataset = @import("dataset.zig").Dataset;
pub const Vm = @import("vm.zig").Vm;
pub const Source = @import("vm.zig").Source;
pub const hash_size = @import("vm.zig").hash_size;
pub const hasHardwareAes = @import("vm.zig").hasHardwareAes;
pub const memory = @import("memory.zig");
pub const Options = memory.Options;

test {
    _ = @import("tests.zig");
}
