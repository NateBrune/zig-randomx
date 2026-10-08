# zig-randomx

A port of [RandomX](https://github.com/tevador/RandomX), the proof-of-work
algorithm used by Monero, to Zig. It implements **RandomX v2** with an
**x86-64 JIT compiler**, and matches the official test vectors bit for bit.

```zig
const randomx = @import("randomx");

const cache = try randomx.Cache.create(gpa, .{});
defer cache.destroy(gpa);
cache.init("my key");

// Light mode: 256 MiB, computes dataset items on the fly.
const vm = try randomx.Vm.create(gpa, .{ .light = cache }, .{});
defer vm.destroy(gpa);

var hash: [32]u8 = undefined;
vm.hash("input", &hash);
```

For full speed, build the ~2 GiB dataset once and share it between VMs
(one VM per thread):

```zig
const dataset = try randomx.Dataset.create(gpa, .{});
defer dataset.destroy(gpa);
try dataset.init(cache, thread_count);
const vm = try randomx.Vm.create(gpa, .{ .fast = dataset }, .{});
```

Changing the key (`cache.init` again) is picked up automatically by
light-mode VMs. A fast-mode dataset has to be rebuilt.

## Using it in a project

```sh
zig fetch --save git+https://github.com/<you>/zig-randomx
```

```zig
const randomx = b.dependency("randomx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("randomx", randomx.module("randomx"));
```

Requires Zig 0.16.

## Status

| | |
|---|---|
| RandomX v2 (384-instruction programs, AES-mixed F/E, CFROUND tweak, 2-ahead prefetch) | ✓ |
| x86-64 JIT (programs, SuperscalarHash, dataset init) | ✓ |
| Light mode (256 MiB) and fast mode (2 GiB dataset) | ✓ |
| RandomX v1 | not implemented |
| Interpreter / non-x86-64 targets (ARM64, RISC-V JITs) | not implemented |
| Software AES | not implemented: needs a CPU with AES-NI |
| Huge pages: explicit (`MAP_HUGETLB`), then transparent | ✓ |
| W^X ("secure") JIT mode, hash pipelining | not yet |

The JIT buffer is mapped read-write-execute. Systems that forbid that
(strict SELinux `execmem` policies, for example) will need the W^X mode
added first.

## Verification

`zig build test` checks every component against the vectors in the
reference implementation's `src/tests/tests.cpp`:

- Argon2d cache initialization
- the SuperscalarHash generator (10 program hashes) and reciprocals
- dataset items, from the cache and from the JIT dataset builder
- `AesGenerator1R`
- the five RandomX v2 hash vectors (1a–1e)

### Differential testing against the reference

The port was also compared against the reference C++ library (v2.0.1) at
scale with `tools/verify.zig`. Reference harnesses print values from a
deterministic generator, and `randomx-verify` recomputes and compares them:

| check | result |
|---|---|
| light-mode hashes, 24 keys × 400 inputs (keys 0–299 bytes incl. empty and >60, inputs 0–1000 bytes) | 9,600 / 9,600 identical |
| fast-mode hashes, 3 full datasets × 1,000 inputs | 3,000 / 3,000 identical |
| the full 2,181,038,016-byte dataset, built with 1, 3 and 4 threads | SHA-256 identical to the reference |
| SuperscalarHash programs for 100,000 random keys | 800,000 / 800,000 identical |
| `reciprocal` for 1,000,000 random divisors | all identical |
| 800 light-mode hashes on a Debug build (overflow and bounds checks on) | identical |

The 100,000-key run exercised every rare branch of the SuperscalarHash
generator millions of times (throw-aways, the chained-multiplication
fallback, the r5 special case, stalls). The one exception, the abort after
256 consecutive throw-aways, was reviewed by hand. Disassembling the JIT
buffer shows that every executed byte decodes as intended. The only
undecodable bytes are the embedded constant blocks and stale bytes past the
end of the current program.

Unit tests also check that a hash leaves the caller's MXCSR unchanged and
doesn't depend on it, and that hashing in place (input aliasing output)
gives the same result.

`zig build bench -Doptimize=ReleaseFast` builds the full dataset, re-checks
the vectors in fast mode, and measures single-thread speed (`--light`,
`--hashes N`, `--threads N`, `--no-huge-pages`, `--chain`).

Single-thread, unpipelined, RandomX v2 fast mode on an Intel Core i5-7200U
(2 cores, 2016 laptop), two interleaved rounds:

| | round 1 | round 2 |
|---|---|---|
| reference C++, `--largePages` | 413.0 | 415.1 |
| **zig-randomx, explicit huge pages** | **418.6** | **423.2** |
| reference C++, 4 KiB pages | 272.9 | 289.4 |
| zig-randomx, 4 KiB pages | 275.3 | 291.5 |

(`randomx-benchmark --mine --jit --v2 --noBatch [--largePages]` against
`randomx-bench --hashes 1000 [--no-huge-pages]`.) The port matches the
reference within about 2% in both configurations. Huge pages make both
about 45% faster, because the random dataset and scratchpad reads stop
missing the TLB. Chaining hashes (`x = hash(x)`, `--chain`) runs at the same
speed as independent inputs.

### Huge pages

With `.huge_pages = true` (the default) each region tries, in order:

1. **Explicit huge pages** (`MAP_HUGETLB`): guaranteed 2 MiB pages from a
   pool reserved by root. Fast mode needs about 1170 pages (dataset 1040,
   cache 128, plus 1 per VM scratchpad):

   ```sh
   sudo sysctl vm.compact_memory=1
   sudo sysctl vm.nr_hugepages=1250
   grep HugePages_Total /proc/meminfo   # the kernel may grant fewer
   ```

   Release them with `sudo sysctl vm.nr_hugepages=0`.

2. **Transparent huge pages** (`madvise(MADV_HUGEPAGE)`): no setup, but only
   as much memory as the kernel finds contiguous blocks for, so partial
   coverage gives partial speedups.

3. Normal pages.

The fallback is per region. If the pool is too small for everything,
create the `Dataset` before the `Cache`, so the dataset gets the pool. In
fast mode the cache is only used while the dataset is being built.
`Region.kind` reports which kind each allocation got.

## Layout

| file | ported from |
|---|---|
| `src/argon2.zig` | `argon2_core.c`, `argon2_ref.c` |
| `src/superscalar.zig` | `superscalar.cpp`, `blake2_generator.cpp`, `reciprocal.c` |
| `src/cache.zig`, `src/dataset.zig` | `dataset.cpp`, `randomx.cpp` |
| `src/aes.zig` | `aes_hash.cpp` |
| `src/instruction.zig` | `instruction.hpp`, `instruction_weights.hpp` |
| `src/vm.zig` | `virtual_machine.cpp`, `vm_compiled*.cpp`, `randomx.cpp` |
| `src/jit/x86.zig` | `jit_compiler_x86.cpp` |
| `src/jit/x86_static.S` | `jit_compiler_x86_static.S`, `asm/*.inc` |

## License

BSD 3-Clause, the same as RandomX. See [LICENSE](LICENSE). The Argon2 code
derives from the Argon2 reference implementation (CC0).
