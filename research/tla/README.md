# TLA+ model of KEP-0002's `SharedChannel` protocol

This is the P2 deliverable from
[`research/open-problems.md`](../open-problems.md): a bounded TLA+ model
of the cross-thread channel protocol specified in
[KEP-0002](../../keps/0002-cross-thread-channels.md) §§1–7, checked with
TLC. Per P2's pre-registered decision criteria, **the model must pass all
six properties at the stated bounds before Phase 1 merges; any violation
is a KEP-0002 amendment first, code second.** The model currently
demonstrates three violations (Findings 1–3 below), so KEP-0002 needs
amending before Phase 1.

## Running

```bash
./run.sh            # all seven configs, ~90 s total; asserts expected outcomes
./run.sh core_cap4_selective   # a single config
```

Needs Java 17+. `run.sh` downloads `tla2tools.jar` on first use (results
below produced with TLC 2.19). Three configs are *expected* to fail —
they are the findings, kept failing on purpose so the counterexamples
stay reproducible; `run.sh` exits nonzero only if any config deviates
from its recorded expectation. Re-run the suite whenever KEP-0002's §4/§6
pseudocode changes (P2's standing rule).

## What is modeled

One channel; three OS threads. `t0` owns the channel pre-promotion and
runs two fibers (`f0a`, `f0b`); `t1`/`t2` run one fiber each (`f1`,
`f2`), gated until they receive their stub through the thunk hand-off.

| KEP-0002 piece | In the model |
|---|---|
| §1 refcount state machine | `rc`, `held[t]` (stubs per heap), envelope stubs for self-referential messages (`(channel-send ch ch)`), destroy-at-zero with queue deinit, the accepted cycle leak |
| §2 promotion | atomic promote: drain (with re-entrant alias outcome for a queued self-message), `rc = 1`, local-waiter migration (step 4) |
| §3 thunk hand-off | net `rc += 1` per spawned thread |
| §4 send | steps 1–8 as one mutex-atomic action; reservation; envelope build outside the lock; the step-9 copy-failure path (release reservation, ring, deinit releases partial-copy stubs); infallible push with `recv_waiters` snapshot-and-clear; per-target ring |
| §4 receive | pop + `send_waiters` snapshot; copy-out (`rc`/`held` for self messages); envelope deinit; drain-then-EOF; register + park |
| §5 notifier | `wake_pending` flag then fd, as two steps; the swap-loop / poll consume protocol as separate scheduler actions; sweep policies (below) |
| §6 close | idempotence-guarded set + both-lists snapshot-and-clear + ring |
| §7 lifecycle | waiter-list dedup (sets keyed by thread); teardown releasing all of a heap's stubs |
| cooperative scheduling | `cur[t]`: fibers of one thread serialize; primitives have no fiber switch points; the scheduler (sweep/poll) runs only when no fiber is mid-primitive |

**Atomicity discipline:** every mutex-held region of the §4/§6 pseudocode
is a single atomic action (sound — the mutex serializes them); every
lock-free window is its own step, because that is where protocol bugs
live: the registered-but-not-yet-parked window, the build, each
flag-then-fd ring, the `wake_pending` swap, the poll, each refcount
transition.

**Scoped out** (would not change the checked properties at these bounds):
notifier refcounts and the `alive` flag (no thread exits mid-model —
§7's teardown pruning is untested here); §6 timeouts; local-channel
capacity pre-promotion; the §5 deadlock heuristic (that is P4); equality
(UQ 4). Promotion's *internal* re-entrancy (early publication, §2
step 2) is modeled by its specified outcome, not rediscovered — the
model checks cross-thread interleavings, not `deepCopy`'s recursion.
Weak-memory effects are not modeled (TLA+ steps are sequentially
consistent); the §5 acq_rel argument is encoded in the action structure,
and GenMC remains P2's escalation path for memory-model doubts.

## The six pre-registered properties

| P2 property | Where |
|---|---|
| 1. refcount ≥ 0 | `RcAccounting` — strengthened to exact accounting: `rc = Σ held + self-stubs in queue + self-stubs in flight` |
| 2. destroy exactly once | `DestroyedClean` + destroy guarded in `Teardown` (reachable only once since `rc` stays 0) |
| 3. envelope always enqueued or deinit'd, never both | `EnvelopeAccounting`: `built = in-hand + queued + received + destroy-deinit + fail-deinit` |
| 4. no admitted send lost across close | `ReservedAccounting` + push never guarded on `closed` + the `strand` scenario's `NoAbandonedTask` (see Finding 2) |
| 5. drain-then-EOF | structural in `RecvEOF` (queue-empty guard precedes EOF) — TLC exercises close-vs-push interleavings against it |
| 6. no lost wakeup (liveness) | `Termination` (`<>[](AllDone ∧ AllTorn)`) under weak fairness, plus TLC deadlock checking — a stranded parked fiber is a deadlock because scripts always close the stream |

Two scenario scripts: **core** (promotion drain + migration, a
pre-promotion local self-send made optional so both the drain-alias and
the empty-queue migration paths are reachable, competing receivers on
two threads, a remote self-send, copy failures, close at the end) and
**strand** (the §8 pool-shutdown shape: one sender racing an independent
closer, two receive-until-EOF workers).

## Results (TLC 2.19, macOS aarch64, 2026-07-12)

| Config | Sweep | EOF policy | Expected | States (distinct) | Depth |
|---|---|---|---|---|---|
| `core_cap1_flipall` + liveness | flip_all | as-is | **pass** ✓ | 872,585 | 62 |
| `core_cap4_flipall` | flip_all | as-is | **pass** ✓ | 167,033 | 50 |
| `core_cap4_selective` | **selective (§5 as written)** | as-is | **fail** — Finding 1 | 53,248* | 28 |
| `strand_flipall` | flip_all | as-is (§4/§6 as written) | **fail** — Finding 2 | 4,777* | 20 |
| `strand_waitres` + liveness | flip_all | wait_reserved | **pass** ✓ (repair verified) | 17,703 | 41 |
| `core_cap4_waitres_naive` | flip_all | wait_reserved_naive | **fail** — Finding 3 | 44,514* | 26 |
| `core_cap1_waitres` + liveness | flip_all | wait_reserved | **pass** ✓ (repair, no regression) | 945,608 | 63 |

\* states explored before the violation stopped the search.

All four passing configs satisfy every safety invariant, TLC's deadlock
check, and (where marked) the `Termination` liveness property.

---

## Finding 1 — lost wakeup: consumed registration + §5's selective sweep

**Violates:** property 6 (no lost wakeup); makes §6's "close wakes
everyone" false. **Config:** `core_cap4_selective` (deadlock, 25-step
counterexample).

Three normative pieces of KEP-0002 contradict each other:

- §4/§6/§7(a): every ring **snapshots-and-clears** the waiter list;
  "threads whose fibers re-park simply re-register."
- §5: the sweep flips only fibers "whose channel is ready *for it*."
- §4: "Wake policy is wake-all on both sides … losers of the retry race
  re-park."

A fiber that is *rung but no longer ready* — because another receiver
drained the queue first, exactly the loser §4 anticipates — is neither
flipped (the §5 readiness filter skips it, so it never retries and never
re-registers) nor still registered (the ring consumed its entry). No
future event can reach it: later pushes snapshot a list it is not on,
and `channel-close!` rings only currently-registered notifiers. The
"loser re-parks and re-registers" recovery assumes the loser gets to
*run*, which is precisely what the readiness filter denies.

Counterexample (TLC's shortest, capacity 4): f2 registers `t2` and is
about to park; f0a pushes, snapshot `{t2}`, clears the list, rings `t2`;
f0b's receive pops the message first; f2 parks; `t2`'s scheduler
consumes the flag and the fd, sweeps — queue empty, not closed, f2 not
ready, not flipped; f0a closes — snapshot `∅`, **rings nobody**; f1's
send raises on the closed channel; `t0`/`t1` tear down. Final state:
`closed = TRUE` (f2 is now *ready* by §5's own definition), f2 parked
forever, `t2` never tears down. In §8 terms: an idle pool worker sleeps
through `pool-shutdown!` and `thread-join!` hangs — the exact "pools
must never silently hang" case P4 flags.

**Repair directions.** (R1) *Unconditional sweep*: flip every fiber in
the shared-waiter registry on any ring; woken losers retry, re-park, and
re-register, making §4's wording literally true. Verified here as
`SweepPolicy = "flip_all"` — all six properties pass. Costs spurious
wakes (the notifier is channel-anonymous anyway, so a multi-channel
thread already sweeps broadly). (R2) *Persistent registration*: rings
snapshot without clearing; entries are removed when the sweep actually
flips a fiber (or at timeout/destroy). Keeps wakeups targeted but moves
entry removal from the ringer to the waiter's thread and adds channel
lock traffic at sweep time; §7's lifecycle rules would need rewriting.
Not modeled. (R3) *Sweep re-registers* on behalf of parked-but-unready
fibers (as §2 step 4 already does at promotion). Same lock-at-sweep
cost. Not modeled. R1 is the minimal amendment: one §5 sentence plus
dropping §7's "re-park ⇒ re-register" reliance.

## Finding 2 — an admitted send can be abandoned across close

**Violates:** §8's "Tasks submitted before shutdown all run and their
replies stay receivable" (property 4's user-visible face). **Config:**
`strand_flipall` (`NoAbandonedTask`, 17-step counterexample).

§4 makes reservation the point of no return: a send admitted before
`channel-close!` completes its push afterward, and "its message is never
lost." The model shows "never lost" means *enqueued*, not *receivable*:
f1's send reserves; f0a closes (nobody parked — rings nobody); both
until-EOF workers find the queue empty and closed and take EOF; f1's
push lands; teardown destroys the channel and deinits the message,
unreceived. The submitting `channel-send` **returned successfully**, so
in §8's pool a `task-wait` on the reply channel now hangs with no error
anywhere — reachable whenever `pool-submit` races `pool-shutdown!`.

**Repair, verified** (`EofPolicy = "wait_reserved"`, config
`strand_waitres`): EOF additionally waits out the reservation window —
§4 receive step 6 becomes *"if closed **and reserved = 0**: return
(eof-object)"*, and step 7's registration is also allowed when
`closed ∧ reserved > 0`. A receiver that finds the channel closed but a
send still admitted parks; the late push rings `recv_waiters` as always
and the message is drained before anyone sees EOF. All properties pass,
including `NoAbandonedTask` and liveness. The alternative — documenting
the race away ("don't race submit against shutdown") — contradicts
§4's own reservation-as-admission promise and leaves a silent hang in
the flagship §8 idiom.

## Finding 3 — the obvious Finding-2 repair deadlocks without a failure-path ring

**Config:** `core_cap4_waitres_naive` (deadlock, 22-step counterexample).

The naive version of the Finding-2 repair (EOF waits for `reserved = 0`
and nothing else changes) strands receivers: f1 reserves just before
close; a receiver, blocked from EOF by `reserved = 1`, registers and
parks; f1's *copy fails* — and §4's failure path (step 9) rings only
`send_waiters`, because in the unrepaired protocol only senders can be
waiting on a reservation. The parked receiver's EOF condition is now
satisfied (`closed`, queue empty, `reserved = 0`) but nothing ever rings
its notifier.

**Repair, verified** (part of `EofPolicy = "wait_reserved"`): the §4
failure path's snapshot-and-clear also covers `recv_waiters` when the
channel is closed (equivalently: whenever it releases the last
reservation on a closed channel). With it, `core_cap1_waitres` passes
all properties including liveness with copy failures enabled — the full
repair does not regress the core protocol.

---

## Amendment summary for KEP-0002 (proposed, pending owner review)

1. **§5 sweep** (Finding 1): `sweepSharedWaiters` flips *every* fiber in
   the shared-waiter registry (R1); delete the per-fiber readiness
   filter, or reclassify it as an invalid optimization. §4's wake-all
   wording and §7(a)'s "re-park ⇒ re-register" then compose soundly.
2. **§4 receive step 6 / §6** (Finding 2): EOF requires
   `closed ∧ queue empty ∧ reserved = 0`; registration permitted when
   `closed ∧ reserved > 0`. §8's shutdown claim becomes true as stated.
3. **§4 step 9 failure path** (Finding 3): on a closed channel the
   failure path rings `recv_waiters` too.

The three violating configs stay in the suite as regression witnesses:
after the KEP text is amended, the model's `"selective"` /
`"asis"` / `"wait_reserved_naive"` modes remain as documentation of the
rejected designs, and the passing modes become the spec's normative
behavior.

## Fidelity caveats

This model checks the *specified protocol*, not the future Zig
implementation — the Phase 3 PCT-style stress harness (P2 method
step 2) covers the code-vs-spec gap. Known coarsenings, each argued
sound in comments in the module: mutex regions are atomic actions; the
sweep is atomic per swap-loop iteration (justified by §5's acq_rel
happens-before argument); `PollWake` is enabled whenever the fd is
pending (a superset of real schedules — kqueue triggers and eventfd
counters stay armed until retrieved); local-channel wake modeling covers
only the one local waiter the scripts can produce. One observation
outside the checked properties: §4's receive pops the envelope *before*
the copy-out — the KEP does not specify what happens if the receive-side
`deepCopy` fails (OOM), which as written would lose the popped message;
worth a sentence in §4 when it is amended.
