# KEP-0014: The `.sbc` Bytecode File Format and Compile Cache

| Field | Value |
|-------|-------|
| **KEP** | 0014 |
| **Title** | The `.sbc` Bytecode File Format and Compile Cache |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/bytecode_file.zig`, `src/bytecode_file_write.zig`, `src/bytecode_file_read.zig`, `src/cache.zig`, `src/main.zig`, `build.zig`), `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source — not just
`docs/dev/bytecode.md` and `docs/dev/cache.md` — as of 2026-08-08. The
divergences those two docs leave implicit (notably the two endianness
layers) are called out explicitly below.*

## Summary

Kaappi serializes compiled bytecode to an on-disk format, `.sbc`
(magic `KPBC`, current version 11). The same format serves three roles: it
is the transparent auto-run **compile cache** (`~/.kaappi/cache`) that a
plain `kaappi foo.scm` reads and writes so re-runs skip compilation; it is
the **explicit artifact** `kaappi --compile foo.scm` produces; and it is the
blob **embedded into a standalone binary** by `zig build -Dbundle`. A loaded
`.sbc` is validated three ways — magic, format version, and two hashes
(source content and a "compiler identity" hash folding in the kaappi
version, git build id, and target) — and any mismatch is treated as a cache
miss and silently recompiled, never as an error. It shipped as co-located
`.sbc` files early and moved to the central hashed cache with build-id keys
in #1516.

This is a retroactive, *as-built* KEP. It proposes no behavioural change. It
writes down the byte layout, the versioning and staleness-detection
contract, the "transparent cache" invariant (a HIT must behave exactly like
a MISS), the integrity model (structural validation and two hashes, *no*
checksum), the set of forms the cache refuses, and the two distinct
endianness layers that the existing docs describe separately and never
reconcile. The point is to make a versioned on-disk compatibility contract —
one that also governs standalone-binary provenance — into a numbered,
citable record rather than a format defined only by its reader and writer.

## Motivation

`.sbc` is a genuine on-disk compatibility surface, and the KEP process names
"the build model" as in scope. Three things make a written record valuable:

- **It is a versioned file format with a real compatibility contract, yet
  that contract lives only in code.** There is a magic number, a `VERSION`
  constant with a documented history (v9 line tables, v10 provenance, v11
  immutability + backref sharing), and a precise load-time validation
  sequence. Nothing in the KEP index records what an `.sbc` guarantees or
  how staleness is detected — a reader must reconstruct it from
  `bytecode_file_read.zig`.
- **The "transparent cache" invariant is subtle and easy to regress.** The
  cache must be *semantically invisible*: a run served from cache must
  behave identically to a cold compile, including error locations. That
  guarantee is enforced by a differential test and by the writer *refusing
  to cache* any form it cannot round-trip faithfully (top-level
  `define-syntax`, over-limit constants, and six other head forms). This is
  a design position — "correctness over hit-rate" — that deserves to be
  stated, not just tested.
- **The same format underpins standalone-binary provenance.** `-Dbundle`
  embeds an `.sbc`, and the compiler-identity hash is what lets a bundled
  binary reject a blob built by a different kaappi. That cross-cuts the
  native/bundle build model and the cache; documenting the format once
  covers all three consumers.

The docs also already leave a trap: `bytecode.md` says the ISA operand
stream is big-endian, `cache.md` says `.sbc` scalars are little-endian.
Both are correct — they describe *different layers* — but neither
cross-references the other, so a careful reader can conclude a
contradiction. A single reference spec resolves it.

## Guide-level explanation

Most users never name `.sbc` — it just makes the second run faster:

```bash
kaappi foo.scm     # 1st run: compile, then write ~/.kaappi/cache/<hash>.sbc
kaappi foo.scm     # 2nd run: load the cached bytecode, skip compilation
```

The cache is **transparent**: a cached run does exactly what a fresh compile
would, down to error messages and line numbers. If anything relevant
changes — the source content, the kaappi binary, or the target — the cached
entry stops matching and is silently recompiled. You never get a stale
result; at worst you pay for a recompile you didn't need. Inspect or clear
it:

```bash
kaappi cache status    # current / stale / unloadable entries
kaappi cache clear
```

Two explicit uses of the same format:

```bash
kaappi --compile foo.scm -o foo.sbc     # produce a named .sbc artifact
zig build -Dbundle=foo.sbc              # embed it into a standalone binary
zig build -Dbundle-src=foo.scm          # compile + embed in one step
```

Note the naming collision to keep straight: `kaappi --compile` (this KEP)
produces **bytecode** `.sbc`; `kaappi compile` (no dashes) produces a
**native** executable via LLVM — a different subsystem entirely
([KEP-0010](0010-llvm-native-backend.md)).

An important safety property: the cache never trades correctness for speed.
Some top-level forms (imports, `define-library`, top-level `define-syntax`,
and others) are simply **not cached**, because faithfully replaying their
effects from bytecode is not something the format guarantees. `--timings`
shows the HIT/MISS/OFF decision and, on a miss, why.

## Reference-level design

### File layout (`bytecode_file.zig` owns the format)

Written by `bytecode_file_write.zig::writeFunctionsToBuffer` (`:335`), read
by `bytecode_file_read.zig::deserializeFromBuffer` (`:423`).

Constants (`bytecode_file.zig:26`, `:45`):

```zig
pub const MAGIC = [4]u8{ 'K', 'P', 'B', 'C' };
pub const VERSION: u16 = 11;
```

**Header** (write order, `bytecode_file_write.zig:353`):

1. `MAGIC` — 4 bytes `KPBC`
2. `VERSION` — u16 (11)
3. `source_hash` — u64 (Wyhash of source bytes)
4. `compilerHash()` — u64 (compiler identity; see below)
5. `build_id` — u16-length-prefixed string (provenance, v10; not hashed)
6. `source_path` — u16-length-prefixed string (provenance, v10; not hashed)
7. `func_count` — u32 (functions, flattened)
8. `top_level_count` — u32

**Per-function record** (`bytecode_file_write.zig:366`), ×`func_count`:
`arity` u8, `locals_count` u16, `upvalue_count` u16, `is_variadic` u8;
`name` (u16 length + bytes); `code_len` u32 + raw ISA code bytes; the
constant pool (`const_count` u32 + tagged constants); `source_line` u32;
`line_table_count` u32 + entries `{offset u16, line u32, col u32}`.

**Trailer** — two sections present in every `.sbc` (both zero-count for
auto-run cache files): bundled files (`bf_count` u32, then
`{path, content}` pairs) and preamble forms (`preamble_count` u32, then
`{src}` entries).

**Constant pool** is a tagged union (`bytecode_file.zig:71`): fixnum,
flonum, symbol, string, boolean, nil, void, char, function, pair, vector,
bytevector, bignum, rational, complex, eof, undefined, and `BACKREF` (17).
The four mutable types (pair/string/vector/bytevector) carry a 1-byte
immutability flag (v11); nested functions are stored as a `TAG_FUNCTION`
u32 index into the flat function array. There is **no** separate global
string or symbol table — symbols and strings live inline in each function's
constant pool. Structural caps are constants in `bytecode_file.zig`
(`MAX_FUNCTIONS = 16384`, `MAX_CODE_BYTES = 4 MiB`,
`MAX_CONSTANTS_PER_FUNCTION = 65535`, `MAX_CONSTANT_DEPTH = 256`,
`MAX_STRING_BYTES = 1 MiB`, …).

### Two endianness layers (stated explicitly)

This is the single most important clarification the existing docs omit:

- **Container scalars are little-endian.** Every header/record scalar is
  written through explicit `nativeToLittle` and read through `littleToNative`
  (`bytecode_file_write.zig:35`, `bytecode_file_read.zig:37`), pinned by
  golden bytes in `tests_endian.zig`. This makes `.sbc` portable across
  big-endian targets (s390x, #1949).
- **The ISA operand stream inside `code` is big-endian.** `code` bytes are
  copied verbatim, and the VM reads u16 operands big-endian
  (`readU16FromCode`: `(hi << 8) | lo`, `bytecode_file_read.zig:294`). This
  layer's endianness is independent of the container's because the bytes are
  never reinterpreted at (de)serialization time.

Both are correct; they describe different layers. A reader must not treat
them as contradictory.

### Versioning and staleness detection

`VERSION` is a single `u16` (currently 11) with an inline history
(`bytecode_file.zig:36`): v9 added line/col tables (#1506), v10 added
build-id + source-path provenance (#1516), v11 added the immutability byte,
backref sharing, and the "writer refuses what the reader would reject"
discipline (#2110/#2111/#2113).

A load is a **cache-miss decision, never an error**. `deserializeFromBuffer`
returns `null` on any of: bad magic, `ver != VERSION`, `source_hash`
mismatch, or `compilerHash` mismatch (`bytecode_file_read.zig:434`–`445`).
The format is deliberately **not** forward- or backward-compatible: only the
exact current `VERSION` loads; bumping it invalidates every older entry as a
clean miss.

The **compiler-identity hash** is
`compilerHashFor(version_str, git_build_id, compile_target_id)`
(`bytecode_file.zig:172`), a Wyhash of the three joined with NUL separators.
`compile_target_id` (`:149`) is the `arch-os-abi` triple plus the
`;`-joined `types.platform_features`. So a cached entry is bound to the
source content *and* to the exact binary and target that produced it — a
rebuilt compiler or a different target is a miss. One deliberately
uncovered case is documented: two *dirty* working trees at the same commit
share the `-dirty` build id and can therefore serve each other's bytecode;
the escape hatch is `kaappi cache clear` or `--no-ir-opt`.

### The three consumers, one codec

- **Auto-run cache.** A plain `kaappi foo.scm` reads
  `cache.pathForSource(...)` then, on a miss, writes it back
  (`main.zig:706`, `:906`). The cache file is named `<16-hex>.sbc` where the
  hex is a Wyhash of the **absolute, canonicalized** source path
  (`cache.zig:77`); content validity is then gated by the stored
  `source_hash` and `compilerHash`. It is **not** mtime-based — pure
  content + path + compiler identity. Location is `$KAAPPI_HOME/cache` (else
  `~/.kaappi/cache`); if no home resolves, caching silently disables.
- **`--compile`.** `kaappi --compile foo.scm [-o out.sbc]` writes a named
  artifact via `compileFile` (`main.zig:1117`), default path from
  `getSbcPath` (`.scm`→`.sbc`). It does **not run** the program (#2114): it
  evaluates only the declaration heads needed for the preamble. (Note:
  `getSbcPath` is legacy co-located naming used for `--compile`'s default
  output; it is *not* the cache path, which is the hashed central file.)
- **Standalone bundle.** `-Dbundle=foo.sbc` `@embedFile`s the blob;
  `-Dbundle-src=foo.scm` compiles then embeds (`build.zig:124`–`170`). At
  runtime, a non-null `embedded_bytecode` is loaded via `readFromBuffer`
  (`main.zig:336`). This path intentionally **skips the source-hash check**
  (passes `expected_hash = null`, `bytecode_file_read.zig:636`) — there is
  no source file to compare against — but still enforces magic, version, and
  `compilerHash`. `classifyEmbeddedRejection` distinguishes a
  `.foreign_build` (valid header, different compiler) from `.invalid`, for a
  precise fatal diagnostic.

All three use the identical MAGIC/VERSION/reader/writer; the auto-run cache
just writes both trailer sections empty.

### The transparent-cache invariant and cache refusals

The cache guarantees a HIT is observationally identical to a MISS. It is
upheld by *not caching* anything the format cannot faithfully replay. The
writer refuses (surfaced by `--timings`) for: eight top-level head forms
(`import`, `define-library`, `include`, `include-ci`,
`define-record-type`, `define-values`, `begin`, `cond-expand`), top-level
`define-syntax`/`define-property` (#2112), compile errors, and constants
that exceed format limits (#2113). Under v11, the writer refuses with
`LimitExceeded`/`UnsupportedConstant` rather than emitting an entry the
reader would later reject — so a written entry is always loadable.

### Integrity model (no checksum, by design)

There is **no CRC or content checksum**. Integrity rests on three
mechanisms, all of which collapse a bad file to "miss + recompile":

1. **Bounds-checked reads** — truncation yields `CorruptedFile` or `null`.
2. **Opcode-level validation** — `validateFunctionBytecode`
   (`bytecode_file_read.zig:311`) walks every function's code and rejects
   out-of-range opcodes, bad operands, bad jump targets, out-of-bounds
   constant indices, and malformed closure-capture strides. Constant
   decoding rejects bad tags, over-deep/oversized constants, invalid
   codepoints/surrogates, denormalized bignums, and zero denominators.
3. **Exact-length trailer check** — `if (r.pos != data.len) return null`
   (`:622`) catches trailing garbage.

### The ISA being serialized

The format serializes a **31-opcode, register-based, variable-length** ISA
(`OpCode = enum(u8)`, `types.zig:1359`, last member `tail_eval` = 30),
executed by `vm_dispatch.zig`. Encoding: a 1-byte opcode, big-endian u16
operands, i16 jump offsets (bitcast u16, relative to the following
instruction), and u8 operands only for `nargs` and closure-capture
`is_local`. A `closure` opcode is followed by `upvalue_count × 3` bytes of
capture descriptors (`is_local:u8, index:u16`) — the same stride the reader
and validator walk. The full opcode/operand table lives in
`docs/dev/bytecode.md`.

### Sandbox and WASM interaction

- **`--sandbox`: cache off.** `sbc_path` is `null` when
  `vm.sandbox_mode` (or `--no-ir-opt`) is set (`main.zig:712`), reported as
  `cacheOff("sandbox")` — no filesystem side effects (see
  [KEP-0011](0011-ffi-and-sandbox.md)).
- **WASM: cache is a no-op.** `cacheDir`/`pathForSource`/`ensureDir`
  early-return under wasm, and the writer refuses (`bytecode_file_write.zig`
  returns `WriteError` on wasm) — no home directory, no cache (see
  [KEP-0013](0013-wasm-target.md)).

### Tests

In-file round-trip and rejection tests in `bytecode_file.zig` (constants,
nested functions, immutability #2110, backref sharing #2111, cycles,
hash/version/build-id/target rejection, oversized counts, invalid opcodes);
`tests_bytecode_cache.zig` (GC-rooting of loaded functions, #970-class);
`tests_endian.zig` (golden little-endian scalar pinning); `cache.zig` tests
(status/clear, unloadable detection). Shell suites under
`tests/scheme/cache/`, `tests/scheme/compile/`, and — the invariant's
guardrail — `tests/scheme/differential/run-differential.sh`, which requires
cold and warm runs to agree byte-for-byte and every written entry to HIT.

## Drawbacks

Documenting a format still at an active version (v11, with recent
transparency work #2110–#2113) risks drift as the version climbs.
Mitigation: this KEP records the *contract and invariants* (the validation
sequence, the transparent-cache guarantee, the two-endianness structure, the
no-checksum decision) which are stable across version bumps, and pins field
layout to a commit; the exhaustive opcode/operand table stays in
`bytecode.md`.

Freezing the layout in a KEP could imply the byte format is a public
interoperability contract for third-party tools. It is not: `.sbc` is a
private cache/bundle format whose only compatibility guarantee is "the exact
same kaappi build reads what it wrote." The Unresolved questions ask whether
that should ever change; the record's job is to state the *current* narrow
contract clearly.

## Alternatives considered

- **Leave it to `bytecode.md` + `cache.md`.** Rejected: those docs are split
  by concern (ISA vs. cache policy) and never reconcile the two endianness
  layers, and neither states the format as a numbered compatibility
  contract. A single reference spec removes the apparent contradiction and
  gives the standalone-bundle provenance model a home.
- **Fold this into KEP-0010 (native backend).** Rejected: `--compile`
  (bytecode) and `kaappi compile` (LLVM native) are different pathways that
  merely share a confusing name; the native backend does not consume
  `.sbc`. Documenting them together would reinforce the confusion. They
  cross-reference instead.
- **Fold the cache into a build-model KEP with thottam (KEP-0012).**
  Rejected: the cache is a *runtime* artifact of the interpreter, not part
  of package management; the only overlap is `$KAAPPI_HOME`, which both
  reference.
- **Split "format" and "cache policy" into two KEPs.** Rejected as
  over-fragmentation: the cache-refusal set and the transparent-cache
  invariant are only meaningful in terms of what the format can and cannot
  round-trip, and the same codec backs the explicit-artifact and bundle
  uses.
- **Add a checksum for integrity.** Considered and *not* what ships:
  structural validation plus the two hashes already collapse any corruption
  to a safe recompile, and a checksum would add write cost for no
  correctness gain. Recorded as a deliberate non-choice.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- `.sbc` container scalars are little-endian, so files are structurally
  portable across endianness (s390x, #1949); the embedded ISA stream is
  big-endian and copied verbatim.
- An `.sbc` is bound to its producing compiler and target by `compilerHash`
  (version + git build id + `arch-os-abi` + platform features), so a cache
  entry or bundled blob from a different kaappi build or target is rejected
  as a clean miss (cache) or a precise fatal error (bundle).
- The format is not a stable public interchange format: the only guarantee
  is same-build round-trip. Version bumps invalidate all older entries.
- The cache is disabled under `--sandbox` (KEP-0011) and a no-op under WASM
  (KEP-0013).
- Standalone bundles (`-Dbundle`/`-Dbundle-src`) embed the same format and
  rely on `compilerHash` for provenance rejection.

## Unresolved questions

1. **Should `.sbc` ever become a stable interoperability contract** (e.g. a
   `.sbc` produced by one kaappi loadable by a compatible later one), or is
   "same-build only" the permanent, intended guarantee?
2. **Is the `VERSION` bump policy a KEP-amendable contract?** Should adding a
   constant tag or header field require updating this KEP, or only the
   inline version-history comment and CHANGELOG?
3. **The dirty-tree collision** (two `-dirty` builds sharing a key): is the
   `cache clear` / `--no-ir-opt` mitigation sufficient, or does the build-id
   scheme warrant strengthening (e.g. hashing the working tree)?
4. **Should the embedded/bundle path's omission of the source-hash check be
   formalized** as part of the contract, and should a bundled binary expose
   which `.sbc` (build id / source path provenance) it carries?
5. **No checksum**: is structural-validation-plus-two-hashes the permanent
   integrity stance, or should a corruption-vs-mismatch distinction ever be
   surfaced to users rather than both collapsing to a silent recompile?
6. **Is a `.sbc` inspection tool** (beyond `kaappi cache status` and
   `--disassemble`) worth specifying for debugging bundle/provenance issues?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Reconcile the dev-docs.** Add cross-references so `bytecode.md`
   (big-endian ISA) and `cache.md` (little-endian container) each point at
   this KEP's "two endianness layers" section, and clarify that `getSbcPath`
   is `--compile` output naming, not the cache path.
3. **Decide the version/contract-freeze questions** (Unresolved 1–2) and
   annotate the versioning section accordingly.
4. **Cross-link KEP-0010, 0011, 0013** so the `--compile`/`compile` naming
   distinction, the sandbox cache-off behaviour, and the WASM no-op are
   coherent across the set.
5. **Publish user-facing guidance** on `kaappi.github.io` (a caching /
   standalone-binaries section): the transparent-cache guarantee, `kaappi
   cache status|clear`, the `--compile` vs `compile` distinction, and the
   bundle workflow, linking this KEP.
6. **On acceptance**, triage the dirty-tree, integrity, and inspection-tool
   questions (Unresolved 3–6) into tracked issues so future format work
   amends this KEP rather than starting from source.
