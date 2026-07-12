# Research plan: open problems in KEP-0002 / KEP-0003

This document is the research roadmap for the open problems in
[KEP-0002](../keps/0002-cross-thread-channels.md) (cross-thread channels)
and [KEP-0003](../keps/0003-shared-flat-numeric-data.md) (shared flat
numeric data). Each problem gets: the question as the KEP states it, why
it is hard, a reading list of published work, a method, **decision
criteria written before the experiments run** (pre-registration — so the
numbers judge the design instead of the other way around), and where the
answer lands.

It is a working document, not a KEP: it carries no design authority, and
when a problem is resolved the answer moves into the owning KEP and the
section here is reduced to a pointer.

*All links verified 2026-07-12. Free author/institutional PDFs are given
alongside DOIs where they exist.*

## Priority and sequencing

| # | Problem | Owner | When | Stakes |
|---|---------|-------|------|--------|
| P1 | Racing element-access semantics | KEP-0003 UQ 2 | before KEP-0003 Phase 1 | highest — wrong answer is UB or a gutted fast path |
| P2 | Concurrency-protocol verification | KEP-0002 §§2, 4–6 | before KEP-0002 Phase 1 | highest leverage — bugs found here never reach Zig |
| P3 | Envelope cost & copy elision | KEP-0002 UQ 1 | with KEP-0002 Phase 1 | perf only; design is correct either way |
| P4 | Deadlock-heuristic precision | KEP-0002 UQ 2 | KEP-0002 Phase 3 | UX of hangs vs. errors |
| P5 | Benchmark methodology & the KEP-0003 gate | KEP-0002 Phase 7 / KEP-0003 gate | before Phase 7 runs | decides KEP-0003's fate |
| P6 | Cycle collection for shared objects | KEP-0002 UQ 6 | parked until Phase 5 usage data | low — debug tooling only |
| P7 | Darwin `SO_REUSEPORT` distribution | KEP-0002 §9 | first thing in Phase 6 | small, empirical |

P1 and P2 are the two that must be answered before their respective
Phase 1 code exists. P3–P5 attach to already-planned implementation
phases. P6 and P7 are bounded and parked.

---

## P1 — Racing element-access semantics for shared buffers

**Problem (KEP-0003 UQ 2).** "Are plain aligned loads/stores enough, or
must element access compile to `.unordered` atomics to prevent the
optimizer from inventing tears? Do we offer any `Atomics`-style ordered
subset (`shared-buffer-cas!`), or is 'channels are the only ordering'
the permanent answer?"

**Why it is hard.** The adversary is the compiler, not the CPU. Racing
*plain* accesses are undefined behavior at the LLVM IR level regardless
of what aarch64/x86_64 guarantee, so "aligned loads don't tear on our
platforms" is not by itself a sound argument — the optimizer may cache,
duplicate, or invent loads. The safe encoding (`unordered`/`monotonic`
atomics) is exactly what LLVM's own guidance recommends for Java-like
"racy but memory-safe" languages, but atomic accesses inhibit
auto-vectorization — potentially gutting the numeric inner loops this
KEP exists to serve. JavaScript's `SharedArrayBuffer` and WebAssembly's
shared memory faced the identical dilemma and chose access-atomic,
unordered semantics with *bounded* nondeterminism (racing plain accesses
return some written value, never fire-the-machine UB) — the closest
published precedent for KEP-0003's "untorn, unordered, memory-safe"
wording, including its formal repair history.

**Reading list.**

- Boehm & Adve, *Foundations of the C++ Concurrency Memory Model*,
  PLDI 2008 — why catch-fire semantics for races was chosen; the
  data-race-free contract.
  [ACM](https://dl.acm.org/doi/10.1145/1375581.1375591)
- Boehm, *How to Miscompile Programs with "Benign" Data Races*,
  HotPar 2011 — concrete optimizer transformations that break "harmless"
  races; the direct argument against plain accesses.
  [USENIX](https://www.usenix.org/conference/hotpar-11/how-miscompile-programs-benign-data-races) ·
  [PDF](http://www.usenix.org/events/hotpar11/tech/final_files/Boehm.pdf)
- Manson, Pugh & Adve, *The Java Memory Model*, POPL 2005 — the
  alternative contract: races stay defined, bounded by causality; the
  no-out-of-thin-air requirement KEP-0003 would inherit.
  [ACM](https://dl.acm.org/doi/10.1145/1040305.1040336) ·
  [PDF](http://rsim.cs.uiuc.edu/Pubs/popl05.pdf)
- Watt, Rossberg & Pichon-Pharabod, *Weakening WebAssembly*,
  OOPSLA 2019 — shared linear memory with per-access atomicity
  granularity; directly reusable spec vocabulary, and the model the WASM
  target would eventually meet.
  [ACM](https://dl.acm.org/doi/10.1145/3360559)
- Watt, Pulte, Podkopaev, Barbier, Dolan, Flur, Pichon-Pharabod & Guo,
  *Repairing and Mechanising the JavaScript Relaxed Memory Model*,
  PLDI 2020 — SAB semantics as shipped were subtly wrong (ARMv8
  compilation, SC-DRF failure); what "we defined racy access semantics"
  costs to get right.
  [ACM](https://dl.acm.org/doi/10.1145/3385412.3385973)
- Lahav, Vafeiadis, Kang, Hur & Dreyer, *Repairing Sequential
  Consistency in C/C++11*, PLDI 2017 — background on how subtle the
  weak-atomics design space is; note the Dec 2024
  [corrigendum](https://www.cs.tau.ac.il/~orilahav/papers/pldi17_corrigendum.html)
  (register promotion claim) — even the repairs needed repair.
  [Project page](https://plv.mpi-sws.org/scfix/)
- Normative, non-paper: [LLVM Atomics guide](https://llvm.org/docs/Atomics.html)
  (`unordered` is documented as intended for Java-style racy loads) and
  Zig's `@atomicLoad`/`@atomicStore` orderings, which map onto it.

**Method.**
1. Constraints memo: what each candidate (plain / `unordered` /
   `monotonic` / hybrid "plain within a task's slice, fences at channel
   edges") promises and forbids, in the vocabulary of the JS/Wasm models.
2. Codegen experiment on aarch64 + x86_64: the KEP-0003 Motivation
   kernels (fill, map, reduction over `f64`) compiled via Kaappi's LLVM
   backend under each encoding; measure vectorization loss directly.
3. If `unordered` costs are unacceptable and plain is unsound, evaluate
   the hybrid: plain accesses inside a worker's slice justified by a
   no-concurrent-access argument at the *protocol* level (slices handed
   out via channels; the channel edge is the fence) — i.e., move the
   soundness burden from every access to the hand-off, and document
   overlapping-slice races as the one remaining hole.

**Decision criteria (pre-registered).** If `unordered` element access
costs < 10% on the vectorizable kernels, take it unconditionally (full
memory-safety, no caveats). If it costs more than that, adopt the hybrid
and require the guide to state the overlapping-slices caveat in its
first paragraph. Plain-accesses-everywhere is rejected *a priori* on
Boehm 2011 grounds. An `Atomics`-style ordered subset is out of scope
for v1 either way; revisit only with a concrete user demand.

**Lands in:** KEP-0003 Reference-level design (access semantics become
normative) + UQ 2 resolution. The codegen experiment is a follow-up work
item in the kaappi repo (needs the LLVM backend).

---

## P2 — Concurrency-protocol verification

**Problem (implicit in KEP-0002 §§2, 4–6).** The send/receive/close/
promotion/wakeup protocol is specified as normative pseudocode with
hand-argued interleaving claims ("the classic lost wakeup is
structurally impossible", "no interleaving loses a wakeup",
"reservation-as-admission"). Hand review has already found two real
protocol bugs (re-entrant promotion, refcount cycle leaks). What
machine-checks the rest?

**Why it is hard.** The state space is the product of: N threads'
positions inside the §4 sequences, queue/reservation counters, the
`closed` flag, waiter-list contents, `wake_pending` flags, and refcounts
— far beyond what example-based tests explore. And the implementation
language (Zig, no checked concurrency model) provides no net.

**Reading list.**

- Lamport, *Specifying Systems* — TLA+/PlusCal; the whole book is free.
  [Book page](https://lamport.azurewebsites.net/tla/book.html)
- Musuvathi, Qadeer, Ball, Basler, Nainar & Neamtiu, *Finding and
  Reproducing Heisenbugs in Concurrent Programs* (CHESS), OSDI 2008 —
  systematic schedule exploration bolted onto real code; the shape of
  the eventual Zig stress harness.
  [MSR](https://www.microsoft.com/en-us/research/publication/finding-and-reproducing-heisenbugs-in-concurrent-programs/) ·
  [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/osdi2008-CHESS.pdf)
- Burckhardt, Kothari, Musuvathi & Nagarakatte, *A Randomized Scheduler
  with Probabilistic Guarantees of Finding Bugs* (PCT), ASPLOS 2010 —
  the cheap version: randomized priorities + d−1 change points beat
  naive stress by orders of magnitude, with a proved bug-finding bound.
  [ACM](https://dl.acm.org/doi/10.1145/1736020.1736040)
- Kokologiannakis & Vafeiadis, *GenMC: A Model Checker for Weak Memory
  Models*, CAV 2021 — stateless model checking of real C/C++ code under
  RC11/IMM; the heavyweight option if the Zig protocol core can be
  extracted to C-compatible form.
  [Project](https://plv.mpi-sws.org/genmc/) ·
  [PDF](https://plv.mpi-sws.org/genmc/cav21-paper.pdf)
- Grey but load-bearing: [tokio-rs/loom](https://github.com/tokio-rs/loom)
  — Rust's exhaustive-interleaving test harness; the best existing
  design for "model checking as a unit test", worth imitating in Zig.

**Method.**
1. **Before Phase 1:** a bounded PlusCal/TLA+ model of `SharedChannel` —
   2–3 threads, queue capacity ≤ 2, operations: promote (with local
   drain + waiter migration), send (§4 reservation path), receive,
   close, notify/sweep (§5 `wake_pending` protocol), stub free.
   Invariants to check: refcount ≥ 0 and destroy-exactly-once; a built
   envelope is always enqueued or deinit'd (no leak, no double-free);
   no admitted send is lost across close (reservation-as-admission);
   drain-then-EOF; and the liveness property *a parked waiter whose
   channel becomes ready is eventually swept* (no lost wakeup) under
   weak fairness.
2. **Phase 3:** PCT-style randomized scheduling in the Zig stress tests
   — seed-controlled yield injection at every lock acquire/release and
   atomic op in `shared_object.zig`/`shared_channel.zig`, with the seed
   printed on failure for deterministic replay (CHESS's reproducibility
   lesson, loom's ergonomics).
3. GenMC is the escalation path if a weak-memory-specific doubt appears
   (the §5 `wake_pending` acq_rel/fd protocol is the candidate); not
   planned by default.

**Decision criteria.** The TLA+ model must pass all six properties at
the stated bounds before Phase 1 merges; any violation is a KEP-0002
amendment first, code second. The model lives in `research/tla/` and is
re-run when §4/§6 pseudocode changes.

**Lands in:** `research/tla/shared_channel.tla` (follow-up work item,
its own PR); KEP-0002 Phase 1/3 test plans reference it.

**Status (2026-07-12).** Method step 1 is done: the model lives in
[`research/tla/`](tla/README.md) (TLC 2.19, seven configs, ~950k
distinct states at the largest bound) and checks all six properties.
Verdict per the pre-registered criteria: **KEP-0002 must be amended
before Phase 1.** Three violations found, each with a machine-checked
counterexample and a candidate repair verified in the same model:
(1) the §5 selective sweep loses wakeups for waiters whose registration
was consumed by a ring they lost — permanent hang that even
`channel-close!` cannot reach; repair `flip_all` verified. (2) a
reservation-admitted send racing `channel-close!` can be destroyed
unreceived after all until-EOF workers exit — §8's "tasks submitted
before shutdown all run" fails; repair (EOF also waits for
`reserved = 0`) verified. (3) that repair is sound only if the §4
failure path also rings `recv_waiters` on a closed channel. **The
amendment landed 2026-07-12** — §5 unconditional sweep, §4/§6
reserved-aware EOF, §4 closed-channel failure ring, plus newly
specified receive-side copy-failure semantics (re-queue at head, ring
receivers; transient capacity overshoot documented) — every change
model-checked before the text changed, and the nine-config suite
(three intentionally-failing regression witnesses) is now KEP-0002's
Phase 1 merge gate. Method steps 2 (PCT stress harness) and 3 (GenMC
escalation) remain with Phase 3.

---

## P3 — Envelope cost and copy elision

**Problem (KEP-0002 UQ 1).** "Is a GC struct per message acceptable for
small hot messages (fixnums, short strings)? … whether the envelope
backing becomes a reusable arena", plus the two pre-identified elision
levers: immediates skipping the envelope, and large immutable payloads
crossing by refcounted reference (BEAM binaries).

**Why it is hard.** Not conceptually — it is a measurement problem with
a 25-year-old design space. The risk is choosing by intuition instead of
by the taxonomy the literature already built.

**Reading list.**

- Johansson, Sagonas & Wilhelmsson, *Heap Architectures for Concurrent
  Languages using Message Passing*, ISMM 2002 — the exact design space:
  private heaps (Kaappi today) vs. shared heap vs. **hybrid with a
  separate message area** (Kaappi's envelopes), with measured trade-offs
  in Erlang/HiPE. The envelope-vs-arena question is this paper's
  message-area allocation question.
  [PDF](https://www.fantasi.se/publications/ISMM02.pdf)
- Gay & Aiken, *Memory Management with Explicit Regions*, PLDI 1998 —
  region allocator design and costs; the arena option's foundations
  (message lifetime is a trivially known region).
  [ACM](https://dl.acm.org/doi/10.1145/277650.277748)
- Grey, authoritative: Erlang's
  [message-passing internals blog](https://www.erlang.org/blog/message-passing/)
  and the
  [efficiency guide on processes](https://www.erlang.org/doc/system/eff_guide_processes.html)
  (`off_heap` message queues; the >64-byte refcounted binary heap) —
  production-tested answers to both elision levers.

**Method.** The Phase 1 micro-benchmark harness grows an A/B/C/D matrix
over the same message workloads (fixnum, small pair, 1 KiB string,
64 KiB bytevector, deep record): (A) per-message GC struct as specified;
(B) reusable per-channel arena behind the same `Envelope` interface;
(C) A or B plus the immediate fast path (fixnums/booleans/chars skip the
envelope heap entirely); (D) C plus refcounted immutable side-heap for
large bytevectors/strings. Metrics: ns/message at each size, allocations
per message, and the §1 symbol-table lock contention figure (many
threads, symbol-heavy records).

**Decision criteria (pre-registered).** (C) ships if immediates are
≥ 2× (A) for fixnum messages — expected, near-certain. (B) replaces (A)
only if it wins ≥ 30% on the small-message workloads *and* survives the
gc-stress/leak suite with no new lifetime rules visible outside
`shared_channel.zig`. (D) is KEP-0003's Alternative 1 and also feeds
P5's gate — implement behind a flag for measurement, but its *shipping*
decision belongs to the gate, not to this benchmark alone.

**Lands in:** KEP-0002 UQ 1 resolution (Phase 7 confirms at scale);
possibly a one-paragraph §1 amendment if (B) wins.

---

## P4 — Deadlock-heuristic precision

**Problem (KEP-0002 UQ 2).** Per-channel `refcount > 1` is a sound
"another thread may act" test; is the coarse "other live OS threads
exist" disjunct still needed, or can pure refcount reasoning replace it?

**Why it is hard.** The heuristic trades two failure modes: too eager →
false deadlock errors (a thread that *would* have received a channel
through a future message gets killed); too lazy → real deadlocks hang
silently (mitigated by §6 timeouts, but a worse default UX than today's
local detector.)

**Reading list.**

- Marlow, Peyton Jones & Singh, *Runtime Support for Multicore Haskell*,
  ICFP 2009 — GHC's `BlockedIndefinitelyOnMVar`: deadlock detection as
  GC reachability ("no reachable thread can wake this one"), the direct
  structural ancestor of the refcount test — including its documented
  soundness edges (threads resurrected via finalizers/FFI, detection
  deferred to the next GC).
  [ACM](https://dl.acm.org/doi/10.1145/1596550.1596563) ·
  [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2009/09/multicore-ghc.pdf)
- Peyton Jones, Gordon & Finne, *Concurrent Haskell*, POPL 1996 — the
  MVar semantics the ICFP 2009 machinery serves; background.
  [ACM](https://dl.acm.org/doi/10.1145/237721.237794)
- Kobayashi, *A New Type System for Deadlock-Free Processes*,
  CONCUR 2006 — the static alternative and why it is out of reach here:
  the guarantee rides on a type system a dynamically-typed R7RS Scheme
  cannot carry.
  [Springer](https://link.springer.com/chapter/10.1007/11817949_16)
- Christakis & Sagonas, *Detection of Asynchronous Message Passing
  Errors Using Static Analysis*, PADL 2011 — what a *tooling-level*
  (Dialyzer-style, optional, unsound-but-useful) analysis can catch for
  Erlang-shaped message passing; the model for a future `kaappi-lsp`
  lint rather than a runtime guarantee.
  [Springer](https://link.springer.com/chapter/10.1007/978-3-642-18378-2_3) ·
  [PDF](https://mariachris.github.io/Pubs/PADL-2011.pdf)
- Grey, normative precedent: GHC's
  [Control.Concurrent documentation](https://hackage.haskell.org/package/base/docs/Control-Concurrent.html)
  on the exceptions and their caveats — the user-facing contract wording
  to emulate.

**Method.** Formalize "wakeup possible for fiber F waiting on channel
C" as reachability over the stub graph: some *other* live actor (thread
or queued envelope) holds a counted reference to C. Enumerate the
soundness edges against GHC's list: (a) envelope-in-flight holds rc —
already handled; (b) the *waiter's own* stub inflates rc — must subtract
self-references or the test never fires for rc = self-only cases;
(c) C reachable only from a message queued on a channel nobody can
receive from (transitive deadness — GHC gets this free from GC
transitivity; refcounts do not). Case (c) is the interesting one: decide
whether to accept the imprecision (blocks forever; timeouts as hatch) or
run a reachability pass over shared objects at "all schedulers idle"
time. Then re-examine whether the global thread-count disjunct adds
anything the per-channel test misses.

**Decision criteria.** Drop the global disjunct iff the Phase 3 test
matrix shows no case where it fires correctly and the refcount test does
not. Accept case (c) imprecision for v1 (document: cross-thread
deadlocks can hang; use timeouts), unless the TLA+ model from P2 shows
it reachable from the §8 pool idioms — pools are the one pattern that
must never silently hang.

**Lands in:** KEP-0002 UQ 2 resolution in the Phase 3 review; guide
wording for the hang-vs-error contract.

---

## P5 — Benchmark methodology and the KEP-0003 acceptance gate

**Problem.** KEP-0002 Phase 7 must produce the `parallel-map` scaling
data that KEP-0003's gate consumes ("Erlang-shaped or Racket-shaped?").
A gate evaluated on ad-hoc numbers, chosen after the fact, would be
motivated reasoning with a bibliography.

**Reading list.**

- Georges, Buytaert & Eeckhout, *Statistically Rigorous Java Performance
  Evaluation*, OOPSLA 2007 — confidence intervals, multiple VM
  invocations, why "best of N" lies.
  [ACM](https://dl.acm.org/doi/10.1145/1297027.1297033) ·
  [PDF](https://dri.es/files/oopsla07-georges.pdf)
- Mytkowicz, Diwan, Hauswirth & Sweeney, *Producing Wrong Data Without
  Doing Anything Obviously Wrong!*, ASPLOS 2009 — measurement bias
  (link order, environment size!); mandates setup randomization.
  [dblp](https://dblp.uni-trier.de/rec/conf/asplos/MytkowiczDHS09.html) ·
  [PDF](https://users.cs.northwestern.edu/~robby/courses/322-2013-spring/mytkowicz-wrong-data.pdf)
- Kalibera & Jones, *Rigorous Benchmarking in Reasonable Time*,
  ISMM 2013 — how many iterations at which level (invocation vs.
  iteration) for a target confidence; the budget formula Phase 7 should
  apply.
  [ACM](https://dl.acm.org/doi/10.1145/2464157.2464160) ·
  [PDF](https://kar.kent.ac.uk/33611/45/p63-kaliber.pdf)
- Blackburn et al., *The DaCapo Benchmarks*, OOPSLA 2006 — workload
  *suite* design: diversity metrics, why one kernel proves nothing.
  [ACM](https://dl.acm.org/doi/10.1145/1167473.1167488) ·
  [PDF](https://www.steveblackburn.org/pubs/papers/dacapo-oopsla-2006.pdf)
- Tew, Swaine, Flatt, Findler & Dinda, *Places: Adding Message-Passing
  Parallelism to Racket*, DLS 2011 — the closest system's evaluation:
  NAS-style kernels over places; the workload template to adapt.
  [PDF](https://users.cs.northwestern.edu/~robby/pubs/papers/dls2010-tsffd.pdf)

**Method.** Pre-register in this document, before Phase 7 runs: the
workload matrix (payload kind: bytevector / f64 vector / record tree ×
size: 64 KiB–64 MiB × workers: 1–2×cores × read-only fan-out vs.
in-place-shaped result assembly), the stats protocol (Kalibera-Jones
iteration counts, setup randomization per Mytkowicz), and the gate rule.

**Gate rule (pre-registered, first cut — refine wording in a KEP-0003
amendment before Phase 7):** classify the demand *Racket-shaped* (KEP-0003
proceeds) if, on ≥ 2 of the in-place-shaped workloads at 8 workers,
copy+reassembly overhead ≥ 25% of end-to-end time *after* P3's elision
levers (immediates + immutable side-heap) are applied; classify it
*Erlang-shaped* (immutable side-heap suffices; KEP-0003 rejected in
favor of its Alternative 1) if elision alone brings overhead < 10%
everywhere; anything between: KEP-0003 stays gated, revisit with real
application traces from `kaappi-examples`.

**Lands in:** a `research/benchmarks/` plan + KEP-0003 gate amendment;
Phase 7 executes it.

---

## P6 — Cycle collection for shared objects

**Problem (KEP-0002 UQ 6).** Refcounting never reclaims a channel kept
alive only by stubs inside its own (or a peer's) queued envelopes. Is a
debug-build cycle reporter worth building, and on what algorithm?

**Reading list.**

- Bacon & Rajan, *Concurrent Cycle Collection in Reference Counted
  Systems*, ECOOP 2001 — trial deletion with candidate buffering; the
  synchronous variant is the debug-reporter algorithm (the concurrent
  machinery is unnecessary at leak-check time when the world is stopped).
  [Springer](https://link.springer.com/chapter/10.1007/3-540-45337-7_12) ·
  [PDF](https://pages.cs.wisc.edu/~cymen/misc/interests/Bacon01Concurrent.pdf)
- Shahriyar, Blackburn & Frampton, *Down for the Count? Getting
  Reference Counting Back in the Ring*, ISMM 2012 — modern RC cost
  analysis; calibrates what a production (non-debug) collector would
  cost, i.e., the argument for *not* building one.
  [ACM](https://dl.acm.org/doi/10.1145/2258996.2259008) ·
  [PDF](https://www.steveblackburn.org/pubs/papers/rc-ismm-2012.pdf)

**Method & criteria.** Parked per UQ 6 until Phase 5 usage data exists.
If real programs form cycles: implement synchronous trial deletion over
the stub graph (roots: all stubs in all queued envelopes) behind
`--gc-stress`/leak-check builds only, reporting "channel reachable only
from its own queue" with allocation sites. A production cycle collector
stays rejected on Shahriyar-et-al. cost grounds unless leak reports
arrive from the field.

**Lands in:** KEP-0002 UQ 6; debug tooling in the kaappi repo if
triggered.

---

## P7 — Darwin `SO_REUSEPORT` accept distribution

**Problem (KEP-0002 §9).** Linux hashes the 4-tuple across
`SO_REUSEPORT` listeners; Darwin reputedly concentrates accepts on the
most recently bound socket. Quantify the skew; decide whether the
userspace fd-distributor fallback is needed.

**Reading (grey — this is systems folklore to be replaced by a
measurement).**

- Kerrisk, [*The SO_REUSEPORT socket option*](https://lwn.net/Articles/542629/),
  LWN 2013 — the Linux design and its load-balancing intent.
- [*Avoiding unintended connection failures with SO_REUSEPORT*](https://lwn.net/Articles/853637/),
  LWN 2021 — the drain/migration edge cases that also apply to
  `http-listen-parallel` shutdown.
- FreeBSD added `SO_REUSEPORT_LB` (see
  [setsockopt(2)](https://man.freebsd.org/cgi/man.cgi?query=setsockopt&sektion=2))
  precisely because classic BSD `SO_REUSEPORT` does not balance —
  the datapoint suggesting Darwin (shared BSD lineage) needs measuring,
  not trusting.

**Method.** A ~50-line harness: N listeners on one port (each tagging
accepts with its index), M short-lived connections from a separate
process, chi-squared test against uniform. Run on macOS (aarch64) and
Linux (x86_64), N ∈ {2, 4, 8}, M = 10 000. First task of Phase 6.

**Decision criteria.** If Darwin's max/min per-listener ratio > 3 at
N = cores, implement the §9 fallback (acceptor thread + fd fixnums over
a shared channel); otherwise document the measured skew and ship the
plain `SO_REUSEPORT` path everywhere.

**Lands in:** KEP-0002 §9 / Phase 6; `kaappi-net` implementation choice.

---

## Follow-up work items (tracked, not part of this document's PR)

1. ~~`research/tla/shared_channel.tla` — the P2 model (own PR to this
   repo).~~ Done, and the KEP-0002 §4–§6 amendment its findings
   required has landed — see P2's status block. Next in line for this
   repo: the P1 constraints memo (method step 1) and the P5
   `research/benchmarks/` spec; KEP-0002 Phase 1 implementation moves
   to the kaappi repo.
2. P1 codegen/vectorization micro-benchmark — kaappi repo (needs the
   LLVM backend).
3. P3 envelope A/B/C/D harness — kaappi repo, part of KEP-0002 Phase 1.
4. P5 `research/benchmarks/` workload matrix spec — this repo, before
   Phase 7.
5. P7 accept-distribution harness — kaappi-net repo, first task of
   Phase 6.
