//! RandomX parameters (configuration.h in the reference implementation).

/// Cache size in KiB (Argon2 blocks).
pub const argon_memory = 262144;
pub const argon_iterations = 3;
pub const argon_lanes = 1;
pub const argon_salt = "RandomX\x03";

pub const cache_accesses = 8;
pub const superscalar_latency = 170;

pub const dataset_base_size: u64 = 2147483648;
pub const dataset_extra_size: u64 = 33554368;
pub const dataset_item_size = 64;

/// RandomX v1 runs 256-instruction programs, v2 runs 384. Program buffers are
/// always sized for the larger one.
pub const program_size_v1 = 256;
pub const program_size_v2 = 384;
pub const program_max_size = program_size_v2;
pub const program_iterations = 2048;
pub const program_count = 8;

pub const scratchpad_l3 = 2097152;
pub const scratchpad_l2 = 262144;
pub const scratchpad_l1 = 16384;

/// RandomX version. Monero used v1 from its November 2019 fork; v2 changes
/// the program size, CFROUND, the F/E mix and which register is mixed.
pub const Version = enum {
    v1,
    v2,

    pub fn programSize(v: Version) usize {
        return switch (v) {
            .v1 => program_size_v1,
            .v2 => program_size_v2,
        };
    }
};

pub const jump_bits = 8;
pub const jump_offset = 8;

// Derived values (common.hpp).
pub const cache_size: u64 = argon_memory * 1024;
pub const dataset_size: u64 = dataset_base_size + dataset_extra_size;
pub const dataset_items: u64 = dataset_size / dataset_item_size;
pub const cache_line_align_mask: u32 = @intCast((dataset_base_size - 1) & ~@as(u64, dataset_item_size - 1));
pub const superscalar_max_size = 3 * superscalar_latency + 2;
pub const condition_mask: u32 = (1 << jump_bits) - 1;
pub const store_l3_condition = 14;

pub const scratchpad_l1_mask: u32 = (scratchpad_l1 / 8 - 1) * 8;
pub const scratchpad_l2_mask: u32 = (scratchpad_l2 / 8 - 1) * 8;
pub const scratchpad_l3_mask: u32 = (scratchpad_l3 / 8 - 1) * 8;
pub const scratchpad_l3_mask64: u32 = (scratchpad_l3 / 64 - 1) * 64;
