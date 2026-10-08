//! RandomX v2 program interpreter (bytecode_machine.cpp, vm_interpreted.cpp).
//!
//! Runs the same programs as the x86-64 JIT without generating machine
//! code, so it works where executable memory is forbidden (strict SELinux
//! `execmem` policies, for example). It is much slower than the JIT.
//!
//! Programs are first decoded into a bytecode with every per-instruction
//! decision (register vs. immediate operand, address mask, branch target,
//! reciprocal) made up front, then executed for 2048 iterations.
//!
//! The rounding-sensitive float operations (add, sub, mul, div, sqrt) are
//! single SSE2 instructions in volatile inline assembly. They run under the
//! MXCSR that CFROUND sets, in program order, with the same flush-to-zero
//! and denormals-are-zero behaviour as the JIT.

const std = @import("std");
const config = @import("config.zig");
const ins = @import("instruction.zig");
const superscalar = @import("superscalar.zig");
const RegisterFile = @import("jit/x86.zig").RegisterFile;
const ProgramConfig = @import("jit/x86.zig").ProgramConfig;
const Source = @import("vm.zig").Source;
const Block = std.crypto.core.aes.Block;

const Instruction = ins.Instruction;
const F = @Vector(2, f64);
const U = @Vector(2, u64);

/// `instruction.Type`; IMUL_RCP decodes to IMUL_R with an immediate, and
/// instructions that do nothing decode to NOP.
pub const Op = ins.Type;

/// One decoded instruction.
pub const Bytecode = struct {
    op: Op,
    dst: u8,
    src: u8,
    /// Integer ops: use `imm` instead of `r[src]`. Memory ops: address
    /// `imm32` alone (masked to L3) instead of `r[src] + imm32`.
    src_imm: bool = false,
    shift: u6 = 0,
    imm32: u32 = 0,
    /// Sign-extended `imm32`, the IMUL_RCP reciprocal, or the CBRANCH addend.
    imm: u64 = 0,
    /// Scratchpad address mask, or the CBRANCH condition mask.
    mask: u32 = 0,
    /// CBRANCH jump target.
    target: u16 = 0,
};

pub const Program = [config.program_size]Bytecode;

inline fn signExtend(x: u32) u64 {
    return @bitCast(@as(i64, @as(i32, @bitCast(x))));
}

fn memMask(instr: Instruction) u32 {
    return if (instr.modMem() != 0) config.scratchpad_l1_mask else config.scratchpad_l2_mask;
}

/// Decodes `prog`, tracking register writes for CBRANCH targets exactly as
/// the JIT does.
pub fn decode(out: *Program, prog: *const [config.program_size]Instruction) void {
    var register_usage: [8]i32 = @splat(-1);
    for (prog, 0..) |instr, idx| {
        const bc = &out[idx];
        const i: i32 = @intCast(idx);
        const dst = instr.dst % 8;
        const src = instr.src % 8;
        const t = ins.opcode_table[instr.opcode];
        bc.* = .{ .op = .nop, .dst = dst, .src = src, .imm32 = instr.imm32, .imm = signExtend(instr.imm32) };
        switch (t) {
            .iadd_rs => {
                bc.op = t;
                bc.shift = instr.modShift();
                // Only r5 takes the displacement (it needs one in x86 addressing).
                if (dst != 5) bc.imm = 0;
                register_usage[dst] = i;
            },
            .iadd_m, .isub_m, .imul_m, .imulh_m, .ismulh_m, .ixor_m => {
                bc.op = t;
                if (src != dst) {
                    bc.mask = memMask(instr);
                } else {
                    bc.src_imm = true;
                    bc.mask = config.scratchpad_l3_mask;
                }
                register_usage[dst] = i;
            },
            .isub_r, .imul_r, .ixor_r, .iror_r, .irol_r => {
                bc.op = t;
                bc.src_imm = src == dst;
                register_usage[dst] = i;
            },
            .imulh_r, .ismulh_r, .ineg_r => {
                bc.op = t;
                register_usage[dst] = i;
            },
            .imul_rcp => {
                const divisor = instr.imm32;
                // Zero and powers of two are no-ops.
                if (divisor & (divisor -% 1) != 0) {
                    bc.op = .imul_r;
                    bc.src_imm = true;
                    bc.imm = superscalar.reciprocal(divisor);
                    register_usage[dst] = i;
                }
            },
            .iswap_r => {
                if (src != dst) {
                    bc.op = t;
                    register_usage[dst] = i;
                    register_usage[src] = i;
                }
            },
            .fswap_r => bc.op = t, // dst 0-3: f, 4-7: e
            .fadd_r, .fsub_r, .fmul_r => {
                bc.op = t;
                bc.dst = dst % 4;
                bc.src = src % 4;
            },
            .fadd_m, .fsub_m, .fdiv_m => {
                bc.op = t;
                bc.dst = dst % 4;
                bc.mask = memMask(instr);
            },
            .fscal_r, .fsqrt_r => {
                bc.op = t;
                bc.dst = dst % 4;
            },
            .cbranch => {
                bc.op = t;
                bc.target = @intCast(register_usage[dst] + 1);
                const shift: u5 = @as(u5, instr.modCond()) + config.jump_offset;
                var imm: u32 = instr.imm32 | (@as(u32, 1) << shift);
                imm &= ~(@as(u32, 1) << (shift - 1));
                bc.imm = signExtend(imm);
                bc.mask = config.condition_mask << shift;
                @memset(&register_usage, i);
            },
            .cfround => {
                bc.op = t;
                bc.shift = @truncate(instr.imm32 & 63);
            },
            .istore => {
                bc.op = t;
                bc.mask = if (instr.modCond() < config.store_l3_condition) memMask(instr) else config.scratchpad_l3_mask;
            },
            .nop => {},
        }
    }
}

// -- float operations under the current MXCSR --------------------------------

inline fn addpd(a: F, b: F) F {
    return asm volatile ("addpd %[b], %[ret]"
        : [ret] "=x" (-> F),
        : [_] "0" (a),
          [b] "x" (b),
    );
}
inline fn subpd(a: F, b: F) F {
    return asm volatile ("subpd %[b], %[ret]"
        : [ret] "=x" (-> F),
        : [_] "0" (a),
          [b] "x" (b),
    );
}
inline fn mulpd(a: F, b: F) F {
    return asm volatile ("mulpd %[b], %[ret]"
        : [ret] "=x" (-> F),
        : [_] "0" (a),
          [b] "x" (b),
    );
}
inline fn divpd(a: F, b: F) F {
    return asm volatile ("divpd %[b], %[ret]"
        : [ret] "=x" (-> F),
        : [_] "0" (a),
          [b] "x" (b),
    );
}
inline fn sqrtpd(a: F) F {
    return asm volatile ("sqrtpd %[a], %[ret]"
        : [ret] "=x" (-> F),
        : [a] "x" (a),
    );
}
/// An opaque call, so the float instructions above stay on their side of it.
extern fn zrx_set_mxcsr(v: u32) callconv(.c) void;

/// Flush to zero, denormals are zero, all exceptions masked; RC in bits 13-14.
const mxcsr_base: u32 = 0x9FC0;
const mantissa_mask: U = @splat(0x00FF_FFFF_FFFF_FFFF);
const scale_mask: U = @splat(0x80F0_0000_0000_0000);

inline fn bits(x: F) U {
    return @bitCast(x);
}
inline fn float(x: U) F {
    return @bitCast(x);
}

inline fn read64(sp: []const u8, addr: u32) u64 {
    return std.mem.readInt(u64, sp[addr..][0..8], .little);
}

/// Two signed 32-bit integers converted to doubles (`cvtdq2pd`; exact).
inline fn readF(sp: []const u8, addr: u32) F {
    const lo = std.mem.readInt(i32, sp[addr..][0..4], .little);
    const hi = std.mem.readInt(i32, sp[addr + 4 ..][0..4], .little);
    return .{ @floatFromInt(lo), @floatFromInt(hi) };
}

inline fn mulh(a: u64, b: u64) u64 {
    return @truncate((@as(u128, a) * b) >> 64);
}
inline fn smulh(a: u64, b: u64) u64 {
    const p = @as(i128, @as(i64, @bitCast(a))) * @as(i64, @bitCast(b));
    return @truncate(@as(u128, @bitCast(p)) >> 64);
}

/// Runs a decoded program for `iterations` iterations, like the JIT's
/// program function. `reg.a` must be set; `reg.r`, `reg.f` and
/// `reg.e` are written. `ma` and `mx` come from the program's entropy.
pub fn execute(
    prog: *const Program,
    reg: *RegisterFile,
    ma_init: u32,
    mx_init: u32,
    pcfg: ProgramConfig,
    scratchpad: []u8,
    source: Source,
    dataset_offset: u64,
    iterations: u32,
) void {
    const sp = scratchpad;
    var r: [8]u64 = @splat(0);
    var f: [4]F = undefined;
    var e: [4]F = undefined;
    var a: [4]F = undefined;
    for (&a, 0..) |*x, i| x.* = float(.{ reg.a[2 * i], reg.a[2 * i + 1] });
    const e_or: U = .{ pcfg.e_mask[0], pcfg.e_mask[1] };

    // Dataset addresses: `ma` is read now, `mx` two iterations later (v2).
    var ma = ma_init;
    var mx = mx_init;
    var sp_addr0: u32 = mx & config.scratchpad_l3_mask64;
    var sp_addr1: u32 = ma & config.scratchpad_l3_mask64;

    for (0..iterations) |_| {
        for (&r, 0..) |*x, i| x.* ^= read64(sp, sp_addr0 + 8 * @as(u32, @intCast(i)));
        for (&f, 0..) |*x, i| x.* = readF(sp, sp_addr1 + 8 * @as(u32, @intCast(i)));
        for (&e, 0..) |*x, i| x.* = float((bits(readF(sp, sp_addr1 + 32 + 8 * @as(u32, @intCast(i)))) & mantissa_mask) | e_or);

        var pc: usize = 0;
        while (pc < prog.len) : (pc +%= 1) {
            const bc = &prog[pc];
            const d = &r[bc.dst];
            const s = if (bc.src_imm) bc.imm else r[bc.src];
            switch (bc.op) {
                .iadd_rs => d.* +%= (r[bc.src] << bc.shift) +% bc.imm,
                .iadd_m => d.* +%= read64(sp, intAddr(bc, &r)),
                .isub_r => d.* -%= s,
                .isub_m => d.* -%= read64(sp, intAddr(bc, &r)),
                .imul_r => d.* *%= s,
                .imul_m => d.* *%= read64(sp, intAddr(bc, &r)),
                .imulh_r => d.* = mulh(d.*, r[bc.src]),
                .imulh_m => d.* = mulh(d.*, read64(sp, intAddr(bc, &r))),
                .ismulh_r => d.* = smulh(d.*, r[bc.src]),
                .ismulh_m => d.* = smulh(d.*, read64(sp, intAddr(bc, &r))),
                .ineg_r => d.* = 0 -% d.*,
                .ixor_r => d.* ^= s,
                .ixor_m => d.* ^= read64(sp, intAddr(bc, &r)),
                .iror_r => d.* = std.math.rotr(u64, d.*, s & 63),
                .irol_r => d.* = std.math.rotl(u64, d.*, s & 63),
                .iswap_r => std.mem.swap(u64, d, &r[bc.src]),
                .fswap_r => {
                    const x = if (bc.dst < 4) &f[bc.dst] else &e[bc.dst - 4];
                    x.* = @shuffle(f64, x.*, undefined, [2]i32{ 1, 0 });
                },
                .fadd_r => f[bc.dst] = addpd(f[bc.dst], a[bc.src]),
                .fadd_m => f[bc.dst] = addpd(f[bc.dst], readF(sp, fltAddr(bc, &r))),
                .fsub_r => f[bc.dst] = subpd(f[bc.dst], a[bc.src]),
                .fsub_m => f[bc.dst] = subpd(f[bc.dst], readF(sp, fltAddr(bc, &r))),
                .fscal_r => f[bc.dst] = float(bits(f[bc.dst]) ^ scale_mask),
                .fmul_r => e[bc.dst] = mulpd(e[bc.dst], a[bc.src]),
                .fdiv_m => {
                    const divisor = float((bits(readF(sp, fltAddr(bc, &r))) & mantissa_mask) | e_or);
                    e[bc.dst] = divpd(e[bc.dst], divisor);
                },
                .fsqrt_r => e[bc.dst] = sqrtpd(e[bc.dst]),
                .cbranch => {
                    d.* +%= bc.imm;
                    if (d.* & bc.mask == 0) pc = @as(usize, bc.target) -% 1;
                },
                .cfround => {
                    const v = std.math.rotr(u64, r[bc.src], bc.shift);
                    // v2: only when bits 2-5 are zero.
                    if ((v >> 2) & 0xF == 0) zrx_set_mxcsr(mxcsr_base | @as(u32, @intCast(v & 3)) << 13);
                },
                .istore => {
                    const addr = (@as(u32, @truncate(r[bc.dst])) +% bc.imm32) & bc.mask;
                    std.mem.writeInt(u64, sp[addr..][0..8], r[bc.src], .little);
                },
                .nop => {},
                .imul_rcp => unreachable, // decoded to imul_r
            }
        }

        const t: u32 = @truncate(r[pcfg.read_reg[2]] ^ r[pcfg.read_reg[3]]);
        const item = readItem(source, dataset_offset, ma & config.cache_line_align_mask);
        for (&r, item) |*x, y| x.* ^= y;
        ma ^= t;
        std.mem.swap(u32, &ma, &mx);

        const next = r[pcfg.read_reg[0]] ^ r[pcfg.read_reg[1]];
        for (r, 0..) |x, i| std.mem.writeInt(u64, sp[sp_addr1 + 8 * i ..][0..8], x, .little);
        // v2: F is mixed with E by AES rounds before it is stored.
        var blocks: [4]Block = undefined;
        for (&blocks, f) |*b, x| b.* = Block.fromBytes(std.mem.asBytes(&x));
        for (e) |k| {
            const key = Block.fromBytes(std.mem.asBytes(&k));
            blocks[0] = blocks[0].encrypt(key);
            blocks[1] = blocks[1].decrypt(key);
            blocks[2] = blocks[2].encrypt(key);
            blocks[3] = blocks[3].decrypt(key);
        }
        for (&f, blocks, 0..) |*x, b, i| {
            const bytes = b.toBytes();
            x.* = @bitCast(bytes);
            sp[sp_addr0 + 16 * i ..][0..16].* = bytes;
        }

        sp_addr0 = @as(u32, @truncate(next)) & config.scratchpad_l3_mask64;
        sp_addr1 = @as(u32, @truncate(next >> 32)) & config.scratchpad_l3_mask64;
    }

    reg.r = r;
    for (0..4) |i| {
        reg.f[2 * i ..][0..2].* = @as([2]u64, bits(f[i]));
        reg.e[2 * i ..][0..2].* = @as([2]u64, bits(e[i]));
    }
}

inline fn intAddr(bc: *const Bytecode, r: *const [8]u64) u32 {
    const base: u32 = if (bc.src_imm) 0 else @truncate(r[bc.src]);
    return (base +% bc.imm32) & bc.mask;
}

inline fn fltAddr(bc: *const Bytecode, r: *const [8]u64) u32 {
    return (@as(u32, @truncate(r[bc.src])) +% bc.imm32) & bc.mask;
}

fn readItem(source: Source, dataset_offset: u64, addr: u32) [8]u64 {
    switch (source) {
        .fast => |ds| {
            const p = ds.memory[dataset_offset + addr ..][0..64];
            var item: [8]u64 = undefined;
            for (&item, 0..) |*x, i| x.* = std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
            return item;
        },
        .light => |cache| return cache.datasetItem((dataset_offset + addr) / config.dataset_item_size),
    }
}
