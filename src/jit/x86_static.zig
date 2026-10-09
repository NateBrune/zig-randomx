//! Fixed code fragments the x86-64 JIT copies into its buffer
//! (jit_compiler_x86_static.S and asm/*.inc, RandomX v1/v2, hardware AES only).
//!
//! The fragments live in x86_static.S (attached to the module in build.zig)
//! and are never executed in place: the JIT copies the bytes
//! between consecutive labels. RIP-relative references only point inside the
//! fragment that contains them, so the copies stay valid.

/// Offset of the SuperscalarHash code in the JIT buffer; must match
/// SUPERSCALAR_OFFSET in x86_static.S.
pub const superscalar_offset = 16384;

extern const zrx_prefetch_scratchpad: u8;
extern const zrx_prefetch_scratchpad_end: u8;
extern const zrx_program_prologue: u8;
extern const zrx_program_loop_begin: u8;
extern const zrx_program_loop_load: u8;
extern const zrx_program_start: u8;
extern const zrx_program_read_dataset: u8;
extern const zrx_program_read_dataset_sshash_init: u8;
extern const zrx_program_read_dataset_sshash_fin: u8;
extern const zrx_program_loop_store: u8;
extern const zrx_program_loop_end: u8;
extern const zrx_dataset_init: u8;
extern const zrx_program_epilogue: u8;
extern const zrx_sshash_load: u8;
extern const zrx_sshash_prefetch: u8;
extern const zrx_sshash_end: u8;
extern const zrx_sshash_init: u8;
extern const zrx_program_end: u8;
extern const zrx_v1_read_dataset: u8;
extern const zrx_v1_read_dataset_sshash_init: u8;
extern const zrx_v1_loop_store: u8;
extern const zrx_v1_end: u8;

fn span(comptime from: *const u8, comptime to: *const u8) []const u8 {
    const start = @intFromPtr(from);
    const len = @intFromPtr(to) - start;
    return @as([*]const u8, @ptrFromInt(start))[0..len];
}

/// Copyable code fragments.
pub fn prefetchScratchpad() []const u8 {
    return span(&zrx_prefetch_scratchpad, &zrx_prefetch_scratchpad_end);
}
/// Prologue plus the 64-byte constant block that precedes the loop.
pub fn prologue() []const u8 {
    return span(&zrx_program_prologue, &zrx_program_loop_begin);
}
pub fn loopLoad() []const u8 {
    return span(&zrx_program_loop_load, &zrx_program_start);
}
pub fn readDataset() []const u8 {
    return span(&zrx_program_read_dataset, &zrx_program_read_dataset_sshash_init);
}
pub fn readDatasetLightInit() []const u8 {
    return span(&zrx_program_read_dataset_sshash_init, &zrx_program_read_dataset_sshash_fin);
}
pub fn readDatasetLightFin() []const u8 {
    return span(&zrx_program_read_dataset_sshash_fin, &zrx_program_loop_store);
}
pub fn loopStore() []const u8 {
    return span(&zrx_program_loop_store, &zrx_program_loop_end);
}
pub fn datasetInit() []const u8 {
    return span(&zrx_dataset_init, &zrx_program_epilogue);
}
pub fn epilogue() []const u8 {
    return span(&zrx_program_epilogue, &zrx_sshash_load);
}
pub fn sshashLoad() []const u8 {
    return span(&zrx_sshash_load, &zrx_sshash_prefetch);
}
pub fn sshashPrefetch() []const u8 {
    return span(&zrx_sshash_prefetch, &zrx_sshash_end);
}
/// SuperscalarHash entry plus its constant block.
pub fn sshashInit() []const u8 {
    return span(&zrx_sshash_init, &zrx_program_end);
}

/// RandomX v1 replacements for `readDataset`, `readDatasetLightInit` and
/// `loopStore`.
pub fn readDatasetV1() []const u8 {
    return span(&zrx_v1_read_dataset, &zrx_v1_read_dataset_sshash_init);
}
pub fn readDatasetLightInitV1() []const u8 {
    return span(&zrx_v1_read_dataset_sshash_init, &zrx_v1_loop_store);
}
pub fn loopStoreV1() []const u8 {
    return span(&zrx_v1_loop_store, &zrx_v1_end);
}
