//! RandomX cache initialization: Argon2d (v1.3) with RandomX's parameters,
//! keeping the filled memory itself rather than a final tag.
//!
//! Ported from RandomX's argon2_core.c / argon2_ref.c, which derive from the
//! Argon2 reference implementation (CC0, Daniel Dinu, Dmitry Khovratovich,
//! Jean-Philippe Aumasson, Samuel Neves).

const std = @import("std");
const config = @import("config.zig");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub const block_words = 128;
pub const Block = [block_words]u64;

const sync_points = 4;
const version = 0x13;
const type_d = 0;
const prehash_digest_len = 64;

/// Fills `memory` (exactly `config.argon_memory` blocks) from `key`.
pub fn fillCache(memory: []Block, key: []const u8) void {
    std.debug.assert(memory.len == config.argon_memory);
    const lane_length: u32 = config.argon_memory;
    const segment_length: u32 = lane_length / sync_points;

    // H0 over the parameters and inputs; output length is 0 (only the memory is used).
    var seed: [prehash_digest_len + 8]u8 = undefined;
    {
        var h = Blake2b512.init(.{});
        const params = [_]u32{ config.argon_lanes, 0, config.argon_memory, config.argon_iterations, version, type_d };
        for (params) |p| updateU32(&h, p);
        updateU32(&h, @intCast(key.len));
        h.update(key);
        updateU32(&h, config.argon_salt.len);
        h.update(config.argon_salt);
        updateU32(&h, 0); // secret
        updateU32(&h, 0); // associated data
        h.final(seed[0..prehash_digest_len]);
    }

    // First two blocks: H'(H0 || i || lane).
    var bytes: [1024]u8 = undefined;
    for (0..2) |i| {
        std.mem.writeInt(u32, seed[64..68], @intCast(i), .little);
        std.mem.writeInt(u32, seed[68..72], 0, .little);
        blake2bLong(&bytes, &seed);
        for (&memory[i], 0..) |*w, j| w.* = std.mem.readInt(u64, bytes[j * 8 ..][0..8], .little);
    }

    for (0..config.argon_iterations) |pass| {
        for (0..sync_points) |slice| {
            const start: u32 = if (pass == 0 and slice == 0) 2 else 0;
            var curr: u32 = @as(u32, @intCast(slice)) * segment_length + start;
            var prev: u32 = if (curr == 0) lane_length - 1 else curr - 1;
            var index = start;
            while (index < segment_length) : ({
                index += 1;
                curr += 1;
                prev += 1;
            }) {
                if (curr % lane_length == 1) prev = curr - 1;
                const pseudo_rand = memory[prev][0];
                const ref = refIndex(@intCast(pass), @intCast(slice), index, segment_length, lane_length, @truncate(pseudo_rand));
                fillBlock(&memory[prev], &memory[ref], &memory[curr], pass != 0);
            }
        }
    }
}

fn updateU32(h: *Blake2b512, v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    h.update(&b);
}

/// Argon2's variable-length hash H' for a 1024-byte output.
fn blake2bLong(out: *[1024]u8, in: []const u8) void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, out.len, .little);
    var buf: [64]u8 = undefined;
    var h = Blake2b512.init(.{});
    h.update(&len_bytes);
    h.update(in);
    h.final(&buf);
    @memcpy(out[0..32], buf[0..32]);
    var pos: usize = 32;
    while (out.len - pos > 64) : (pos += 32) {
        Blake2b512.hash(&buf, &buf, .{});
        @memcpy(out[pos..][0..32], buf[0..32]);
    }
    Blake2b512.hash(&buf, &buf, .{});
    @memcpy(out[pos..][0..64], buf[0..64]);
}

/// Reference block position for Argon2d with a single lane.
fn refIndex(pass: u32, slice: u32, index: u32, segment_length: u32, lane_length: u32, pseudo_rand: u32) u32 {
    const area: u32 = if (pass == 0)
        (if (slice == 0) index - 1 else slice * segment_length + index - 1)
    else
        lane_length - segment_length + index - 1;
    var rel: u64 = pseudo_rand;
    rel = (rel * rel) >> 32;
    rel = area - 1 - ((area * rel) >> 32);
    const start: u32 = if (pass != 0 and slice != sync_points - 1) (slice + 1) * segment_length else 0;
    return @intCast((start + rel) % lane_length);
}

inline fn blaMka(x: u64, y: u64) u64 {
    return x +% y +% 2 *% (x & 0xffffffff) *% (y & 0xffffffff);
}

inline fn g(v: *Block, a: usize, b: usize, c: usize, d: usize) void {
    v[a] = blaMka(v[a], v[b]);
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
    v[c] = blaMka(v[c], v[d]);
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
    v[a] = blaMka(v[a], v[b]);
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
    v[c] = blaMka(v[c], v[d]);
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
}

inline fn round(v: *Block, i: [16]usize) void {
    g(v, i[0], i[4], i[8], i[12]);
    g(v, i[1], i[5], i[9], i[13]);
    g(v, i[2], i[6], i[10], i[14]);
    g(v, i[3], i[7], i[11], i[15]);
    g(v, i[0], i[5], i[10], i[15]);
    g(v, i[1], i[6], i[11], i[12]);
    g(v, i[2], i[7], i[8], i[13]);
    g(v, i[3], i[4], i[9], i[14]);
}

fn fillBlock(prev: *const Block, ref: *const Block, next: *Block, with_xor: bool) void {
    var r: Block = undefined;
    for (&r, prev, ref) |*o, p, q| o.* = p ^ q;
    var tmp = r;
    if (with_xor) {
        for (&tmp, next) |*t, n| t.* ^= n;
    }
    for (0..8) |i| {
        const b = 16 * i;
        round(&r, .{ b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15 });
    }
    for (0..8) |i| {
        const b = 2 * i;
        round(&r, .{ b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49, b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113 });
    }
    for (next, tmp, r) |*n, t, x| n.* = t ^ x;
}
