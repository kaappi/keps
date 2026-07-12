# P1 constraints memo — element-access semantics for shared flat buffers

This is method step 1 of [P1](open-problems.md#p1--racing-element-access-semantics-for-shared-buffers):
the constraints memo for [KEP-0003](../keps/0003-shared-flat-numeric-data.md)
Unresolved question 2 — what each candidate access encoding (plain /
`unordered` / `monotonic` / hybrid) promises and forbids, in the
vocabulary of the JS/Wasm shared-memory models and of LLVM's own atomics
contract. It also refines the step-2 experiment protocol based on three
codegen probes run for this memo.

**What this memo is not:** the decision. That belongs to step 2's
numbers judged against P1's pre-registered criteria (quoted in §9). The
memo's outputs are the constraint table (§10), the sharpened statement
of *why* plain accesses are unsound (§3), and the experiment refinements
(§9).

*Quotes from the [LLVM Atomics guide](https://llvm.org/docs/Atomics.html)
retrieved 2026-07-12. Probes run 2026-07-12 on macOS aarch64 with
Zig 0.16.0, Homebrew clang/LLVM 22.1.7 (§8).*

## 1. The promise being implemented

KEP-0003's guide-level contract, verbatim: element access is
"bounds-checked and never tear (an element is a single aligned machine
access), but two threads racing on the same index get no ordering
guarantee — the race is *your* nondeterminism, not undefined behavior."
The reference-level sketch adds that every `-ref`/`-set!` "compiles to a
single aligned load/store of the element width" and delegates all
ordering to channel operations.

As model-level requirements:

| # | Requirement | JS/Wasm vocabulary |
|---|---|---|
| R1 | **Untorn**: one aligned element access is single-copy atomic | JS's tear-free aligned integer TypedArray accesses (≤ 8 bytes); Wasm's per-access atomicity granularity (Watt et al., OOPSLA 2019). KEP-0003 extends the tear-free guarantee to f64 elements explicitly |
| R2 | **Some written value**: a racing read returns a value some write actually put there — no out-of-thin-air, no `undef` | the JMM/SAB no-thin-air condition; what the PLDI 2020 SAB repair was defending |
| R3 | **No ordering**: racing accesses get no visibility or coherence promise at all | weaker than JS SAB non-atomics (whose model still totals same-location events); deliberately the weakest defensible contract |
| R4 | **Never UB**: VM memory safety must not depend on programs being race-free | the "safe language" property; the entire reason JS/Wasm chose access-atomic semantics |
| R5 | **Happens-before via channels only**: `task-wait` / receive is the fence | release/acquire on the SharedChannel mutex + the §5 notifier `acq_rel` swap — structure machine-checked by the P2 model |

R4 is the load-bearing one: it must hold for *adversarial* programs
(overlapping slices, rogue indices), not just for the blessed
fill-your-slice idiom, because "memory-safe VM" is a property Kaappi
claims unconditionally.

## 2. Adversary model

The CPU is not the adversary: on all supported targets (aarch64,
x86_64, riscv64) aligned loads/stores ≤ 8 bytes are single-copy atomic
in hardware (KEP-0003, Cross-platform impact). The adversary is every
compiler that touches buffer memory:

1. **Zig**, compiling the interpreter's `-ref`/`-set!` primitives (and
   everything else in the runtime that touches payloads);
2. **Kaappi's LLVM backend** (`llvm_emit.zig`), compiling Scheme loops
   over shared buffers to native code — the only tier where the
   candidates differ measurably (§4);
3. **C compilers**, for FFI consumers handed the payload pointer (§7).

Both 1 and 2 bottom out in LLVM IR, so LLVM's memory model is the
normative substrate for the whole question.

## 3. Why "flat data ⇒ races are harmless" is false for plain accesses

LLVM's contract for non-atomic access is explicit. NotAtomic: *"If
there is a race on a given memory location, loads from that location
return undef"*, and for frontends: *"If your frontend is for a 'safe'
language like Java, use Unordered to load and store any shared
variable."* Two further license grants matter:

- *"Introducing loads to shared variables along a codepath where they
  would not otherwise exist is allowed"* (NotAtomic optimizer notes) —
  i.e., a value the program read once may be **re-read**, and under a
  race the two reads may disagree. `unordered` is exactly the level
  that forbids this ("rematerializing a load" is on its
  prohibited-transforms list).
- Nothing at NotAtomic level forbids **splitting** an access; the
  guarantee that a load/store "cannot be split into multiple
  instructions" is stated only for `unordered`. A plain f64 store may
  legally become two 32-bit stores — a compiler-manufactured torn
  write, independent of what the hardware would do.

The buffer being flat (no Scheme references) means a garbage *value*
cannot become a wild *pointer* directly — but that is not where the
danger lives. The failure chain is value flow into safety-critical
operations:

```scheme
;; native-compiled reader racing a writer thread on b:
(vector-ref v (shared-bytevector-ref b i))
```

Compiled with a plain load, the bounds check and the indexing operation
are two *uses* of one racing read. The optimizer may rematerialize the
load between them (explicitly allowed, above): the check tests one
value, the access indexes with another — or the value is `undef` and
the branch/GEP on it is poison. Either way the VM performs an
out-of-bounds heap access. **Memory safety of the VM is lost through a
buffer that contains only bytes.** This is Boehm's HotPar 2011 argument
instantiated at IR level, and it is why R2/R4 rule out plain accesses
*a priori* (as P1 pre-registered) rather than pending measurement.

Plain accesses stay in the step-2 experiment only as the **baseline**:
they are the performance ceiling every other candidate is measured
against.

## 4. Candidate (b): `unordered` atomics on every element access

**Contract fit.** LLVM: *"Unordered is the lowest level of atomicity.
It essentially guarantees that races produce somewhat sane results
instead of having undefined behavior"*; *"intended to match the Java
memory model for shared variables"*; codegen *"required to be atomic in
the sense that … a load cannot see a value which was never stored"*
and *"cannot be split into multiple instructions."* That is R1 + R2 +
R4 verbatim, R3 by omission (unordered promises no ordering, not even
per-location coherence), R5 unaffected. This is the encoding LLVM's own
documentation prescribes for exactly KEP-0003's stated semantics; the
spec wording and the implementation would cite the same sentence.

**Encodings, verified.** Zig 0.16 compiles
`@atomicLoad`/`@atomicStore` at `.unordered` on both `f64` and `u8`
(probe §8.1). The LLVM backend emits
`load atomic double, … unordered, align 8` / the store dual. Both are
legal on all three targets at width ≤ 8 bytes (an f64 is the widest
element; no i128 concerns).

**Machine-code cost: none.** An unordered aligned load/store lowers to
the same single instruction as a plain one (§8 probes: identical scalar
loop bodies).

**Real cost: optimizer inhibition.** The prohibited-transforms list —
no load rematerialization, no store splitting/narrowing, no
*"turning loads and stores into a memcpy call"* — plus the observed
(not merely documented) big one: **LLVM's loop vectorizer refuses
atomic accesses at any ordering, including `unordered`** (probe §8.3:
`-pass-remarks-missed=loop-vectorize` reports "loop not vectorized"
while the identical plain loop vectorizes). On the fill kernel that is
an 8-doubles-per-iteration gap on aarch64 (probe §8.2). Note the
memcpy/memset prohibition separately: for `u8` buffers, plain loops can
collapse into `memset`/`memcpy` library calls that beat even
vectorized loops; unordered forecloses that idiom too. The step-2
kernels must measure both mechanisms (§9).

**Interpreter tier: free.** One ordering annotation on the single
load/store inside a primitive is noise against VM dispatch; only
native-compiled loops can observe the difference. If step 2 adopts any
hybrid, the interpreter side should use `unordered` unconditionally.

**Wasm forward-compatibility (one flag).** Today WASI is
single-threaded and KEP-0003 degrades to single-owner buffers, so this
is moot. If shared-memory Wasm threads arrive, LLVM lowers atomic ops
to Wasm's (seq_cst-only) atomic instructions — costlier than plain
Wasm accesses. Revisit at that boundary; not a v1 input.

## 5. Candidate (c): `monotonic` atomics

LLVM: *"the weakest level of atomicity that can be used in
synchronization primitives … it essentially guarantees that if you
take all the operations affecting a specific address, a consistent
ordering exists."* Everything in (b) plus per-location coherence
(reads of one element never appear to go backward).

Coherence is a promise KEP-0003's contract conspicuously does not make
(R3), channels carry all intended ordering (R5), and the optimizer
inhibition is a strict superset of (b)'s (same-location reordering now
also forbidden). The C11-relaxed probe (§8.2) shows the same
scalar-not-vectorized outcome as unordered, with the same
instruction-level cost. **(c) is dominated by (b)** for this design:
same measured cost expected, weaker optimizer freedom, and a stronger
contract than the spec wants to advertise. It stays in the experiment
matrix only to confirm the "same cost" expectation; choosing it would
need a positive reason step 2 is not expected to produce.

(If a future `shared-buffer-cas!` / ordered subset ever ships —
out of scope for v1 per the pre-registration — it would be
`monotonic`-or-stronger RMW on the same storage, and coexists cleanly
with (b) for plain element access, exactly as JS pairs plain SAB
access with the `Atomics` namespace.)

## 6. Candidate (d): the hybrid — plain in native code, fences at channel edges

**Precise statement.** Interpreter primitives use `unordered` always
(free, §4). The LLVM backend compiles `-ref`/`-set!` to **plain**
accesses. Soundness shifts from per-access to whole-program: the
implementation promises KEP-0003's semantics only for executions that
are data-race-free at element granularity, with the happens-before
edges supplied by KEP-0002 — envelope push/pop under the
`SharedChannel` mutex plus the §5 notifier `acq_rel` protocol (the
edge structure the P2 model checks). For DRF programs, behavior is
indistinguishable from (b); racing programs get LLVM-level UB.

**What it buys:** exactly the plain-codegen ceiling — vectorization
and memset/memcpy idioms in native worker loops.

**What it costs — the spec, not the machine.** KEP-0003's guide
sentence *"the race is your nondeterminism, not undefined behavior"*
becomes false as written and must weaken to a DRF proviso stated in
the shared-buffer documentation's first paragraph (pre-registered
condition). R4 fails for adversarial programs: an overlapping-slice
race can, through §3's chain, break VM memory safety. That is a
qualitatively new kind of hole for Kaappi — today no Scheme program,
however wrong, can corrupt the VM.

**Containments if adopted** (to be specified in the KEP-0003 amendment,
costed in step 2 where measurable):

1. Debug and `--gc-stress` builds compile buffer access `unordered`
   regardless — races stay *defined* in exactly the builds that hunt
   corruption, so a misbehaving program under test yields wrong
   numbers, not a corrupted VM.
2. The `(kaappi parallel)` slice helpers (KEP-0003 Phase 3,
   `parallel-fill!`-style) take disjoint ranges by construction and can
   assert disjointness at submission time — making the blessed idiom
   mechanically safe and confining the UB surface to hand-rolled index
   arithmetic.
3. The guide documents that the hole is *per element*, not per buffer:
   distinct elements never interfere (both candidates guarantee this;
   false sharing is a performance topic, not a correctness one).

## 7. The FFI path (identical under every candidate)

C code handed the payload pointer performs NotAtomic accesses no matter
what Kaappi-compiled code does; (b)'s guarantees hold only among
Kaappi-side accesses. Concurrent Kaappi-writer/C-reader races are
therefore undefined under every candidate, and the FFI lifetime rules
KEP-0003 leaves TODO should state the hand-off discipline: a buffer
passed to an FFI call must not be concurrently accessed until the call
returns (the natural I/O-buffer usage already satisfies this). This is
not an argument for (d) — Kaappi-side racing programs are expressible
by accident in a way "call C while writing" is not.

## 8. Codegen probes (2026-07-12; smoke tests, not the experiment)

Toy kernels, not Kaappi's backend or pipeline; they establish
mechanisms and encodings, nothing more.

1. **Zig encoding exists** — `zig test` of `@atomicStore`/`@atomicLoad`
   at `.unordered` on `f64` and `u8`: compiles and passes,
   Zig 0.16.0.
2. **clang 22.1.7, `-O3`, aarch64** — C fill loop over `double`:
   plain compiles to `stp q1, q1` pairs (8 doubles/iteration, NEON);
   the `__ATOMIC_RELAXED` variant stays a scalar loop and stores via a
   GPR (`str x8` after moving the double out of the FP register) —
   vectorization *and* instruction selection both pessimized.
3. **LLVM 22 `opt -passes='default<O3>'` on hand-written IR** — the
   same fill loop with `store atomic double … unordered`: untouched
   scalar loop; `-pass-remarks-missed=loop-vectorize` says
   *"loop not vectorized"*. The plain twin vectorizes to
   `<2 x double>` operations. Confirms the vectorizer bails at
   `unordered` specifically, not just at C11 orderings.
4. **Pipeline caveat** — Zig 0.16's own `ReleaseFast` pipeline did
   *not* vectorize even the **plain** fill loop in probe form. Whether
   Kaappi's `llvm_emit.zig` pass pipeline vectorizes anything today is
   an open question the experiment must answer *first* (§9.1) —
   otherwise the comparison measures a floor, not the ceiling.

## 9. Step-2 experiment protocol (refinements to the pre-registration)

The pre-registered decision criteria, quoted from P1:

> If `unordered` element access costs < 10% on the vectorizable
> kernels, take it unconditionally (full memory-safety, no caveats).
> If it costs more than that, adopt the hybrid and require the guide to
> state the overlapping-slices caveat in its first paragraph.
> Plain-accesses-everywhere is rejected *a priori* on Boehm 2011
> grounds. An `Atomics`-style ordered subset is out of scope for v1
> either way.

Refinements motivated by the probes:

1. **Baseline validity first.** Confirm the plain-access baseline
   actually vectorizes under Kaappi's backend pipeline (inspect
   `-pass-remarks=loop-vectorize` equivalents / emitted asm). If it
   does not, *tuning the pipeline until it does is part of the
   experiment* — "unordered costs < 10%" against a never-vectorizing
   baseline would be a vacuous pass that silently forecloses future
   vectorization. "Vectorizable kernels" in the criteria means:
   kernels whose plain build demonstrably vectorizes.
2. **Kernel matrix.** The KEP-0003 Motivation kernels plus two probes
   added for mechanisms the doc's prohibited-transforms list names:
   - `f64` fill (splat) — vectorization;
   - `f64` map (`out[i] = a*x[i] + b`) — vectorization with two
     streams;
   - `f64` sum — **only informative if Kaappi's float addition may
     reassociate**; if `fl+` is strict left-to-right, no access mode
     vectorizes it and the kernel drops out. Add an integer variant
     (u8/i64 checksum) where reassociation is legal;
   - `u8` fill and `u8` block copy — the memset/memcpy idiom:
     unordered forbids the libcall conversion outright, so the gap
     here may exceed the vectorization gap.
3. **Configurations.** plain / `unordered` / `monotonic` per element
   access ((d) shares plain's codegen; it is a semantics choice, not a
   fourth build). aarch64-macos and x86_64-linux. Sizes spanning
   L1 / L2 / DRAM.
4. **Interpreter-tier control.** One measurement of `-ref`/`-set!`
   primitive throughput plain-vs-unordered to confirm the "free at
   dispatch scale" claim (§4); expected Δ ≈ 0.
5. **Stats discipline per P5**: Kalibera–Jones iteration counts, setup
   randomization, confidence intervals — the same protocol Phase 7
   pre-registers.

## 10. Constraint summary

| | R1 untorn | R2 some-written-value | R3 unordered ok | R4 never UB | Vectorizes (observed) | memset/memcpy idiom | Contract owner |
|---|---|---|---|---|---|---|---|
| (a) plain everywhere | ✗ compiler may split | ✗ `undef` | — | ✗ | ✓ | ✓ | — (rejected a priori; baseline only) |
| (b) `unordered` | ✓ documented | ✓ documented | ✓ exactly | ✓ | ✗ (LLVM 22) | ✗ prohibited | runtime, per access |
| (c) `monotonic` | ✓ | ✓ | over-promises coherence | ✓ | ✗ (LLVM 22) | ✗ | runtime, per access |
| (d) hybrid | ✓ for DRF | ✓ for DRF | ✓ | ✗ racing programs → UB (contained per §6) | ✓ in native tier | ✓ in native tier | program-level DRF via KEP-0002 edges |

**Standing prediction (falsifiable by step 2):** on any kernel where
the plain baseline vectorizes or hits a libcall idiom, `unordered` will
cost far more than 10% (the fill probe suggests integer factors, not
percent), pushing the pre-registered criteria to the hybrid — with the
loud caveat, the debug-build `unordered` containment, and the checked
slice helpers of §6. If Kaappi's pipeline turns out not to vectorize
these loops even after tuning (§9.1), the opposite follows: (b) is
free, and full per-access memory safety ships with no caveats. Either
way the criteria, not this prediction, decide.

**Lands next:** step 2 is the codegen experiment in the kaappi repo
(needs the LLVM backend; follow-up item 2 in
[open-problems.md](open-problems.md)). Its numbers + this memo resolve
KEP-0003 UQ 2 in a KEP-0003 amendment that makes the access semantics
normative.
