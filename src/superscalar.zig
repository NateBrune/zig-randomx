//! SuperscalarHash: random programs built by simulating an Intel Ivy Bridge
//! decoder and execution ports, used to expand the cache into the dataset.
//!
//! Ported from RandomX's superscalar.cpp and blake2_generator.cpp. The
//! generator's control flow is reproduced exactly, since any deviation
//! changes every dataset item.

const std = @import("std");
const config = @import("config.zig");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

// ---------------------------------------------------------------------------
// Blake2Generator
// ---------------------------------------------------------------------------

pub const Blake2Generator = struct {
    data: [64]u8,
    index: usize,

    const max_seed_size = 60;

    pub fn init(seed: []const u8, nonce: u32) Blake2Generator {
        var g: Blake2Generator = .{ .data = @splat(0), .index = 64 };
        const n = @min(seed.len, max_seed_size);
        @memcpy(g.data[0..n], seed[0..n]);
        std.mem.writeInt(u32, g.data[max_seed_size..][0..4], nonce, .little);
        return g;
    }

    fn check(self: *Blake2Generator, needed: usize) void {
        if (self.index + needed > self.data.len) {
            Blake2b512.hash(&self.data, &self.data, .{});
            self.index = 0;
        }
    }

    pub fn getByte(self: *Blake2Generator) u8 {
        self.check(1);
        defer self.index += 1;
        return self.data[self.index];
    }

    pub fn getUInt32(self: *Blake2Generator) u32 {
        self.check(4);
        defer self.index += 4;
        return std.mem.readInt(u32, self.data[self.index..][0..4], .little);
    }
};

// ---------------------------------------------------------------------------
// Program representation
// ---------------------------------------------------------------------------

pub const Op = enum(u8) {
    isub_r = 0,
    ixor_r = 1,
    iadd_rs = 2,
    imul_r = 3,
    iror_c = 4,
    iadd_c7 = 5,
    ixor_c7 = 6,
    iadd_c8 = 7,
    ixor_c8 = 8,
    iadd_c9 = 9,
    ixor_c9 = 10,
    imulh_r = 11,
    ismulh_r = 12,
    imul_rcp = 13,
};

pub const Instruction = @import("instruction.zig").Instruction;

pub const Program = struct {
    instructions: [config.superscalar_max_size]Instruction,
    size: u32,
    address_register: u8,
    /// Precomputed reciprocals for IMUL_RCP, indexed like `instructions`.
    reciprocals: [config.superscalar_max_size]u64,

    pub fn slice(self: *const Program) []const Instruction {
        return self.instructions[0..self.size];
    }
};

// ---------------------------------------------------------------------------
// Ivy Bridge model
// ---------------------------------------------------------------------------

const P0: u8 = 1;
const P1: u8 = 2;
const P5: u8 = 4;
const P01 = P0 | P1;
const P05 = P0 | P5;
const P015 = P0 | P1 | P5;

const MacroOp = struct {
    size: u8,
    latency: u8 = 0,
    uop1: u8 = 0,
    uop2: u8 = 0,
    dependent: bool = false,

    fn isSimple(m: MacroOp) bool {
        return m.uop2 == 0;
    }
    fn isEliminated(m: MacroOp) bool {
        return m.uop1 == 0;
    }
};

const add_ri: MacroOp = .{ .size = 7, .latency = 1, .uop1 = P015 };
const lea_sib: MacroOp = .{ .size = 4, .latency = 1, .uop1 = P01 };
const sub_rr: MacroOp = .{ .size = 3, .latency = 1, .uop1 = P015 };
const imul_rr: MacroOp = .{ .size = 4, .latency = 3, .uop1 = P1 };
const imul_r: MacroOp = .{ .size = 3, .latency = 4, .uop1 = P1, .uop2 = P5 };
const mul_r: MacroOp = .{ .size = 3, .latency = 4, .uop1 = P1, .uop2 = P5 };
const mov_rr: MacroOp = .{ .size = 3 };
const mov_ri64: MacroOp = .{ .size = 10, .latency = 1, .uop1 = P015 };
const xor_rr: MacroOp = .{ .size = 3, .latency = 1, .uop1 = P015 };
const xor_ri: MacroOp = .{ .size = 7, .latency = 1, .uop1 = P015 };
const ror_ri: MacroOp = .{ .size = 4, .latency = 1, .uop1 = P05 };

const Kind = enum { isub_r, ixor_r, iadd_rs, imul_r, iror_c, iadd_c7, ixor_c7, iadd_c8, ixor_c8, iadd_c9, ixor_c9, imulh_r, ismulh_r, imul_rcp, nop };

/// Matches SuperscalarInstructionType, with -1 for INVALID.
const Group = i32;
const group_invalid: Group = -1;

const Info = struct {
    kind: Kind,
    ops: []const MacroOp,
    result_op: i32 = 0,
    dst_op: i32 = 0,
    src_op: i32,

    fn op(self: *const Info) Op {
        return @enumFromInt(@intFromEnum(self.kind));
    }
    fn typeId(self: *const Info) Group {
        return if (self.kind == .nop) group_invalid else @intFromEnum(self.kind);
    }
};

const info_isub_r: Info = .{ .kind = .isub_r, .ops = &.{sub_rr}, .src_op = 0 };
const info_ixor_r: Info = .{ .kind = .ixor_r, .ops = &.{xor_rr}, .src_op = 0 };
const info_iadd_rs: Info = .{ .kind = .iadd_rs, .ops = &.{lea_sib}, .src_op = 0 };
const info_imul_r: Info = .{ .kind = .imul_r, .ops = &.{imul_rr}, .src_op = 0 };
const info_iror_c: Info = .{ .kind = .iror_c, .ops = &.{ror_ri}, .src_op = -1 };
const info_iadd_c7: Info = .{ .kind = .iadd_c7, .ops = &.{add_ri}, .src_op = -1 };
const info_ixor_c7: Info = .{ .kind = .ixor_c7, .ops = &.{xor_ri}, .src_op = -1 };
const info_iadd_c8: Info = .{ .kind = .iadd_c8, .ops = &.{add_ri}, .src_op = -1 };
const info_ixor_c8: Info = .{ .kind = .ixor_c8, .ops = &.{xor_ri}, .src_op = -1 };
const info_iadd_c9: Info = .{ .kind = .iadd_c9, .ops = &.{add_ri}, .src_op = -1 };
const info_ixor_c9: Info = .{ .kind = .ixor_c9, .ops = &.{xor_ri}, .src_op = -1 };
const info_imulh_r: Info = .{ .kind = .imulh_r, .ops = &.{ mov_rr, mul_r, mov_rr }, .result_op = 1, .dst_op = 0, .src_op = 1 };
const info_ismulh_r: Info = .{ .kind = .ismulh_r, .ops = &.{ mov_rr, imul_r, mov_rr }, .result_op = 1, .dst_op = 0, .src_op = 1 };
const info_imul_rcp: Info = .{
    .kind = .imul_rcp,
    .ops = &.{ mov_ri64, .{ .size = 4, .latency = 3, .uop1 = P1, .dependent = true } },
    .result_op = 1,
    .dst_op = 1,
    .src_op = -1,
};
const info_nop: Info = .{ .kind = .nop, .ops = &.{}, .src_op = 0 };

const slot_3 = [_]*const Info{ &info_isub_r, &info_ixor_r };
const slot_3l = [_]*const Info{ &info_isub_r, &info_ixor_r, &info_imulh_r, &info_ismulh_r };
const slot_4 = [_]*const Info{ &info_iror_c, &info_iadd_rs };
const slot_7 = [_]*const Info{ &info_ixor_c7, &info_iadd_c7 };
const slot_8 = [_]*const Info{ &info_ixor_c8, &info_iadd_c8 };
const slot_9 = [_]*const Info{ &info_ixor_c9, &info_iadd_c9 };

const DecoderBuffer = struct {
    index: i32,
    counts: []const u8,
};

const buffer_484: DecoderBuffer = .{ .index = 0, .counts = &.{ 4, 8, 4 } };
const buffer_7333: DecoderBuffer = .{ .index = 1, .counts = &.{ 7, 3, 3, 3 } };
const buffer_3733: DecoderBuffer = .{ .index = 2, .counts = &.{ 3, 7, 3, 3 } };
const buffer_493: DecoderBuffer = .{ .index = 3, .counts = &.{ 4, 9, 3 } };
const buffer_4444: DecoderBuffer = .{ .index = 4, .counts = &.{ 4, 4, 4, 4 } };
const buffer_3310: DecoderBuffer = .{ .index = 5, .counts = &.{ 3, 3, 10 } };
const default_buffers = [_]*const DecoderBuffer{ &buffer_484, &buffer_7333, &buffer_3733, &buffer_493 };

fn fetchNext(kind: Kind, cycle: i32, mul_count: i32, gen: *Blake2Generator) *const DecoderBuffer {
    if (kind == .imulh_r or kind == .ismulh_r) return &buffer_3310;
    if (mul_count < cycle + 1) return &buffer_4444;
    if (kind == .imul_rcp) return if (gen.getByte() & 1 != 0) &buffer_484 else &buffer_493;
    return default_buffers[gen.getByte() & 3];
}

const register_needs_displacement = 5; // x86 r13

const RegisterInfo = struct {
    latency: i32 = 0,
    last_op_group: Group = group_invalid,
    last_op_par: i32 = -1,
};

const SuperscalarInstruction = struct {
    info: *const Info = &info_nop,
    src: i32 = -1,
    dst: i32 = -1,
    mod: u8 = 0,
    imm32: u32 = 0,
    op_group: Group = 0,
    op_group_par: i32 = 0,
    can_reuse: bool = false,
    group_par_is_source: bool = false,

    fn toInstr(self: *const SuperscalarInstruction) Instruction {
        return .{
            .opcode = @intFromEnum(self.info.op()),
            .dst = @intCast(self.dst),
            .src = @intCast(if (self.src >= 0) self.src else self.dst),
            .mod = self.mod,
            .imm32 = self.imm32,
        };
    }

    fn createForSlot(self: *SuperscalarInstruction, gen: *Blake2Generator, slot_size: u8, fetch_type: i32, is_last: bool) void {
        switch (slot_size) {
            3 => if (is_last) self.create(slot_3l[gen.getByte() & 3], gen) else self.create(slot_3[gen.getByte() & 1], gen),
            4 => if (fetch_type == 4 and !is_last) self.create(&info_imul_r, gen) else self.create(slot_4[gen.getByte() & 1], gen),
            7 => self.create(slot_7[gen.getByte() & 1], gen),
            8 => self.create(slot_8[gen.getByte() & 1], gen),
            9 => self.create(slot_9[gen.getByte() & 1], gen),
            10 => self.create(&info_imul_rcp, gen),
            else => unreachable,
        }
    }

    fn create(self: *SuperscalarInstruction, info: *const Info, gen: *Blake2Generator) void {
        self.info = info;
        self.src = -1;
        self.dst = -1;
        self.can_reuse = false;
        self.group_par_is_source = false;
        switch (info.kind) {
            .isub_r => {
                self.mod = 0;
                self.imm32 = 0;
                self.op_group = @intFromEnum(Kind.iadd_rs);
                self.group_par_is_source = true;
            },
            .ixor_r => {
                self.mod = 0;
                self.imm32 = 0;
                self.op_group = @intFromEnum(Kind.ixor_r);
                self.group_par_is_source = true;
            },
            .iadd_rs => {
                self.mod = gen.getByte();
                self.imm32 = 0;
                self.op_group = @intFromEnum(Kind.iadd_rs);
                self.group_par_is_source = true;
            },
            .imul_r => {
                self.mod = 0;
                self.imm32 = 0;
                self.op_group = @intFromEnum(Kind.imul_r);
                self.group_par_is_source = true;
            },
            .iror_c => {
                self.mod = 0;
                self.imm32 = 0;
                while (self.imm32 == 0) self.imm32 = gen.getByte() & 63;
                self.op_group = @intFromEnum(Kind.iror_c);
                self.op_group_par = -1;
            },
            .iadd_c7, .iadd_c8, .iadd_c9 => {
                self.mod = 0;
                self.imm32 = gen.getUInt32();
                self.op_group = @intFromEnum(Kind.iadd_c7);
                self.op_group_par = -1;
            },
            .ixor_c7, .ixor_c8, .ixor_c9 => {
                self.mod = 0;
                self.imm32 = gen.getUInt32();
                self.op_group = @intFromEnum(Kind.ixor_c7);
                self.op_group_par = -1;
            },
            .imulh_r, .ismulh_r => {
                self.can_reuse = true;
                self.mod = 0;
                self.imm32 = 0;
                self.op_group = @intFromEnum(info.kind);
                self.op_group_par = @bitCast(gen.getUInt32());
            },
            .imul_rcp => {
                self.mod = 0;
                self.imm32 = gen.getUInt32();
                while (isZeroOrPowerOf2(self.imm32)) self.imm32 = gen.getUInt32();
                self.op_group = @intFromEnum(Kind.imul_rcp);
                self.op_group_par = -1;
            },
            .nop => {},
        }
    }

    fn selectDestination(self: *SuperscalarInstruction, cycle: i32, allow_chained_mul: bool, regs: *const [8]RegisterInfo, gen: *Blake2Generator) bool {
        var avail: [8]i32 = undefined;
        var n: usize = 0;
        for (regs, 0..) |r, i_usize| {
            const i: i32 = @intCast(i_usize);
            if (r.latency <= cycle and
                (self.can_reuse or i != self.src) and
                (allow_chained_mul or self.op_group != @intFromEnum(Kind.imul_r) or r.last_op_group != @intFromEnum(Kind.imul_r)) and
                (r.last_op_group != self.op_group or r.last_op_par != self.op_group_par) and
                (self.info.kind != .iadd_rs or i != register_needs_displacement))
            {
                avail[n] = i;
                n += 1;
            }
        }
        return selectRegister(avail[0..n], gen, &self.dst);
    }

    fn selectSource(self: *SuperscalarInstruction, cycle: i32, regs: *const [8]RegisterInfo, gen: *Blake2Generator) bool {
        var avail: [8]i32 = undefined;
        var n: usize = 0;
        for (regs, 0..) |r, i| {
            if (r.latency <= cycle) {
                avail[n] = @intCast(i);
                n += 1;
            }
        }
        if (n == 2 and self.info.kind == .iadd_rs) {
            if (avail[0] == register_needs_displacement or avail[1] == register_needs_displacement) {
                self.src = register_needs_displacement;
                self.op_group_par = register_needs_displacement;
                return true;
            }
        }
        if (selectRegister(avail[0..n], gen, &self.src)) {
            if (self.group_par_is_source) self.op_group_par = self.src;
            return true;
        }
        return false;
    }
};

fn selectRegister(avail: []const i32, gen: *Blake2Generator, reg: *i32) bool {
    if (avail.len == 0) return false;
    const index: usize = if (avail.len > 1) gen.getUInt32() % @as(u32, @intCast(avail.len)) else 0;
    reg.* = avail[index];
    return true;
}

fn isZeroOrPowerOf2(x: u32) bool {
    return x & (x -% 1) == 0;
}

const cycle_map_size = config.superscalar_latency + 4;
const look_forward_cycles = 4;
const max_throwaway_count = 256;
const PortMap = [cycle_map_size][3]u8;

fn scheduleUop(comptime commit: bool, uop: u8, ports: *PortMap, start: i32) i32 {
    var cycle = start;
    while (cycle < cycle_map_size) : (cycle += 1) {
        const c: usize = @intCast(cycle);
        if (uop & P5 != 0 and ports[c][2] == 0) {
            if (commit) ports[c][2] = uop;
            return cycle;
        }
        if (uop & P0 != 0 and ports[c][0] == 0) {
            if (commit) ports[c][0] = uop;
            return cycle;
        }
        if (uop & P1 != 0 and ports[c][1] == 0) {
            if (commit) ports[c][1] = uop;
            return cycle;
        }
    }
    return -1;
}

fn scheduleMop(comptime commit: bool, mop: MacroOp, ports: *PortMap, start: i32, dep_cycle: i32) i32 {
    var cycle = start;
    if (mop.dependent) cycle = @max(cycle, dep_cycle);
    if (mop.isEliminated()) return cycle;
    if (mop.isSimple()) return scheduleUop(commit, mop.uop1, ports, cycle);
    while (cycle < cycle_map_size) : (cycle += 1) {
        const c1 = scheduleUop(false, mop.uop1, ports, cycle);
        const c2 = scheduleUop(false, mop.uop2, ports, cycle);
        if (c1 >= 0 and c1 == c2) {
            if (commit) {
                _ = scheduleUop(true, mop.uop1, ports, c1);
                _ = scheduleUop(true, mop.uop2, ports, c2);
            }
            return c1;
        }
    }
    return -1;
}

fn isMultiplication(kind: Kind) bool {
    return kind == .imul_r or kind == .imulh_r or kind == .ismulh_r or kind == .imul_rcp;
}

pub fn generate(prog: *Program, gen: *Blake2Generator) void {
    var ports: PortMap = std.mem.zeroes(PortMap);
    var regs: [8]RegisterInfo = @splat(.{});

    var buffer: *const DecoderBuffer = &buffer_484; // replaced on the first fetch
    var current: SuperscalarInstruction = .{};
    var mop_index: usize = 0;
    var cycle: i32 = 0;
    var dep_cycle: i32 = 0;
    var ports_saturated = false;
    var program_size: u32 = 0;
    var mul_count: i32 = 0;
    var throwaway_count: i32 = 0;
    var first_fetch = true;

    var decode_cycle: i32 = 0;
    while (decode_cycle < config.superscalar_latency and !ports_saturated and program_size < config.superscalar_max_size) : (decode_cycle += 1) {
        // The very first fetch sees the null instruction (type INVALID).
        buffer = fetchNext(if (first_fetch) .nop else current.info.kind, decode_cycle, mul_count, gen);
        first_fetch = false;

        var buffer_index: usize = 0;
        while (buffer_index < buffer.counts.len) {
            const top_cycle = cycle;

            if (mop_index >= current.info.ops.len) {
                if (ports_saturated or program_size >= config.superscalar_max_size) break;
                current.createForSlot(gen, buffer.counts[buffer_index], buffer.index, buffer.counts.len == buffer_index + 1);
                mop_index = 0;
            }
            const mop = current.info.ops[mop_index];

            var schedule_cycle = scheduleMop(false, mop, &ports, cycle, dep_cycle);
            if (schedule_cycle < 0) {
                ports_saturated = true;
                break;
            }

            if (@as(i32, @intCast(mop_index)) == current.info.src_op) {
                var forward: i32 = 0;
                while (forward < look_forward_cycles and !current.selectSource(schedule_cycle, &regs, gen)) : (forward += 1) {
                    schedule_cycle += 1;
                    cycle += 1;
                }
                if (forward == look_forward_cycles) {
                    if (throwaway_count < max_throwaway_count) {
                        throwaway_count += 1;
                        mop_index = current.info.ops.len;
                        continue;
                    }
                    current = .{};
                    break;
                }
            }
            if (@as(i32, @intCast(mop_index)) == current.info.dst_op) {
                var forward: i32 = 0;
                while (forward < look_forward_cycles and !current.selectDestination(schedule_cycle, throwaway_count > 0, &regs, gen)) : (forward += 1) {
                    schedule_cycle += 1;
                    cycle += 1;
                }
                if (forward == look_forward_cycles) {
                    if (throwaway_count < max_throwaway_count) {
                        throwaway_count += 1;
                        mop_index = current.info.ops.len;
                        continue;
                    }
                    current = .{};
                    break;
                }
            }
            throwaway_count = 0;

            schedule_cycle = scheduleMop(true, mop, &ports, schedule_cycle, schedule_cycle);
            if (schedule_cycle < 0) {
                ports_saturated = true;
                break;
            }
            dep_cycle = schedule_cycle + mop.latency;

            if (@as(i32, @intCast(mop_index)) == current.info.result_op) {
                const r = &regs[@intCast(current.dst)];
                r.latency = dep_cycle;
                r.last_op_group = current.op_group;
                r.last_op_par = current.op_group_par;
            }
            buffer_index += 1;
            mop_index += 1;

            if (schedule_cycle >= config.superscalar_latency) ports_saturated = true;
            cycle = top_cycle;

            if (mop_index >= current.info.ops.len) {
                prog.instructions[program_size] = current.toInstr();
                program_size += 1;
                if (isMultiplication(current.info.kind)) mul_count += 1;
            }
        }
        cycle += 1;
    }

    // Address register: the one with the highest latency on an ideal ASIC.
    var asic_latencies: [8]i32 = @splat(0);
    for (prog.instructions[0..program_size]) |ins| {
        const lat_dst = asic_latencies[ins.dst] + 1;
        const lat_src = if (ins.dst != ins.src) asic_latencies[ins.src] + 1 else 0;
        asic_latencies[ins.dst] = @max(lat_dst, lat_src);
    }
    var max_latency: i32 = 0;
    var address_reg: u8 = 0;
    for (asic_latencies, 0..) |lat, i| {
        if (lat > max_latency) {
            max_latency = lat;
            address_reg = @intCast(i);
        }
    }
    prog.size = program_size;
    prog.address_register = address_reg;
    for (prog.instructions[0..program_size], 0..) |ins, i| {
        prog.reciprocals[i] = if (ins.opcode == @intFromEnum(Op.imul_rcp)) reciprocal(ins.imm32) else 0;
    }
}

/// 2^x / divisor for the highest x such that the result is below 2^64.
pub fn reciprocal(divisor: u32) u64 {
    std.debug.assert(divisor != 0);
    const p2exp63: u64 = 1 << 63;
    const q = p2exp63 / divisor;
    const r = p2exp63 % divisor;
    const shift: u6 = @intCast(64 - @clz(@as(u64, divisor)));
    return (q << shift) +% ((r << shift) / divisor);
}

inline fn mulh(a: u64, b: u64) u64 {
    return @intCast((@as(u128, a) * b) >> 64);
}

inline fn smulh(a: u64, b: u64) u64 {
    const p = @as(i128, @as(i64, @bitCast(a))) * @as(i64, @bitCast(b));
    return @truncate(@as(u128, @bitCast(p)) >> 64);
}

inline fn signExtend(x: u32) u64 {
    return @bitCast(@as(i64, @as(i32, @bitCast(x))));
}

pub fn execute(r: *[8]u64, prog: *const Program) void {
    for (prog.slice(), 0..) |ins, i| {
        const d = &r[ins.dst];
        const s = r[ins.src];
        switch (@as(Op, @enumFromInt(ins.opcode))) {
            .isub_r => d.* -%= s,
            .ixor_r => d.* ^= s,
            .iadd_rs => d.* +%= s << ins.modShift(),
            .imul_r => d.* *%= s,
            .iror_c => d.* = std.math.rotr(u64, d.*, ins.imm32),
            .iadd_c7, .iadd_c8, .iadd_c9 => d.* +%= signExtend(ins.imm32),
            .ixor_c7, .ixor_c8, .ixor_c9 => d.* ^= signExtend(ins.imm32),
            .imulh_r => d.* = mulh(d.*, s),
            .ismulh_r => d.* = smulh(d.*, s),
            .imul_rcp => d.* *%= prog.reciprocals[i],
        }
    }
}
