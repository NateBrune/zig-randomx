//! x86-64 JIT compiler for RandomX v1/v2 programs and SuperscalarHash
//! (jit_compiler_x86.cpp). Emits the same machine code as the reference.
//!
//! Register allocation inside generated code:
//!   rax, rcx, rdx: temporaries     rbx: iteration counter
//!   rsi: scratchpad                rdi: dataset (or cache in light mode)
//!   rbp: "ma"/"mx"                 r8-r15: r0-r7
//!   xmm0-3: f0-3   xmm4-7: e0-3   xmm8-11: a0-3   xmm12: temporary
//!   xmm13: E 'and' mask   xmm14: E 'or' mask   xmm15: scale mask

const std = @import("std");
const config = @import("../config.zig");
const ins = @import("../instruction.zig");
const superscalar = @import("../superscalar.zig");
const static = @import("x86_static.zig");

const Instruction = ins.Instruction;

const max_instr_code_size = 32;
const max_superscalar_instr_size = 14;
const superscalar_program_header = 128;
const code_align = 4096;

fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) / a * a;
}

pub const randomx_code_size = alignUp(code_align + max_instr_code_size * config.program_max_size, code_align);
const superscalar_size = alignUp(code_align + (superscalar_program_header + max_superscalar_instr_size * config.superscalar_max_size) * config.cache_accesses, code_align);
pub const code_size = randomx_code_size + superscalar_size;
pub const superscalar_hash_offset = randomx_code_size;

comptime {
    std.debug.assert(superscalar_hash_offset == static.superscalar_offset);
}

const register_needs_displacement = 5; // r13
const register_needs_sib = 4; // r12

/// Register file in the layout the generated code expects (256 bytes).
pub const RegisterFile = extern struct {
    r: [8]u64 align(64),
    f: [8]u64,
    e: [8]u64,
    a: [8]u64,
};

pub const MemoryRegisters = extern struct {
    mx: u32,
    ma: u32,
    memory: [*]const u8,
};

pub const ProgramConfig = struct {
    e_mask: [2]u64,
    read_reg: [4]u8,
};

pub const ProgramFn = *const fn (*RegisterFile, *MemoryRegisters, [*]u8, u64) callconv(.c) void;
pub const DatasetInitFn = *const fn (*const [*]const u8, [*]u8, u64, u64) callconv(.c) void;

pub const Compiler = struct {
    code: []align(std.heap.page_size_min) u8,
    pos: usize = 0,
    instruction_offsets: [config.program_max_size]i32 = undefined,
    register_usage: [8]i32 = undefined,
    /// RandomX version of the programs generated next.
    version: config.Version = .v2,

    pub fn init() !Compiler {
        const code = try std.posix.mmap(
            null,
            code_size,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        var c: Compiler = .{ .code = code };
        @memcpy(c.code[0..static.prologue().len], static.prologue());
        const ep = static.epilogue();
        @memcpy(c.code[epilogueOffset()..][0..ep.len], ep);
        return c;
    }

    pub fn deinit(self: *Compiler) void {
        std.posix.munmap(self.code);
        self.* = undefined;
    }

    fn epilogueOffset() usize {
        return code_size - static.epilogue().len;
    }

    pub fn programFn(self: *const Compiler) ProgramFn {
        return @ptrCast(self.code.ptr);
    }

    pub fn datasetInitFn(self: *const Compiler) DatasetInitFn {
        return @ptrCast(self.code.ptr);
    }

    // -- emitters -----------------------------------------------------------

    inline fn emitByte(self: *Compiler, b: u8) void {
        self.code[self.pos] = b;
        self.pos += 1;
    }
    inline fn emit(self: *Compiler, bytes: []const u8) void {
        @memcpy(self.code[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
    inline fn emit32(self: *Compiler, v: u32) void {
        std.mem.writeInt(u32, self.code[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    inline fn emitI32(self: *Compiler, v: i64) void {
        self.emit32(@bitCast(@as(i32, @intCast(v))));
    }
    inline fn emit64(self: *Compiler, v: u64) void {
        std.mem.writeInt(u64, self.code[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    // -- programs -----------------------------------------------------------

    /// Program reading the full dataset.
    pub fn generateProgram(self: *Compiler, prog: []Instruction, pcfg: ProgramConfig) void {
        self.generatePrologue(prog, pcfg);
        self.emit(switch (self.version) {
            .v1 => static.readDatasetV1(),
            .v2 => static.readDataset(),
        });
        self.generateEpilogue(pcfg);
    }

    /// Program computing dataset items on the fly from the cache; needs
    /// `generateSuperscalarHash` first.
    pub fn generateProgramLight(self: *Compiler, prog: []Instruction, pcfg: ProgramConfig, dataset_offset: u64) void {
        self.generatePrologue(prog, pcfg);
        self.emit(switch (self.version) {
            .v1 => static.readDatasetLightInitV1(),
            .v2 => static.readDatasetLightInit(),
        });
        self.emit(&.{ 0x81, 0xc3 }); // add ebx, imm32
        self.emit32(@intCast(dataset_offset / config.dataset_item_size));
        self.emitByte(0xe8); // call
        self.emitI32(@as(i64, superscalar_hash_offset) - @as(i64, @intCast(self.pos + 4)));
        self.emit(static.readDatasetLightFin());
        self.generateEpilogue(pcfg);
    }

    /// Dataset initialization entry point at the start of the buffer; needs
    /// `generateSuperscalarHash` too.
    pub fn generateDatasetInitCode(self: *Compiler) void {
        const di = static.datasetInit();
        @memcpy(self.code[0..di.len], di);
    }

    fn generatePrologue(self: *Compiler, prog: []Instruction, pcfg: ProgramConfig) void {
        @memset(&self.register_usage, -1);
        self.pos = static.prologue().len;
        // The E 'or' mask lives in the constant block just before the loop.
        std.mem.writeInt(u64, self.code[self.pos - 48 ..][0..8], pcfg.e_mask[0], .little);
        std.mem.writeInt(u64, self.code[self.pos - 40 ..][0..8], pcfg.e_mask[1], .little);
        self.emit(static.loopLoad());
        for (prog, 0..) |*instr, i| {
            instr.src %= 8;
            instr.dst %= 8;
            self.instruction_offsets[i] = @intCast(self.pos);
            self.generateCode(instr, @intCast(i));
        }
        self.emit(&.{ 0x41, 0x8b }); // mov eax, r32
        self.emitByte(0xc0 + pcfg.read_reg[2]);
        self.emit(&.{ 0x41, 0x33 }); // xor eax, r32
        self.emitByte(0xc0 + pcfg.read_reg[3]);
    }

    fn generateEpilogue(self: *Compiler, pcfg: ProgramConfig) void {
        self.emit(&.{ 0x49, 0x8b }); // mov rax, r64
        self.emitByte(0xc0 + pcfg.read_reg[0]);
        self.emit(&.{ 0x49, 0x33 }); // xor rax, r64
        self.emitByte(0xc0 + pcfg.read_reg[1]);
        self.emit(static.prefetchScratchpad());
        self.emit(switch (self.version) {
            .v1 => static.loopStoreV1(),
            .v2 => static.loopStore(),
        });
        self.emit(&.{ 0x83, 0xeb, 0x01 }); // sub ebx, 1
        self.emit(&.{ 0x0f, 0x85 }); // jnz loop
        self.emitI32(@as(i64, @intCast(static.prologue().len)) - @as(i64, @intCast(self.pos + 4)));
        self.emitByte(0xe9); // jmp epilogue
        self.emitI32(@as(i64, @intCast(epilogueOffset())) - @as(i64, @intCast(self.pos + 4)));
    }

    // -- SuperscalarHash ----------------------------------------------------

    pub fn generateSuperscalarHash(self: *Compiler, programs: []const superscalar.Program) void {
        const init_code = static.sshashInit();
        @memcpy(self.code[superscalar_hash_offset..][0..init_code.len], init_code);
        self.pos = superscalar_hash_offset + init_code.len;
        for (programs, 0..) |*prog, j| {
            for (prog.slice(), 0..) |instr, i| self.generateSuperscalarCode(instr, prog.reciprocals[i]);
            self.emit(static.sshashLoad());
            if (j < programs.len - 1) {
                self.emit(&.{ 0x49, 0x8b }); // mov rbx, r64
                self.emitByte(0xd8 + prog.address_register);
                self.emit(static.sshashPrefetch());
            }
        }
        self.emitByte(0xc3); // ret
    }

    fn generateSuperscalarCode(self: *Compiler, instr: Instruction, rcp: u64) void {
        const dst = instr.dst;
        const src = instr.src;
        switch (@as(superscalar.Op, @enumFromInt(instr.opcode))) {
            .isub_r => {
                self.emit(&.{ 0x4d, 0x2b });
                self.emitByte(0xc0 + 8 * dst + src);
            },
            .ixor_r => {
                self.emit(&.{ 0x4d, 0x33 });
                self.emitByte(0xc0 + 8 * dst + src);
            },
            .iadd_rs => {
                self.emit(&.{ 0x4f, 0x8d });
                self.emitByte(0x04 + 8 * dst);
                self.genSIB(instr.modShift(), src, dst);
            },
            .imul_r => {
                self.emit(&.{ 0x4d, 0x0f, 0xaf });
                self.emitByte(0xc0 + 8 * dst + src);
            },
            .iror_c => {
                self.emit(&.{ 0x49, 0xc1 });
                self.emitByte(0xc8 + dst);
                self.emitByte(@truncate(instr.imm32 & 63));
            },
            .iadd_c7, .iadd_c8, .iadd_c9 => {
                self.emit(&.{ 0x49, 0x81 });
                self.emitByte(0xc0 + dst);
                self.emit32(instr.imm32);
            },
            .ixor_c7, .ixor_c8, .ixor_c9 => {
                self.emit(&.{ 0x49, 0x81 });
                self.emitByte(0xf0 + dst);
                self.emit32(instr.imm32);
            },
            .imulh_r => {
                self.emit(&.{ 0x49, 0x8b });
                self.emitByte(0xc0 + dst);
                self.emit(&.{ 0x49, 0xf7 });
                self.emitByte(0xe0 + src);
                self.emit(&.{ 0x4c, 0x8b });
                self.emitByte(0xc2 + 8 * dst);
            },
            .ismulh_r => {
                self.emit(&.{ 0x49, 0x8b });
                self.emitByte(0xc0 + dst);
                self.emit(&.{ 0x49, 0xf7 });
                self.emitByte(0xe8 + src);
                self.emit(&.{ 0x4c, 0x8b });
                self.emitByte(0xc2 + 8 * dst);
            },
            .imul_rcp => {
                self.emit(&.{ 0x48, 0xb8 }); // mov rax, imm64
                self.emit64(rcp);
                self.emit(&.{ 0x4c, 0x0f, 0xaf });
                self.emitByte(0xc0 + 8 * dst);
            },
        }
    }

    // -- RandomX instructions -----------------------------------------------

    inline fn genSIB(self: *Compiler, scale: u8, index: u8, base: u8) void {
        self.emitByte((scale << 6) | (index << 3) | base);
    }

    fn genAddressReg(self: *Compiler, instr: *const Instruction, rax: bool) void {
        self.emit(&.{ 0x41, 0x8d }); // lea eax/ecx, [r32+imm32]
        self.emitByte(0x80 + instr.src + @as(u8, if (rax) 0 else 8));
        if (instr.src == register_needs_sib) self.emitByte(0x24);
        self.emit32(instr.imm32);
        if (rax) self.emitByte(0x25) else self.emit(&.{ 0x81, 0xe1 }); // and eax/ecx, imm32
        self.emit32(if (instr.modMem() != 0) config.scratchpad_l1_mask else config.scratchpad_l2_mask);
    }

    fn genAddressRegDst(self: *Compiler, instr: *const Instruction) void {
        self.emit(&.{ 0x41, 0x8d });
        self.emitByte(0x80 + instr.dst);
        if (instr.dst == register_needs_sib) self.emitByte(0x24);
        self.emit32(instr.imm32);
        self.emitByte(0x25);
        if (instr.modCond() < config.store_l3_condition) {
            self.emit32(if (instr.modMem() != 0) config.scratchpad_l1_mask else config.scratchpad_l2_mask);
        } else {
            self.emit32(config.scratchpad_l3_mask);
        }
    }

    inline fn genAddressImm(self: *Compiler, instr: *const Instruction) void {
        self.emit32(instr.imm32 & config.scratchpad_l3_mask);
    }

    /// Integer op with a memory operand: `op r, [rsi+rax]` or `op r, [rsi+imm]`.
    fn genIntMem(self: *Compiler, instr: *const Instruction, prefix: []const u8) void {
        if (instr.src != instr.dst) {
            self.genAddressReg(instr, true);
            self.emit(prefix);
            self.emitByte(0x04 + 8 * instr.dst);
            self.emitByte(0x06);
        } else {
            self.emit(prefix);
            self.emitByte(0x86 + 8 * instr.dst);
            self.genAddressImm(instr);
        }
    }

    fn generateCode(self: *Compiler, instr: *Instruction, i: i32) void {
        const dst = instr.dst;
        const src = instr.src;
        switch (ins.opcode_table[instr.opcode]) {
            .iadd_rs => {
                self.register_usage[dst] = i;
                self.emit(&.{ 0x4f, 0x8d });
                self.emitByte(if (dst == register_needs_displacement) 0xac else 0x04 + 8 * dst);
                self.genSIB(instr.modShift(), src, dst);
                if (dst == register_needs_displacement) self.emit32(instr.imm32);
            },
            .iadd_m => {
                self.register_usage[dst] = i;
                self.genIntMem(instr, &.{ 0x4c, 0x03 });
            },
            .isub_r => {
                self.register_usage[dst] = i;
                if (src != dst) {
                    self.emit(&.{ 0x4d, 0x2b });
                    self.emitByte(0xc0 + 8 * dst + src);
                } else {
                    self.emit(&.{ 0x49, 0x81 });
                    self.emitByte(0xe8 + dst);
                    self.emit32(instr.imm32);
                }
            },
            .isub_m => {
                self.register_usage[dst] = i;
                self.genIntMem(instr, &.{ 0x4c, 0x2b });
            },
            .imul_r => {
                self.register_usage[dst] = i;
                if (src != dst) {
                    self.emit(&.{ 0x4d, 0x0f, 0xaf });
                    self.emitByte(0xc0 + 8 * dst + src);
                } else {
                    self.emit(&.{ 0x4d, 0x69 });
                    self.emitByte(0xc0 + 9 * dst);
                    self.emit32(instr.imm32);
                }
            },
            .imul_m => {
                self.register_usage[dst] = i;
                self.genIntMem(instr, &.{ 0x4c, 0x0f, 0xaf });
            },
            .imulh_r, .ismulh_r => {
                self.register_usage[dst] = i;
                self.emit(&.{ 0x49, 0x8b });
                self.emitByte(0xc0 + dst);
                self.emit(&.{ 0x49, 0xf7 });
                self.emitByte(@as(u8, if (ins.opcode_table[instr.opcode] == .imulh_r) 0xe0 else 0xe8) + src);
                self.emit(&.{ 0x4c, 0x8b });
                self.emitByte(0xc2 + 8 * dst);
            },
            .imulh_m, .ismulh_m => {
                const signed = ins.opcode_table[instr.opcode] == .ismulh_m;
                self.register_usage[dst] = i;
                if (src != dst) {
                    self.genAddressReg(instr, false);
                    self.emit(&.{ 0x49, 0x8b });
                    self.emitByte(0xc0 + dst);
                    self.emit(if (signed) &.{ 0x48, 0xf7, 0x2c, 0x0e } else &.{ 0x48, 0xf7, 0x24, 0x0e });
                } else {
                    self.emit(&.{ 0x49, 0x8b });
                    self.emitByte(0xc0 + dst);
                    self.emit(&.{ 0x48, 0xf7 });
                    self.emitByte(if (signed) 0xae else 0xa6);
                    self.genAddressImm(instr);
                }
                self.emit(&.{ 0x4c, 0x8b });
                self.emitByte(0xc2 + 8 * dst);
            },
            .imul_rcp => {
                const divisor = instr.imm32;
                if (divisor & (divisor -% 1) != 0) {
                    self.register_usage[dst] = i;
                    self.emit(&.{ 0x48, 0xb8 });
                    self.emit64(superscalar.reciprocal(divisor));
                    self.emit(&.{ 0x4c, 0x0f, 0xaf });
                    self.emitByte(0xc0 + 8 * dst);
                }
            },
            .ineg_r => {
                self.register_usage[dst] = i;
                self.emit(&.{ 0x49, 0xf7 });
                self.emitByte(0xd8 + dst);
            },
            .ixor_r => {
                self.register_usage[dst] = i;
                if (src != dst) {
                    self.emit(&.{ 0x4d, 0x33 });
                    self.emitByte(0xc0 + 8 * dst + src);
                } else {
                    self.emit(&.{ 0x49, 0x81 });
                    self.emitByte(0xf0 + dst);
                    self.emit32(instr.imm32);
                }
            },
            .ixor_m => {
                self.register_usage[dst] = i;
                self.genIntMem(instr, &.{ 0x4c, 0x33 });
            },
            .iror_r, .irol_r => {
                const base: u8 = if (ins.opcode_table[instr.opcode] == .iror_r) 0xc8 else 0xc0;
                self.register_usage[dst] = i;
                if (src != dst) {
                    self.emit(&.{ 0x41, 0x8b }); // mov ecx, r32
                    self.emitByte(0xc8 + src);
                    self.emit(&.{ 0x49, 0xd3 }); // ror/rol r64, cl
                    self.emitByte(base + dst);
                } else {
                    self.emit(&.{ 0x49, 0xc1 });
                    self.emitByte(base + dst);
                    self.emitByte(@truncate(instr.imm32 & 63));
                }
            },
            .iswap_r => {
                if (src != dst) {
                    self.register_usage[dst] = i;
                    self.register_usage[src] = i;
                    self.emit(&.{ 0x4d, 0x87 });
                    self.emitByte(0xc0 + src + 8 * dst);
                }
            },
            .fswap_r => {
                self.emit(&.{ 0x66, 0x0f, 0xc6 }); // shufpd
                self.emitByte(0xc0 + 9 * dst);
                self.emitByte(1);
            },
            .fadd_r => {
                instr.dst %= 4;
                instr.src %= 4;
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x58 });
                self.emitByte(0xc0 + instr.src + 8 * instr.dst);
            },
            .fadd_m => {
                instr.dst %= 4;
                self.genAddressReg(instr, true);
                self.emit(&.{ 0xf3, 0x44, 0x0f, 0xe6, 0x24, 0x06 }); // cvtdq2pd xmm12, [rsi+rax]
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x58 });
                self.emitByte(0xc4 + 8 * instr.dst);
            },
            .fsub_r => {
                instr.dst %= 4;
                instr.src %= 4;
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x5c });
                self.emitByte(0xc0 + instr.src + 8 * instr.dst);
            },
            .fsub_m => {
                instr.dst %= 4;
                self.genAddressReg(instr, true);
                self.emit(&.{ 0xf3, 0x44, 0x0f, 0xe6, 0x24, 0x06 });
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x5c });
                self.emitByte(0xc4 + 8 * instr.dst);
            },
            .fscal_r => {
                instr.dst %= 4;
                self.emit(&.{ 0x41, 0x0f, 0x57 }); // xorps xmm, xmm15
                self.emitByte(0xc7 + 8 * instr.dst);
            },
            .fmul_r => {
                instr.dst %= 4;
                instr.src %= 4;
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x59 });
                self.emitByte(0xe0 + instr.src + 8 * instr.dst);
            },
            .fdiv_m => {
                instr.dst %= 4;
                self.genAddressReg(instr, true);
                self.emit(&.{ 0xf3, 0x44, 0x0f, 0xe6, 0x24, 0x06 });
                self.emit(&.{ 0x45, 0x0f, 0x54, 0xe5, 0x45, 0x0f, 0x56, 0xe6 }); // andps xmm12, xmm13; orps xmm12, xmm14
                self.emit(&.{ 0x66, 0x41, 0x0f, 0x5e });
                self.emitByte(0xe4 + 8 * instr.dst);
            },
            .fsqrt_r => {
                instr.dst %= 4;
                self.emit(&.{ 0x66, 0x0f, 0x51 });
                self.emitByte(0xe4 + 9 * instr.dst);
            },
            .cbranch => {
                const reg = dst;
                const target: usize = @intCast(self.register_usage[reg] + 1);
                self.emit(&.{ 0x49, 0x81 }); // add r64, imm32
                self.emitByte(0xc0 + reg);
                const shift: u5 = @as(u5, instr.modCond()) + config.jump_offset;
                var imm: u32 = instr.imm32 | (@as(u32, 1) << shift);
                imm &= ~(@as(u32, 1) << (shift - 1));
                self.emit32(imm);
                self.emit(&.{ 0x49, 0xf7 }); // test r64, imm32
                self.emitByte(0xc0 + reg);
                self.emit32(config.condition_mask << shift);
                self.emit(&.{ 0x0f, 0x84 }); // jz
                self.emitI32(@as(i64, self.instruction_offsets[target]) - @as(i64, @intCast(self.pos + 4)));
                @memset(&self.register_usage, i);
            },
            .cfround => {
                self.emit(&.{ 0x49, 0x8b }); // mov rax, r64
                self.emitByte(0xc0 + src);
                const rotate: u8 = @truncate((13 -% (instr.imm32 & 63)) & 63);
                if (rotate != 0) {
                    self.emit(&.{ 0x48, 0xc1, 0xc0 }); // rol rax, imm8
                    self.emitByte(rotate);
                }
                const set_mxcsr = [_]u8{ 0x25, 0x00, 0x60, 0x00, 0x00, 0x0d, 0xc0, 0x9f, 0x00, 0x00, 0x89, 0x04, 0x24, 0x0f, 0xae, 0x14, 0x24 };
                // v2: change the rounding mode only when bits 13-18 of rax are zero.
                if (self.version == .v2) {
                    self.emit(&.{ 0xa9, 0x00, 0x80, 0x07, 0x00 }); // test eax, 0x78000
                    self.emitByte(0x75); // jnz short
                    self.emitByte(set_mxcsr.len);
                }
                self.emit(&set_mxcsr); // and eax, 0x6000; or eax, 0x9fc0; mov [rsp], eax; ldmxcsr [rsp]
            },
            .istore => {
                self.genAddressRegDst(instr);
                self.emit(&.{ 0x4c, 0x89 }); // mov [rsi+rax], r64
                self.emitByte(0x04 + 8 * src);
                self.emitByte(0x06);
            },
            .nop => self.emitByte(0x90),
        }
    }
};
