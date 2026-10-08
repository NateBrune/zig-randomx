//! AES-based generators and hash (aes_hash.cpp): single AES rounds in four
//! lanes, using hardware AES where the target has it.

const std = @import("std");
const Block = std.crypto.core.aes.Block;

/// Builds a block from four 32-bit words given most-significant first,
/// like `_mm_set_epi32(i3, i2, i1, i0)`.
fn words(comptime w: [4]u32) Block {
    var b: [16]u8 = undefined;
    inline for (0..4) |i| std.mem.writeInt(u32, b[i * 4 ..][0..4], w[3 - i], .little);
    return Block.fromBytes(&b);
}

inline fn enc(s: Block, k: Block) Block {
    return s.encrypt(k);
}
inline fn dec(s: Block, k: Block) Block {
    return s.decrypt(k);
}

inline fn load(p: []const u8) Block {
    return Block.fromBytes(p[0..16]);
}
inline fn store(p: []u8, b: Block) void {
    p[0..16].* = b.toBytes();
}

const hash_state = [4]Block{
    words(.{ 0xd7983aad, 0xcc82db47, 0x9fa856de, 0x92b52c0d }),
    words(.{ 0xace78057, 0xf59e125a, 0x15c7b798, 0x338d996e }),
    words(.{ 0xe8a07ce4, 0x5079506b, 0xae62c7d0, 0x6a770017 }),
    words(.{ 0x7e994948, 0x79a10005, 0x07ad828d, 0x630a240c }),
};
const hash_xkey0 = words(.{ 0x06890201, 0x90dc56bf, 0x8b24949f, 0xf6fa8389 });
const hash_xkey1 = words(.{ 0xed18f99b, 0xee1043c6, 0x51f4e03c, 0x61b263d1 });

/// 512-bit hash of `input` (a multiple of 64 bytes), used on the scratchpad.
pub fn hash1Rx4(input: []const u8, out: *[64]u8) void {
    std.debug.assert(input.len % 64 == 0);
    var s = hash_state;
    var i: usize = 0;
    while (i < input.len) : (i += 64) {
        s[0] = enc(s[0], load(input[i..]));
        s[1] = dec(s[1], load(input[i + 16 ..]));
        s[2] = enc(s[2], load(input[i + 32 ..]));
        s[3] = dec(s[3], load(input[i + 48 ..]));
    }
    inline for (.{ hash_xkey0, hash_xkey1 }) |k| {
        s[0] = enc(s[0], k);
        s[1] = dec(s[1], k);
        s[2] = enc(s[2], k);
        s[3] = dec(s[3], k);
    }
    for (s, 0..) |b, j| store(out[j * 16 ..], b);
}

const gen1_keys = [4]Block{
    words(.{ 0xb4f44917, 0xdbb5552b, 0x62716609, 0x6daca553 }),
    words(.{ 0x0da1dc4e, 0x1725d378, 0x846a710d, 0x6d7caf07 }),
    words(.{ 0x3e20e345, 0xf4c0794f, 0x9f947ec6, 0x3f1262f1 }),
    words(.{ 0x49169154, 0x16314c88, 0xb1ba317c, 0x6aef8135 }),
};

/// Fills `out` (a multiple of 64 bytes) from `state`, one AES round per
/// 16 bytes; the advanced state is written back.
pub fn fill1Rx4(state: *[64]u8, out: []u8) void {
    std.debug.assert(out.len % 64 == 0);
    var s = [4]Block{ load(state[0..]), load(state[16..]), load(state[32..]), load(state[48..]) };
    var i: usize = 0;
    while (i < out.len) : (i += 64) {
        s[0] = dec(s[0], gen1_keys[0]);
        s[1] = enc(s[1], gen1_keys[1]);
        s[2] = dec(s[2], gen1_keys[2]);
        s[3] = enc(s[3], gen1_keys[3]);
        for (s, 0..) |b, j| store(out[i + j * 16 ..], b);
    }
    for (s, 0..) |b, j| store(state[j * 16 ..], b);
}

const gen4_keys = [8]Block{
    words(.{ 0x99e5d23f, 0x2f546d2b, 0xd1833ddb, 0x6421aadd }),
    words(.{ 0xa5dfcde5, 0x06f79d53, 0xb6913f55, 0xb20e3450 }),
    words(.{ 0x171c02bf, 0x0aa4679f, 0x515e7baf, 0x5c3ed904 }),
    words(.{ 0xd8ded291, 0xcd673785, 0xe78f5d08, 0x85623763 }),
    words(.{ 0x229effb4, 0x3d518b6d, 0xe3d6a7a6, 0xb5826f73 }),
    words(.{ 0xb272b7d2, 0xe9024d4e, 0x9c10b3d9, 0xc7566bf3 }),
    words(.{ 0xf63befa7, 0x2ba9660a, 0xf765a38b, 0xf273c9e7 }),
    words(.{ 0xc0b0762d, 0x0c06d1fd, 0x915839de, 0x7a7cd609 }),
};

/// Like `fill1Rx4` with four rounds per 16 bytes; the state is not written back.
pub fn fill4Rx4(state: *const [64]u8, out: []u8) void {
    std.debug.assert(out.len % 64 == 0);
    var s = [4]Block{ load(state[0..]), load(state[16..]), load(state[32..]), load(state[48..]) };
    var i: usize = 0;
    while (i < out.len) : (i += 64) {
        inline for (0..4) |r| {
            s[0] = dec(s[0], gen4_keys[r]);
            s[1] = enc(s[1], gen4_keys[r]);
            s[2] = dec(s[2], gen4_keys[r + 4]);
            s[3] = enc(s[3], gen4_keys[r + 4]);
        }
        for (s, 0..) |b, j| store(out[i + j * 16 ..], b);
    }
}
