# KEP-0003: Shared Flat Numeric Data

| Field | Value |
|-------|-------|
| **KEP** | 0003 |
| **Title** | Shared Flat Numeric Data |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (new shared-buffer type, GC/deepCopy integration), `(kaappi parallel)` |
| **Created** | 2026-07-12 |
| **Requires** | KEP-0002 (Phases 1–4; see acceptance gate below) |
| **Supersedes** | — |

> **Acceptance gate.** This KEP is drafted as a *sibling* of KEP-0002: the
> design work proceeds in parallel so the two share one shared-object
> protocol, but this KEP must **not** move to `Accepted` until KEP-0002's
> Phase 7 workload data shows real `parallel-map` programs bottlenecked on
> copying numeric payloads (KEP-0002, Prior art lesson 4 and Unresolved
> question 1). The Motivation below carries what can be measured *today*;
> the fan-out evidence it cannot yet carry is exactly what the gate waits
> for. Sections marked **[skeleton]** are intentionally incomplete until
> then. The gate's workload matrix, statistics protocol, and
> classification rule are pre-registered in
> [`research/benchmarks/`](../research/benchmarks/README.md) (P5);
> thresholds frozen 2026-07-12, before any Phase 7 code or numbers
> exist.
>
> **Gate evaluated — 2026-07-16, outcome 4 (Between): stays gated.**
> Phase 7 ran the pre-registered campaign and
> [kaappi#1474](https://github.com/kaappi/kaappi/issues/1474) applied
> the protocol's §5 rule mechanically; **both reference machines read
> Between independently** (genuine agreement, not the cross-machine
> fallback). Racket-shaped failed: only `IP-MAP` cleared the 25 %
> CI-lower share bound (26.0 % [25.7, 26.3] at 64 MiB on macOS
> aarch64; 8 MiB and 64 MiB on Linux x86_64) where the rule needs 2 of
> 3 `IP-*` workloads. Erlang-shaped and Absent failed: `IP-MAP`,
> `FO-TREE` (69.9–72.4 % share on macOS), and `FO-SLICE` (52.7–57.0 %)
> sit far above the 10 % upper bound at both lever settings, with
> Linux reading the same three offenders. Lever D barely moves those
> cells (`cd` ≈ `none`): the high-share payloads are byte-opaque
> flonum vectors and trees a bytevector side-heap cannot share — so
> the copy pain that exists today is the *walk tax* on boxed fan-out,
> not the in-place wall this carve-out exists for, and it did not
> reach pre-registered strength in the `IP-*` shape. This KEP
> therefore stays **Draft**; the sections marked **[skeleton]** stay
> skeletal. Revisit trigger (§5 outcome 4): real `kaappi-examples`
> traces exhibiting an `IP-*`-shaped hot loop — which fires a fresh
> gate re-run under the same frozen thresholds, not a renegotiation.
> Record: datasets and classifier in kaappi#1549 (macOS) and
> kaappi#1580 (Linux); the filled mechanical worksheet is
> `docs/dev/kep-0003-acceptance-gate-worksheet.md` in the kaappi repo.
> One deviation from §5's outcome-4 action (which leaves the gate
> issue open): the maintainer deliberately closed kaappi#1474, the
> epic kaappi#1465, and the gated implementation issue kaappi#1475 —
> recorded as a maintainer call in their closing comments. The
> successor trackers those comments promised (kaappi#1596 — path to
> Accepted; kaappi#1597 — implementation-to-release) were opened
> 2026-07-16 and deliberately retired the same day: an open issue
> reads as actionable work, and this KEP's only next step is waiting
> on field evidence. The standing record is
> [Path to `Accepted`](#path-to-accepted-revisit-protocol) at the end
> of this document; firing the trigger opens fresh kaappi/kaappi
> issues rather than reopening any of the retired ones.

*The benchmark in the Motivation was run on macOS aarch64 (Apple
Silicon), ReleaseSafe, at kaappi commit
[`bff08865`](https://github.com/kaappi/kaappi/commit/bff08865) (main,
2026-07-12, post KEP-0001 Phase 3). Prior-art links current as of
2026-07.*

## Summary

KEP-0002 gives Kaappi cross-thread channels with copy-at-boundary
semantics: every value that crosses a thread is deep-copied in and out of
an envelope. That is the right default — it is what keeps every heap
single-threaded and every primitive lock-free — but it makes one workload
shape structurally awkward: **large flat numeric data fanned out to, or
assembled by, parallel workers**. Copying multiplies by the worker count
in both time and memory, the copies serialize on the submitting thread,
and in-place algorithms (N workers each writing a disjoint slice of one
output buffer) cannot be expressed at all, at any cost.

This KEP proposes the first — and deliberately narrow — carve-out:
**shared flat buffers** of raw numeric data (`shared-bytevector`,
`shared-f64vector`) that cross thread boundaries by refcounted reference
instead of by copy. The carve-out does not breach the GC invariant that
motivates copying everywhere else: a shared buffer contains only flat
words — bytes or IEEE doubles, never Scheme heap references — so no
Scheme heap object ever becomes reachable from two GCs. What it does
surrender is race-freedom on the buffer *contents*: concurrent access to
the same element is user-visible nondeterminism (memory-safe,
bounds-checked, untorn — but unordered). Coordination is delegated to the
tool the runtime already has: a KEP-0002 channel send/receive pair
creates the happens-before edge that makes "fill your slice, then post
done" well-defined.

Structurally, a shared buffer is the second instance of KEP-0002's
shared-object protocol — refcounted process-global allocation, per-heap
stub objects, a `deepCopy` arm that aliases instead of copies, teardown
through `freeObject` — which is why the two KEPs are designed together
(see Implementation plan, Phase 0).

## Motivation

### What copying flat data costs today (measured)

`thread-start!` deep-copies the captured thunk into the child;
`thread-join!` deep-copies the result back. A round trip is therefore two
`deepCopy` traversals of the payload — the same in-plus-out cost KEP-0002's
envelope path charges per message. Timing round trips against
single-thread copies of the same payloads separates the *traversal* cost
from thread overhead:

```scheme
(import (scheme base) (scheme time) (srfi 18))
(define (round-trip data)
  (thread-join! (thread-start! (make-thread (lambda () data)))))
;; timed with current-jiffy over N reps after one warm-up;
;; full script in this KEP's pull-request description
```

| Payload | Round trip (2 copies) | One-copy floor | Per-copy rate |
|---|---:|---:|---:|
| empty thunk (thread overhead) | 0.04 ms | — | — |
| bytevector, 1 MiB | 0.13 ms | — | ~15 GiB/s |
| bytevector, 16 MiB | 2.08 ms | — | ~15 GiB/s |
| bytevector, 64 MiB | 7.20 ms | 4.53 ms (`bytevector-copy`) | ~17 GiB/s |
| vector, 1M flonums (~8 MiB) | 4.75 ms | 0.54 ms (`vector-copy`) | ~3.3 GiB/s |
| list, 1M fixnums | 141.38 ms | — | ~0.4 GiB/s |

Three honest readings, in decreasing order of comfort:

1. **A single bytevector crossing is nearly free.** `deepCopy` of flat
   bytes runs at memcpy speed (~15–17 GiB/s here); 64 MiB crosses one way
   in ~3.6 ms. This KEP is *not* motivated by "bytevector copies are
   slow" — they are not, and the KEP-0002 copy default is vindicated for
   one-shot transfers.
2. **Anything with per-element structure pays a walk tax.** A uniform
   vector of NaN-boxed flonums copies ~4.4× slower than its flat floor
   (per-element dispatch in `deepCopy`), and a list of the same element
   count is ~30× slower again. Notably, Kaappi has **no flat float
   storage at all today**: SRFI-4's float kinds are portable records
   wrapping plain `vector`s
   ([`lib/srfi/4.sld`](https://github.com/kaappi/kaappi/blob/bff08865/lib/srfi/4.sld)),
   so every f64 payload pays the boxed-walk rate, not the bytevector
   rate. A shared flat f64 buffer is incidentally Kaappi's first flat
   float array.
3. **The structural costs are multiplicative and unmeasurable in a
   single round trip.** Fan out one 64 MiB input to 8 pool workers under
   copy semantics and the submitting thread performs 8 envelope copies
   (~29 ms of its own time — copies happen *on the sender*, KEP-0002 §4)
   while the process holds up to 9 copies of the data (~576 MiB) in
   envelopes and worker heaps that no GC heuristic accounts for
   (KEP-0002, Drawbacks). Every one of those sender-side copies also
   stalls every fiber on the sending scheduler for its duration
   (KEP-0002's head-of-line drawback). The per-copy price is small; the
   *shape* multiplies it by worker count, serializes it on one thread,
   and doubles it again to collect results.

### What copying cannot express at any price

The deeper limitation is not cost but expressiveness. The canonical
data-parallel pattern — N workers each computing a disjoint **slice of
one output array** (image tiles, matrix blocks, chunked map over a
numeric column) — has no copy-semantics encoding that avoids
reassembly: each worker must return its slice as a fresh value, and the
parent must copy each into place, adding one more full traversal and
O(result) transient garbage to every parallel job. In-place parallel
algorithms (stencils, in-situ transforms, big accumulation buffers)
cannot be written at all. Racket hit exactly this wall with places and
answered with `shared-flvector`/`shared-bytes` (see Prior art) — the
escape hatch this KEP adapts.

### Why now (and why gated)

KEP-0002 Phase 5 ships `parallel-map`; its Phase 7 benchmarks will show
whether real workloads hit reading 3 and the reassembly wall. Drafting
this KEP *now* — before that evidence — has one concrete payoff: the
shared-object machinery KEP-0002 builds for channels (refcount protocol,
stubs, `deepCopy` aliasing, leak discipline) is this KEP's substrate, and
specifying both against one generic protocol while KEP-0002 is still
Draft avoids a retrofit later (Phase 0). Acceptance waited for the
evidence, and the evidence has since arrived: the gate note above
records the 2026-07-16 evaluation — outcome **Between**, neither the
in-place demand at pre-registered strength nor a copy cost that
elision dissolves — so the wait continues with a concrete trigger
rather than a date.

## Guide-level explanation

**[skeleton — API names and exact semantics are provisional]**

A shared buffer is made once and handed to workers like any other value;
crossing a thread boundary passes a reference, not a copy:

```scheme
(import (scheme base) (kaappi parallel) (kaappi shared-data))

(define pixels (make-shared-bytevector (* width height 4) 0))
(define pool (make-pool (processor-count)))

;; each worker fills a disjoint horizontal band, in place
(define tasks
  (map (lambda (band)
         (pool-submit pool
           (lambda ()
             (render-band! pixels width band)   ; writes shared memory
             band)))                            ; tiny result: the band id
       (bands height (processor-count))))

(for-each task-wait tasks)   ; happens-before: all writes visible here
(write-png pixels width height)
```

The rules a user must know:

- **Contents are raw numbers, never Scheme objects.** A shared buffer
  holds bytes (`shared-bytevector`) or IEEE doubles
  (`shared-f64vector`). You cannot store a pair, string, or channel in
  one — the type admits no reference, which is what keeps the GC model
  intact.
- **Element access is untorn and unordered — for race-free programs.**
  Reads and writes are bounds-checked and never tear (an element is a single
  aligned machine access). Two tasks that reach a buffer through a channel
  handshake see each other's writes across that edge, and any residual race
  *across a channel edge* is your nondeterminism. But two tasks racing on the
  same element with **no channel edge between them** — overlapping slices,
  hand-rolled indices — are a data race the native compiler may miscompile:
  undefined behavior, not merely nondeterminism (the hybrid encoding, P1
  step 2). Write disjoint ranges and let a channel carry "done" (the blessed
  idiom below); debug and `--gc-stress` builds compile every access
  `unordered`, so a race under test surfaces as wrong numbers, never a
  corrupted VM. The shared-buffer guide's first paragraph must state this
  DRF proviso.
- **Channels are the synchronization.** A value received on a channel
  happens-after everything the sender did before sending (the channel
  mutex provides the edge). "Write your slice, then send done" is the
  blessed idiom; `task-wait` in the example is exactly that.
- **Everything else is unchanged.** Ordinary bytevectors still copy;
  shared buffers are something you reach for deliberately, and the
  guide's first line about them says when *not* to (small payloads:
  copying 1 MiB costs 65 µs — just copy).

**Why this plus KEP-0002 reads as native parallelism.** Every runtime
that offers "just call it" parallelism — Rayon's `par_iter`, OpenMP's
`parallel for`, Java's parallel streams — is secretly providing two
planes: a **control plane** (how work units are distributed and their
completion observed) and a **data plane** (how payloads reach and leave
the workers). Shared-heap runtimes get both from the heap. Kaappi's
isolated heaps forbid that, so the two sibling KEPs rebuild one plane
each on terms the GC model accepts:

```
 user surface:     (parallel-map pool f xs)    (render-band! pixels …)
                   ── no threads, channels, or fibers visible ──
                             │                        │
 control plane     KEP-0002: pools over channels      │
 (small, copied)   tasks/results/shutdown cross       │
                   by deep copy — µs-cheap because    │
                   control messages are small         │
                             │                        │
 data plane                  │            KEP-0003: shared flat buffers
 (big, referenced)           │            payload crosses by refcounted
                             │            reference — O(1), written in place
                             ▼                        ▼
 substrate:        N isolated heaps, N schedulers, N reactors
```

KEP-0002 alone already gives a working `parallel-map` with no visible
concurrency plumbing, but for numeric payloads the copy semantics leak
back in as *shape*: the Motivation's fan-out arithmetic (N sender-side
copies, serialized on the submitting thread, plus the reassembly wall)
is a serial section that grows with the data — Amdahl eating the
speedup from inside the plumbing. This KEP removes exactly that serial
section and nothing else: what crosses per task shrinks to a descriptor
(buffer handle, offset, length — a few dozen bytes through the same
channels), the payload never moves, and results are written in place,
so there is no reassembly step at all.

The composition is also this KEP's memory model, not just its
transport. A shared buffer ships no atomics API and no locks; a channel
send/receive pair (its internal mutex, KEP-0002 §4) is what provides
the happens-before edge between a worker's writes and a reader. In the
example above, `task-wait` is simultaneously the control-plane join and
the data-plane memory fence — "fill your slice, then send; receive,
then read" is well-defined *because* coordination already flows through
channels. Neither KEP can offer this alone: channels without buffers
have nothing to fence; buffers without channels would need a
synchronization API invented from scratch.

Scoped honestly: this lands Kaappi in the fork-join /
parallel-collections family — the user names the parallel region
(`make-pool`, `parallel-map`, slice-per-worker) and never touches a
thread, channel, or fiber — not in the implicit-parallelism family
(futures, sparks, auto-parallelization), which KEP-0002's Alternatives
rule out for isolated heaps. Granularity stays task-level and
user-chosen, and everything except buffer contents keeps the full
share-nothing guarantee.

**The implicit boundary is permanent, not pending.** Implicit
parallelism requires the runtime to relocate arbitrary — possibly
suspended — computation between cores on its own initiative; in Kaappi
a suspended computation is fiber frames and registers full of pointers
into one specific heap, so relocation is fiber migration, which
KEP-0002's Alternatives reject as structurally incompatible with
isolated heaps (Racket futures and Haskell sparks exist because a
shared heap makes "run this thunk over there" free). No later phase of
either KEP changes this: speculative futures, auto-parallelized loops,
and parallel-by-default collections are off the table unless the
shared-heap question itself is reopened. The trade carries a
compensating guarantee worth stating plainly: because tasks cross by
copy, `parallel-map` over an impure, stateful function still cannot
create a data race on Scheme data — each worker mutates its own heap's
copies. OpenMP-style systems hand you implicit-feeling loops where a
race is undefined behavior; Kaappi hands you an explicit call where a
race is unrepresentable, with this KEP's buffers as the single,
opted-in, documented exception. Future ergonomics work
(`parallel-for`, `parallel-vector-map`, a `(parallel …)` macro) can
make the surface feel more implicit, but it stays library sugar over
the pool: the region stays explicit underneath, and this paragraph is
the record of why.

## Reference-level design

**[skeleton — to be completed before acceptance; the load-bearing
decisions are recorded, the mechanics are TODO]**

- **`SharedBuffer` is the second instance of the KEP-0002 shared-object
  protocol.** Refcounted allocation from the process-global allocator;
  one counted stub per heap that references it; `+1` on every stub
  `deepCopy` (thread thunks, channel messages), `−1` in `freeObject`;
  destroy at zero. Phase 0 lands the KEP-0002 §1 amendment that names
  this generic protocol so channels and buffers share one audited
  implementation (refcount state machine, leak discipline, gc-stress
  coverage) rather than two divergent ones.
- **Contents are flat words, so GC invariant 1 survives.** The buffer
  payload (`[]u8` / `[]f64`, 8-byte aligned) contains no `Value`s: no
  marking, no tracing, no cross-heap reachability. The stub is an
  ordinary heap object with no traceable fields — exactly a promoted
  channel's shape (KEP-0002 §2).
- **Element access semantics (normative — the hybrid).** Each
  `-ref`/`-set!` compiles to a single aligned load/store of the element
  width. On all supported targets (aarch64, x86_64, riscv64) aligned
  accesses ≤ 8 bytes do not tear. No ordering is implied between racing
  accesses; the happens-before story is delegated to channel operations
  (KEP-0002 §4's mutex) and `thread-join!`. **Resolved (P1 step 2, the
  codegen experiment kaappi#1473):** access encoding is the **hybrid**,
  not per-access atomics.
  - **Interpreter primitives use Zig `@atomicLoad/@atomicStore(.unordered)`
    unconditionally.** An aligned `unordered` access lowers to the *same
    machine instruction* as a plain one, and the annotation is
    unobservable against VM dispatch (measured: a real
    `bytevector-u8-ref`/`-set!` is ~107 ns/call; the atomic annotation adds
    a sub-nanosecond fraction). Full memory safety, no caveat, at this tier.
  - **The LLVM native backend compiles `-ref`/`-set!` to *plain* accesses.**
    Soundness shifts from per-access to whole-program: KEP-0003's semantics
    hold for executions data-race-free at element granularity, with
    happens-before supplied by KEP-0002 (envelope push/pop under the
    `SharedChannel` mutex + the §5 notifier `acq_rel` protocol — the edge
    structure the P2 model checks). For race-free programs, behavior is
    indistinguishable from `unordered`; a program racing on the same element
    with no channel edge is a data race the native compiler may miscompile
    (LLVM-level UB). This buys back exactly the fast path per-access atomics
    forecloses — the experiment measured `unordered` element access costing
    **+55 % to +2747 %** (bootstrap-CI lower bounds) versus plain on every
    vectorizable kernel (auto-vectorization loss; the `memset`/`memcpy`
    libcall idioms gap widest, ~29× on `u8` fill), far past the
    pre-registered 10 % threshold that would have made per-access
    `unordered` free.
  - **Containments (normative):** (1) debug and `--gc-stress` builds compile
    every access `unordered` regardless — races stay *defined* in exactly the
    builds that hunt corruption, so a misbehaving program under test yields
    wrong numbers, not a corrupted VM; (2) the `(kaappi parallel)` slice
    helpers (Phase 3) take disjoint ranges by construction and assert
    disjointness at submission time, confining the UB surface to hand-rolled
    index arithmetic; (3) the blast radius is *per element* — distinct
    elements never interfere (false sharing is a performance topic, not a
    correctness one). `monotonic` is rejected as dominated by `unordered`
    (same measured cost, weaker optimizer freedom, over-promises per-location
    coherence this contract does not want). An `Atomics`-style ordered subset
    (`shared-buffer-cas!`) stays out of scope for v1. Rationale and numbers:
    [`research/p1-access-semantics.md`](../research/p1-access-semantics.md)
    and the kaappi#1473 experiment report.
- **`deepCopy` arm.** `.shared_buffer` aliases: allocate a stub on the
  target heap, `refcount += 1` — identical shape to the promoted-channel
  arm, minus promotion (a shared buffer is born shared; there is no
  local representation and no promotion step, which sidesteps the
  subtlest part of KEP-0002 §2 entirely).
- **FFI hand-off.** The payload is a stable, non-moving allocation, so
  C FFI libraries (`kaappi-net`, `kaappi-pg`) can read/write it with
  zero copies — a `shared-bytevector` is a natural I/O buffer. Rules for
  lifetime across an FFI call: TODO.
- **Bounds-check hoisting (normative, from P1 step 2).** To realize the plain
  fast path the hybrid buys, the backend's `-ref`/`-set!` lowering must present
  the vectorizer a counted loop with a raw element GEP and a *hoisted* bounds
  check (standard loop-invariant check motion) — a per-iteration trap the
  optimizer cannot remove would under-vectorize the plain baseline itself. The
  kaappi#1473 experiment measured the ceiling this requirement targets.
- **TODO:** exact type surface (§ Unresolved 1), `write`
  representation, `equal?` semantics, slice objects or offsets-only,
  sandbox-mode policy. (`--gc-stress` interaction is resolved: compile accesses
  `unordered` — containment 1 above.)

## Drawbacks

- **First user-visible data races in the language.** Everywhere else,
  Kaappi programs cannot express a race on Scheme data; shared buffers
  introduce deliberate, documented nondeterminism. The containment is the
  type's narrowness (no references, no growth, two element kinds) and the
  guide's channel-idiom framing — but the line "Kaappi threads share
  nothing mutable" becomes "…except shared buffers, which you opted
  into".
- **A second storage family.** `shared-bytevector` next to `bytevector`
  (and `shared-f64vector` next to SRFI-4's boxed `f64vector`) forks the
  API: library authors must choose or dispatch. Racket carries the same
  fork (`flvector` / `shared-flvector`) as the acknowledged price.
- **More refcounted unmanaged memory.** Same class of manual lifetime as
  KEP-0002's `SharedChannel`/envelopes; mitigated by sharing that KEP's
  (audited, gc-stress-tested) protocol rather than adding a parallel one.
- **An attractive nuisance.** Once shared mutable memory exists, users
  will ask for shared hash tables, shared records, shared everything.
  The no-references rule is the bright line, and this KEP should be
  quotable as the argument for why the line holds.

## Alternatives considered

- **Refcounted *immutable* payloads only** (KEP-0002 Unresolved
  question 1: large bytevectors/strings cross by reference, BEAM-binary
  style). Solves the fan-out copy multiplier and footprint without any
  race surface — but not the reassembly wall or in-place algorithms,
  which the Motivation argues are the deeper limit. If Phase 7 data
  shows fan-out cost dominating and in-place demand absent, *that*
  design should win and this KEP should be rejected in its favor; the
  two share the Phase 0 protocol either way.
- **Transfer, not share** (Dart `TransferableTypedData`, JS
  `ArrayBuffer` transfer): move the buffer O(1) and *detach* it from the
  sender — no races, no sharing, sender's handle goes dead. Runtime-
  enforceable without a type system (a detached stub raises on access).
  Attractive as a *complement* (cheap pipeline hand-off) but does not
  express N-writers-one-buffer; noted as a possible `shared-buffer-
  transfer!` extension, Unresolved question 4.
- **mmap-backed shared memory between OS processes** (Python
  `multiprocessing.shared_memory` shape): heavier isolation than Kaappi
  needs — threads already share an address space; adds naming/cleanup
  problems (POSIX shm object lifetimes) for no gain here. Rejected.
- **A full shared heap.** Rejected in KEP-0002 (Alternatives) and the
  reasoning transfers wholesale; this KEP exists precisely to relieve
  the numeric pressure *without* reopening that question.

## Prior art

What isolated-heap runtimes do when flat data outgrows copy semantics —
the same two questions as KEP-0002's survey (*what crosses, who
guarantees safety*), asked one level down. (Links current as of
2026-07.)

| System | Escape hatch | Mutable? | Safety story |
|---|---|---|---|
| **Kaappi (this KEP)** | `shared-bytevector` / `shared-f64vector` | yes | no-references rule + untorn unordered elements + channel happens-before |
| [Racket places](https://docs.racket-lang.org/reference/places.html) | `shared-flvector`, `shared-bytes`, `shared-fxvector` | yes | flat-only types; races on contents are the program's problem |
| [Erlang/BEAM](https://www.erlang.org/doc/system/binaryhandling.html) | refcounted binary heap (>64-byte binaries) | **no** — immutable | immutability; sub-binaries alias by offset |
| [JavaScript workers](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer) | `SharedArrayBuffer` + `Atomics`; plus `ArrayBuffer` transfer (detach) | yes | typed-array-only contents; `Atomics` for ordering; transfer for no-race hand-off |
| [Dart isolates](https://api.dart.dev/stable/dart-isolate/TransferableTypedData-class.html) | `TransferableTypedData` (O(1) move, sender detached) | moved, not shared | detachment — no two owners, ever |
| [Python multiprocessing](https://docs.python.org/3/library/multiprocessing.shared_memory.html) | `shared_memory` / `sharedctypes` (mmap between processes) | yes | flat ctypes/buffer contents; user locks |
| [WASM threads](https://github.com/WebAssembly/threads) | shared linear memory + atomics | yes | whole-memory sharing; tooling-level discipline |

**Racket is the direct precedent.** The places design (Tew et al.,
[DLS 2011](https://users.cs.northwestern.edu/~robby/pubs/papers/dls2010-tsffd.pdf))
is KEP-0002's closest relative, and its authors shipped
`shared-flvector`/`shared-bytes` alongside places from the start —
evidence that copy-boundary Schemes hit the flat-numeric wall
immediately, and that the fix is a *narrow flat type*, not a general
sharing mechanism. Racket also demonstrates the API fork cost this KEP
accepts (Drawbacks).

**Erlang marks the conservative endpoint.** BEAM's refcounted binaries
share only *immutable* flat data — the fan-out fix without the race
surface — and 25 years of production say that covers most of what
message-passing systems need. That is exactly this KEP's first
alternative, and the acceptance gate is largely the question "is Kaappi's
demand Erlang-shaped (read-mostly fan-out) or Racket-shaped (parallel
in-place writes)?"

**JavaScript shows both levers coexisting.** The web platform ended up
with *transfer* (detach — cheap, race-free hand-off) **and** *share*
(`SharedArrayBuffer` — with an explicit `Atomics` API for ordering),
because neither subsumes the other. It is also the cautionary tale on
scope: SAB shipped, was withdrawn after Spectre (2018), and returned
gated behind cross-origin isolation — a reminder that shared memory's
blast radius exceeds its API surface. Kaappi's no-references rule and
thread-level (not origin-level) trust model keep the analogy loose, but
the both-levers lesson directly shapes Unresolved question 4.

**WASM threads matter for the target matrix.** Kaappi's wasm32-wasi
build has no threads today (KEP-0002 degrades accordingly); if
WebAssembly's shared-memory threading reaches WASI, a `SharedBuffer`
maps naturally onto shared linear memory, while a shared *heap* never
would. Designing the buffer type now keeps that door open.

## Cross-platform / compatibility impact

- **Platforms.** Aligned ≤8-byte loads/stores are untorn on aarch64,
  x86_64, and riscv64; no other platform assumption is made.
- **WASM/WASI.** No threads ⇒ a shared buffer degrades to an ordinary
  flat buffer with the same API (single-owner, still no references).
- **Sandbox mode.** Thread creation is already blocked; same degradation
  as WASM. Whether sandboxed code may *create* (single-threaded) shared
  buffers: TODO.
- **Backward compatibility.** Strictly additive: new types, new
  procedures, no change to any existing semantics.

## Unresolved questions

*Question 2 is **resolved** by the P1 step-2 codegen experiment
(kaappi#1473 — the hybrid; see §Reference). The acceptance gate's
pre-registered criteria (P5, in
[`research/open-problems.md`](../research/open-problems.md)) have been
**evaluated**: 2026-07-16, outcome Between, stays gated — see the gate
note at the top. Questions 1 and 3–5 remain open and gated with the
rest of the KEP.*

1. **Type surface.** Distinct disjoint types (`shared-bytevector?` ⇒
   `bytevector?` is `#f`, Racket-style) or subtypes that answer `#t` to
   the base predicates and work with the existing accessor procedures?
   Disjoint is safer (no silent sharing through code that assumes
   copies); subtyping is vastly more ergonomic for FFI-adjacent code.
   Which element kinds at launch — bytes + f64 only, or the full SRFI-4
   family?
2. **Access semantics, precisely.** *Resolved (P1 step 2 — the codegen
   experiment kaappi#1473): the **hybrid**.* Interpreter primitives use
   `@atomicLoad/@atomicStore(.unordered)` unconditionally (free at dispatch
   scale); the LLVM backend compiles `-ref`/`-set!` to plain accesses, with
   soundness carried by KEP-0002's channel happens-before edges and the three
   containments in §Reference. Per-access `unordered` everywhere was rejected
   because it costs +55 %–+2747 % on vectorizable kernels (pre-registered
   threshold: 10 %); plain-everywhere stays rejected *a priori* (Boehm 2011);
   `monotonic` is dominated; an `Atomics`-style ordered subset
   (`shared-buffer-cas!`) is out of scope for v1. See the §Reference normative
   sketch, [`research/p1-access-semantics.md`](../research/p1-access-semantics.md),
   and the kaappi#1473 experiment report.
3. **Relationship to KEP-0002 UQ 1.** Should immutable refcounted
   payloads (the Erlang lever) and mutable shared buffers (this KEP) be
   one mechanism with a mutability flag, or two types? One mechanism
   halves the protocol surface; two keeps "immutable ⇒ race-free"
   visible in the type.
4. **A transfer/detach variant.** Is `shared-buffer-transfer!` (O(1)
   move, source stub goes dead) worth its API weight as the race-free
   complement, per the JS/Dart precedent?
5. **Slices.** First-class sub-buffer views (aliasing, Erlang
   sub-binary-style) or offsets-in-user-code only? Views make the
   disjoint-slices idiom pleasant and misuse (overlap) easier.

## Implementation plan

**[skeleton — sequencing firm, contents provisional; nothing starts
before the acceptance gate opens except Phase 0]**

**Phase 0 — Shared-object protocol unification (lands in KEP-0002).**
Amend KEP-0002 §1 to name the generic protocol (refcounted process-global
object, per-heap counted stubs, `deepCopy` alias arm, `freeObject`
release, destroy-at-zero, leak/gc-stress discipline) with `SharedChannel`
as its first instance and `SharedBuffer` as the declared second. Pure
specification; no code beyond what KEP-0002's phases already build. This
is the only part of this KEP that is *not* gated — it must land while
KEP-0002 §1 is still cheap to reword. **(Done:** KEP-0002 §1 specifies
the generic protocol and names this KEP's buffers the declared second
instance; `src/shared_object.zig` shipped with KEP-0002 Phase 1.)

**Gate check.** KEP-0002 Phase 7 `parallel-map` data answers: is the
pinch fan-out copies (→ prefer Alternative 1, immutable payloads), the
reassembly wall / in-place demand (→ this KEP), or absent (→ reject
both, revisit later)? Evaluated mechanically per the pre-registered
protocol in [`research/benchmarks/`](../research/benchmarks/README.md):
overhead shares with confidence intervals on the named gate cells, and
classification only when both reference machines agree — disagreement
means the KEP stays gated. **Evaluated 2026-07-16: Between, by
two-machine agreement (kaappi#1474).** Neither branch fires — the
demand is neither Racket-shaped nor Erlang-shaped/absent — so Phases
1–4 below stay gated behind the revisit trigger. Numbers and record:
the gate note at the top of this KEP; the trigger and the re-run
procedure: [Path to `Accepted`](#path-to-accepted-revisit-protocol)
below.

**Phase 1 — `SharedBuffer` core.** The type, stubs, refcounting on the
Phase 0 protocol; `-ref`/`-set!` with the §Reference access semantics;
single-threaded tests + leak checks.

**Phase 2 — Boundary integration.** `deepCopy` alias arm (thunks and
channel messages carry buffers by reference); gc-stress thread-churn
tests; the happens-before test matrix (write → send → receive → read).

**Phase 3 — `(kaappi parallel)` integration.** Slice-per-worker helpers
(`parallel-fill!`-style), guide chapter with the when-not-to-use rule,
worked example in `kaappi-examples`.

**Phase 4 — Measurement.** Re-run the Motivation benchmark plus the
fan-out and in-place workloads; publish the copy-vs-share crossover
sizes; decide Unresolved question 4 (transfer variant) with numbers.

## Path to `Accepted` (revisit protocol)

*This section is the standing tracker for this KEP's lifecycle — the
KEP is a living document until `Final`, and "waiting on evidence" is
KEP state, not actionable work, so it lives here rather than in an
open issue. The tracking issues kaappi#1596 (path to Accepted) and
kaappi#1597 (implementation-to-release) promised by kaappi#1474's and
kaappi#1475's closing comments were opened 2026-07-16 and retired the
same day in favor of this section; their bodies are preserved in the
closed issues.*

In order:

1. **The revisit trigger fires.** Real application traces — from
   `kaappi-examples` or an equivalent field report — exhibiting an
   `IP-*`-shaped hot loop: N workers producing disjoint slices of one
   large (≥ 1 MiB) flat numeric output (image tiles, matrix blocks,
   chunked map over a numeric column), or in-place demand that copy
   semantics cannot express at any cost. Synthetic kernels do not
   qualify; "Between" specifically left the gate waiting on *field*
   evidence. A qualifying report is a fresh issue on kaappi/kaappi
   citing this KEP, trace/profile attached (`kaappi-examples` has
   issues disabled, so reports cannot land there).
2. **Fresh gate re-run under the same frozen thresholds.** Protocol:
   [`research/benchmarks/README.md`](../research/benchmarks/README.md)
   §5 — the thresholds are not renegotiated (§8 records the first
   evaluation; a trigger firing buys a re-run, not a rule change). The
   campaign is turnkey per the worksheet: `benchmarks/gate/run-gate.py`
   + `classify.py`, the Kalibera–Jones floor, `w = 8`, **both lever
   settings**, on both reference machines (macOS aarch64, Linux
   x86_64).
3. **Classification reads Racket-shaped on both machines:** with
   levers `C+D` on, ≥ 2 of the 3 `IP-*` workloads with `share ≥ 25 %`
   at some size ≥ 1 MiB, CI lower bound clearing the threshold. Attach
   the filled §6 worksheet to the status PR (a reading, not an
   argument).
4. **Complete the KEP, then the status PR.** Fill the `[skeleton]`
   sections and settle the remaining unresolved questions — UQ 1 (type
   surface), UQ 3 (one mechanism or two), UQ 5 (slices), plus the
   reference-level TODOs (`write` representation, `equal?` semantics,
   FFI lifetime rules, sandbox-mode policy); UQ 2 is already resolved
   (the hybrid, kaappi#1473). Open the status PR: Draft → `Accepted`,
   update the README index annotation, and open per-phase
   implementation issues in kaappi/kaappi (scope: the Implementation
   plan above, as carried by the retired kaappi#1597).

If the re-run reads otherwise:

| Re-run outcome (both machines) | Action |
|---|---|
| Racket-shaped | Step 4 — `Accepted` |
| Erlang-shaped | Status PR: Draft → `Rejected` in favor of Alternative 1 (refcounted immutable payloads, a KEP-0002 UQ 1 follow-up) |
| Absent | Status PR: Draft → `Rejected` (both designs); revisit only with new field evidence |
| Between (or machine disagreement) | Stays gated; log the run below and keep waiting |

### Revisit log

| Date | Check | Outcome |
|---|---|---|
| 2026-07-16 | First gate evaluation (kaappi#1474): pre-registered campaign, both reference machines | **Between**, by two-machine agreement — stays gated. Record: kaappi/keps#25; datasets kaappi#1549 (macOS) / kaappi#1580 (Linux) |
| 2026-07-16 | Trigger check: systematic survey of `kaappi-examples` @ `aaeff1a` (all 13 apps), adjacent numeric repos (`kaappi-math`, `kaappi-mpl`), and the field-report channels | **Not fired** — no `IP-*` shape anywhere; the one parallel workload (parallel-primes) is a scalar reduction moving ~100 B cross-thread. [Baseline survey](https://github.com/kaappi/kaappi/issues/1596#issuecomment-4991123187) for future checks to diff against |

Future trigger checks diff `kaappi-examples` (and new numeric ecosystem
apps) against the baseline survey — the latent candidate shapes are a
rasterizer/plotting backend or a chunked numeric-column workload —
and append a row here either way.
