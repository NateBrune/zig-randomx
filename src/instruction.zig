//! The 8-byte instruction format shared by VM and SuperscalarHash programs
//! (instruction.hpp), plus the VM opcode table (instruction_weights.hpp).

/// Same layout as the reference `Instruction`.
pub const Instruction = extern struct {
    opcode: u8,
    dst: u8,
    src: u8,
    mod: u8,
    imm32: u32,

    pub fn modMem(self: Instruction) u2 {
        return @truncate(self.mod);
    }
    pub fn modShift(self: Instruction) u6 {
        return @intCast((self.mod >> 2) % 4);
    }
    pub fn modCond(self: Instruction) u4 {
        return @truncate(self.mod >> 4);
    }
};

pub const Type = enum(u8) {
    iadd_rs,
    iadd_m,
    isub_r,
    isub_m,
    imul_r,
    imul_m,
    imulh_r,
    imulh_m,
    ismulh_r,
    ismulh_m,
    imul_rcp,
    ineg_r,
    ixor_r,
    ixor_m,
    iror_r,
    irol_r,
    iswap_r,
    fswap_r,
    fadd_r,
    fadd_m,
    fsub_r,
    fsub_m,
    fscal_r,
    fmul_r,
    fdiv_m,
    fsqrt_r,
    cbranch,
    cfround,
    istore,
    nop,
};

/// Instruction frequencies per 256 opcodes, in `Type` order (configuration.h).
const frequencies = [_]u16{ 16, 7, 16, 7, 16, 4, 4, 1, 4, 1, 8, 2, 15, 5, 8, 2, 4, 4, 16, 5, 16, 5, 6, 32, 4, 6, 25, 1, 16, 0 };

/// Maps an opcode byte to its instruction type.
pub const opcode_table: [256]Type = blk: {
    var sum = 0;
    for (frequencies) |f| sum += f;
    if (sum != 256) @compileError("instruction frequencies must sum to 256");
    var table: [256]Type = undefined;
    var pos = 0;
    for (frequencies, 0..) |f, t| {
        for (0..f) |_| {
            table[pos] = @enumFromInt(t);
            pos += 1;
        }
    }
    break :blk table;
};
