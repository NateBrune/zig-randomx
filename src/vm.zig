//! The RandomX v2 virtual machine, executed through the x86-64 JIT or the
//! interpreter (virtual_machine.cpp, vm_compiled.cpp, vm_compiled_light.cpp,
//! vm_interpreted.cpp, randomx.cpp).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const aes = @import("aes.zig");
const Cache = @import("cache.zig").Cache;
const Dataset = @import("dataset.zig").Dataset;
const Instruction = @import("instruction.zig").Instruction;
const jit = @import("jit/x86.zig");
const interpreter = @import("interpreter.zig");
const memory = @import("memory.zig");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

comptime {
    if (builtin.cpu.arch != .x86_64) @compileError("this RandomX port currently supports x86-64 only");
}

pub const hash_size = 32;

const Program = extern struct {
    entropy: [16]u64 align(64),
    instructions: [config.program_size]Instruction,
};

comptime {
    std.debug.assert(@sizeOf(Program) % 64 == 0);
    std.debug.assert(@sizeOf(jit.RegisterFile) == 256);
}

/// Where dataset items come from.
pub const Source = union(enum) {
    /// Compute items on the fly from the 256 MiB cache (slower).
    light: *const Cache,
    /// Read the precomputed ~2 GiB dataset.
    fast: *const Dataset,
};

pub const Vm = struct {
    reg: jit.RegisterFile,
    program: Program,
    mem: jit.MemoryRegisters,
    pcfg: jit.ProgramConfig,
    dataset_offset: u64,
    scratchpad: []align(std.heap.page_size_min) u8,
    scratchpad_region: memory.Region,
    /// Null when the interpreter runs programs (`Options.jit = false`).
    compiler: ?jit.Compiler,
    bytecode: interpreter.Program,
    source: Source,
    /// Cache generation the SuperscalarHash code was compiled for (light mode).
    compiled_generation: u64,

    pub fn create(gpa: std.mem.Allocator, source: Source, options: memory.Options) !*Vm {
        if (!hasHardwareAes()) return error.AesNotSupported;
        const self = try gpa.create(Vm);
        errdefer gpa.destroy(self);
        self.scratchpad_region = try memory.alloc(config.scratchpad_l3, options);
        errdefer self.scratchpad_region.free();
        self.scratchpad = self.scratchpad_region.bytes;
        self.compiler = if (options.jit) try jit.Compiler.init() else null;
        self.source = source;
        self.compiled_generation = 0;
        return self;
    }

    pub fn destroy(self: *Vm, gpa: std.mem.Allocator) void {
        if (self.compiler) |*c| c.deinit();
        self.scratchpad_region.free();
        gpa.destroy(self);
    }

    /// RandomX v2 hash of `input`. The cache (or the dataset's cache) must be
    /// initialized; re-initializing it with a new key is picked up here.
    pub fn hash(self: *Vm, input: []const u8, out: *[hash_size]u8) void {
        switch (self.source) {
            .light => |cache| {
                std.debug.assert(cache.generation != 0); // Cache.init was never called
                if (self.compiler) |*c| if (cache.generation != self.compiled_generation) {
                    c.generateSuperscalarHash(&cache.programs);
                    self.compiled_generation = cache.generation;
                };
            },
            .fast => {},
        }
        const saved = getMxcsr();
        defer setMxcsr(saved);

        var temp: [64]u8 align(16) = undefined;
        Blake2b512.hash(input, &temp, .{});
        aes.fill1Rx4(&temp, self.scratchpad);
        setMxcsr(mxcsr_default);
        for (0..config.program_count - 1) |_| {
            self.run(&temp);
            Blake2b512.hash(std.mem.asBytes(&self.reg), &temp, .{});
        }
        self.run(&temp);

        // Final result: AES hash of the scratchpad into "a", then BLAKE2b of the registers.
        aes.hash1Rx4(self.scratchpad, std.mem.asBytes(&self.reg.a));
        Blake2b256.hash(std.mem.asBytes(&self.reg), out, .{});
    }

    fn run(self: *Vm, seed: *const [64]u8) void {
        aes.fill4Rx4(seed, std.mem.asBytes(&self.program));
        self.initialize();
        const compiler = if (self.compiler) |*c| c else {
            interpreter.decode(&self.bytecode, &self.program.instructions);
            interpreter.execute(&self.bytecode, &self.reg, self.mem.ma, self.mem.mx, self.pcfg, self.scratchpad, self.source, self.dataset_offset, config.program_iterations);
            return;
        };
        switch (self.source) {
            .fast => |ds| {
                compiler.generateProgram(&self.program.instructions, self.pcfg);
                self.mem.memory = ds.memory.ptr + self.dataset_offset;
            },
            .light => |cache| {
                compiler.generateProgramLight(&self.program.instructions, self.pcfg, self.dataset_offset);
                self.mem.memory = cache.bytes().ptr;
            },
        }
        compiler.programFn()(&self.reg, &self.mem, self.scratchpad.ptr, config.program_iterations);
    }

    fn initialize(self: *Vm) void {
        const e = &self.program.entropy;
        for (0..8) |i| self.reg.a[i] = smallPositiveFloatBits(e[i]);
        self.mem.ma = @as(u32, @truncate(e[8])) & config.cache_line_align_mask;
        self.mem.mx = @truncate(e[10]);
        var address_regs = e[12];
        inline for (0..4) |k| {
            self.pcfg.read_reg[k] = @intCast(2 * k + (address_regs & 1));
            address_regs >>= 1;
        }
        const extra_items = config.dataset_extra_size / config.dataset_item_size;
        self.dataset_offset = (e[13] % (extra_items + 1)) * config.dataset_item_size;
        self.pcfg.e_mask = .{ floatMask(e[14]), floatMask(e[15]) };
    }
};

const mantissa_size = 52;
const mantissa_mask: u64 = (1 << mantissa_size) - 1;
const exponent_mask: u64 = (1 << 11) - 1;
const exponent_bias = 1023;
const dynamic_exponent_bits = 4;
const static_exponent_bits = 4;
const const_exponent_bits: u64 = 0x300;

fn smallPositiveFloatBits(entropy: u64) u64 {
    var exponent = entropy >> 59;
    const mantissa = entropy & mantissa_mask;
    exponent += exponent_bias;
    exponent &= exponent_mask;
    return (exponent << mantissa_size) | mantissa;
}

fn floatMask(entropy: u64) u64 {
    const mask22: u64 = (1 << 22) - 1;
    var exponent = const_exponent_bits;
    exponent |= (entropy >> (64 - static_exponent_bits)) << dynamic_exponent_bits;
    return (entropy & mask22) | (exponent << mantissa_size);
}

/// Flush to zero, denormals are zero, round to nearest, all exceptions masked.
const mxcsr_default: u32 = 0x9FC0;

extern fn zrx_get_mxcsr() callconv(.c) u32;
extern fn zrx_set_mxcsr(v: u32) callconv(.c) void;

fn getMxcsr() u32 {
    return zrx_get_mxcsr();
}

fn setMxcsr(v: u32) void {
    zrx_set_mxcsr(v);
}

pub const getMxcsrForTest = getMxcsr;
pub const setMxcsrForTest = setMxcsr;

pub fn hasHardwareAes() bool {
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={ecx}" (ecx),
        : [_] "{eax}" (@as(u32, 1)),
          [_] "{ecx}" (@as(u32, 0)),
        : .{ .eax = true, .ebx = true, .edx = true });
    return ecx & (1 << 25) != 0;
}
