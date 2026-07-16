# TLA+ model of KEP-0002's `SharedChannel` protocol

This is the P2 deliverable from
[`research/open-problems.md`](../open-problems.md): a bounded TLA+ model
of the cross-thread channel protocol specified in
[KEP-0002](../../keps/0002-cross-thread-channels.md) §§1–7, checked with
TLC. Per P2's pre-registered decision criteria, **the model must pass
all six properties at the stated bounds before Phase 1 merges; any
violation is a KEP-0002 amendment first, code second.**

The model found three protocol bugs in the original KEP text
(Findings 1–3 below) and exposed one unspecified case (receive-side
copy failure). **All four are repaired/specified in the amended KEP-0002
text, and every repair was model-checked before it became spec text.**
The 2026-07-16 rendezvous amendment (capacity 0,
[kaappi#1601](https://github.com/kaappi/kaappi/issues/1601)) extended
the model with demand-bounded admission and found a fourth protocol bug
before any code existed (Finding 4 below). Review of the implementation
([kaappi#1604](https://github.com/kaappi/kaappi/pull/1604)) then found
two more demand-accounting races the first extension's matched-budget
script could not see (Findings 5 and 6 below) — both repaired here
first, per the standing rule. The rejected designs remain in the suite
as regression witnesses: six configs fail *by design* and `run.sh`
asserts those expectations.

## Running

```bash
./run.sh                       # all sixteen configs, ~15 min total
./run.sh core_cap4_selective   # a single config
```

Needs Java 17+. `run.sh` downloads `tla2tools.jar` on first use (results
below produced with TLC 2.19) and exits nonzero only if a config
deviates from its recorded expectation. Re-run the suite whenever
KEP-0002's §4–§6 pseudocode changes (P2's standing rule, now also the
KEP's Phase 1 merge gate).

## What is modeled

One channel; three OS threads. `t0` owns the channel pre-promotion and
runs two fibers (`f0a`, `f0b`); `t1`/`t2` run one fiber each (`f1`,
`f2`), gated until they receive their stub through the thunk hand-off.

| KEP-0002 piece | In the model |
|---|---|
| §1 refcount state machine | `rc`, `held[t]` (stubs per heap), envelope stubs for self-referential messages (`(channel-send ch ch)`), destroy-at-zero with queue deinit, the accepted cycle leak |
| §2 promotion | atomic promote: drain (with re-entrant alias outcome for a queued self-message), `rc = 1`, local-waiter migration (step 4) |
| §3 thunk hand-off | net `rc += 1` per spawned thread |
| §4 send | steps 1–8 as one mutex-atomic action; reservation; envelope build outside the lock; the step-9 copy-failure path (release reservation, ring — incl. the amended closed-channel `recv_waiters` ring — deinit releases partial-copy stubs); infallible push with `recv_waiters` snapshot-and-clear; per-target ring |
| §4 receive | pop + `send_waiters` snapshot; copy-out (`rc`/`held` for self messages); envelope deinit; the amended copy-failure re-queue-at-head + `recv_waiters` ring; drain-then-EOF with the amended `reserved == 0` guard; register + park |
| §5 notifier | `wake_pending` flag then fd, as two steps; the swap-loop / poll consume protocol as separate scheduler actions; the amended unconditional sweep (and the rejected readiness-filtered sweep) |
| §6 close | idempotence-guarded set + both-lists snapshot-and-clear + ring |
| §6 rendezvous (Cap = 0) | demand-bounded admission (`Bound = rvDemand`); per-fiber demand tokens acquired idempotently at the park decision (local and shared), withdrawn atomically with a pop (Finding 5) and on every other terminal exit; the demand-growth `send_waiters` ring as its own lock-then-ring window; token carry across promotion; bounded receiver abandonment as the timers-scoped-out stand-in for the §6 timeout withdraw, single-mutex-section (Finding 6) |
| §7 lifecycle | waiter-list dedup (sets keyed by thread); teardown releasing all of a heap's stubs |
| cooperative scheduling | `cur[t]`: fibers of one thread serialize; primitives have no fiber switch points; the scheduler (sweep/poll) runs only when no fiber is mid-primitive |

**Atomicity discipline:** every mutex-held region of the §4/§6
pseudocode is a single atomic action (sound — the mutex serializes
them); every lock-free window is its own step, because that is where
protocol bugs live: the registered-but-not-yet-parked window, the
build, each flag-then-fd ring, the `wake_pending` swap, the poll, each
refcount transition.

**Protocol variants (CONSTANTS).** The amended KEP-0002 text corresponds
to `SweepPolicy = "flip_all"`, `EofPolicy = "wait_reserved"`,
`RvRing = "ring"`, `RvPopWithdraw = "at_pop"`, and `RvAbandon = "atomic"`
where abandonment is exercised (plus the `RecvFail` re-queue rule). The
rejected designs are kept selectable:
`"selective"` (the original §5 readiness-filtered sweep — Finding 1),
`"asis"` (the original EOF-when-closed rule — Finding 2),
`"wait_reserved_naive"` (the incomplete Finding-2 repair — Finding 3),
`RvRing = "noring"` (demand growth without the `send_waiters` ring —
Finding 4), `RvPopWithdraw = "at_deinit"` (the token counted through the
pop's copy-out window — Finding 5), and `RvAbandon = "naive"` (the
timeout withdraw racing an in-flight reservation — Finding 6).

**Scoped out** (would not change the checked properties at these
bounds): notifier refcounts and the `alive` flag (no thread exits
mid-model — §7's teardown pruning is untested here); §6 timeouts —
including the rendezvous delivery-wins and reservation-drain rules,
which are receiver-local decisions under the already-modeled lock
discipline and add no new lock-free window;
local-channel capacity pre-promotion (the rv scenario *does* model the
local rendezvous park and its token-carrying migration); the §5
deadlock heuristic (that
is P4); equality (UQ 4). Promotion's *internal* re-entrancy (early
publication, §2 step 2) is modeled by its specified outcome, not
rediscovered. Weak-memory effects are not modeled (TLA+ steps are
sequentially consistent); the §5 acq_rel argument is encoded in the
action structure, and GenMC remains P2's escalation path.

## The six pre-registered properties

| P2 property | Where |
|---|---|
| 1. refcount ≥ 0 | `RcAccounting` — strengthened to exact accounting: `rc = Σ held + self-stubs in queue + self-stubs in flight` |
| 2. destroy exactly once | `DestroyedClean` + destroy guarded in `Teardown` (reachable only once since `rc` stays 0) |
| 3. envelope always enqueued or deinit'd, never both | `EnvelopeAccounting`: `built = in-hand + queued + received + destroy-deinit + fail-deinit` (a re-queued envelope moves hand→queue, staying balanced) |
| 4. no admitted send lost across close | `ReservedAccounting` + push never guarded on `closed` + the `strand` scenario's `NoAbandonedTask` |
| 5. drain-then-EOF | structural in `RecvEOF` (queue-empty and `reserved == 0` guards precede EOF) — TLC exercises close-vs-push interleavings against it |
| 6. no lost wakeup (liveness) | `Termination` (`<>[](AllDone ∧ AllTorn)`) under weak fairness, plus TLC deadlock checking — a stranded parked fiber is a deadlock because scripts always close the stream |

Three scenario scripts: **core** (promotion drain + migration, optional
pre-promotion local self-send so both the drain-alias and empty-queue
migration paths are reachable, competing receivers on two threads, a
remote self-send, both failure modes, close at the end), **strand**
(the §8 pool-shutdown shape: one sender racing an independent closer,
two receive-until-EOF workers), **rv** (rendezvous, `Cap = 0`: two
senders on two threads against two single-receive receivers — budgets
matched so `NoAbandonedTask` must hold — with f0b's receive able to
park locally *before* promotion, exercising the token-carrying §2
step 4 migration; close at the end), **rv2** (Finding 5's geometry: two
plain sends against a single receive and no other receiver, so a send
admitted through the pop window has nobody left to collect it), and
**rva** (Finding 6's geometry: one plain send against a single receiver
that may abandon its wait once — the timers-scoped-out stand-in for the
§6 timeout withdraw). rv2/rva use plain sends deliberately: a stranded
*self* envelope would pin the refcount above zero and surface as the
documented §1 cycle leak instead of a destroy-at-zero deinit, making
`NoAbandonedTask` hold vacuously.

## Results (TLC 2.19, macOS aarch64, 2026-07-12)

| Config | Variant | Checks | Expected | States (distinct) |
|---|---|---|---|---|
| `core_cap1_flipall` | pre-amendment EOF, fixed sweep | safety + liveness | **pass** ✓ | 872,585 |
| `core_cap4_flipall` | pre-amendment EOF, fixed sweep | safety | **pass** ✓ | 167,033 |
| `core_cap4_selective` | **§5 sweep as originally written** | safety | **fail** — Finding 1 | ~50k* |
| `strand_flipall` | **§4/§6 EOF as originally written** | safety | **fail** — Finding 2 | ~5k* |
| `strand_waitres` | amended | safety + liveness | **pass** ✓ | 17,703 |
| `core_cap4_waitres_naive` | **incomplete Finding-2 repair** | safety | **fail** — Finding 3 | ~40k* |
| `core_cap4_waitres` | amended, both failure modes | safety | **pass** ✓ | 1,607,571 |
| `core_cap1_recvfail` | amended, receive failures, capacity 1 | safety + liveness | **pass** ✓ | 5,260,378 |
| `core_cap1_waitres` | amended, send failures, capacity 1 | safety + liveness | **pass** ✓ | 945,608 |
| `rv_flipall`† | rendezvous, send failures | safety + liveness | **pass** ✓ | 1,071,005 |
| `rv_recvfail`† | rendezvous, receive failures | safety + liveness | **pass** ✓ | 1,962,624 |
| `rv_noring`† | **demand growth without the sender ring** | safety + liveness | **fail** — Finding 4 | ~0.4k* |
| `rv2_popwithdraw`‡ | rendezvous, withdraw-at-pop | safety + liveness | **pass** ✓ | 5,004 |
| `rv2_popwindow`‡ | **token counted through the pop window** | safety + liveness | **fail** — Finding 5 | ~5k* |
| `rva_atomic`‡ | rendezvous, atomic timeout-withdraw | safety + liveness | **pass** ✓ | 3,691 |
| `rva_naive`‡ | **withdraw racing an in-flight reservation** | safety + liveness | **fail** — Finding 6 | ~3k* |

\* states explored before the violation stopped the search; varies
across runs (parallel BFS).

† added by the 2026-07-16 rendezvous amendment
([kaappi#1601](https://github.com/kaappi/kaappi/issues/1601)); run with
TLC 2.19. The nine original configs were re-run at the same time and
reproduce the recorded outcomes — the pass configs' distinct-state
counts are unchanged by the extension (for `Cap > 0` the added
variables are constant), which is itself a check that the rendezvous
changes are conservative.

‡ added by the Findings 5–6 amendment
([kaappi#1604](https://github.com/kaappi/kaappi/pull/1604) review
follow-up, same day); the rv configs' counts reflect the normative
`at_pop` withdraw, which changes rendezvous demand trajectories, so
`rv_flipall`/`rv_recvfail` differ from their first-recorded values.

All passing configs satisfy every safety invariant, TLC's deadlock
check, and (where marked) the `Termination` liveness property.

---

## Finding 1 — lost wakeup: consumed registration + the readiness-filtered sweep

**Violated:** property 6 (no lost wakeup); made §6's "close wakes
everyone" false. **Witness:** `core_cap4_selective` (deadlock, 25-step
counterexample). **Repaired in §5:** the sweep flips every registry
fiber unconditionally.

Three normative pieces of the original text contradicted each other:
rings **snapshot-and-clear** the waiter list (§4/§6/§7a, "threads whose
fibers re-park simply re-register"); the sweep flipped only fibers
"whose channel is ready *for it*" (§5); and §4 promised "wake-all …
losers of the retry race re-park." A fiber rung but no longer ready —
because another receiver drained the queue first, exactly the loser §4
anticipates — was neither flipped (never retries, never re-registers)
nor still registered (the ring consumed its entry). Later pushes rang a
list its thread was not on; `channel-close!` rang nobody. Permanent
hang: an idle §8 pool worker sleeps through `pool-shutdown!` and
`thread-join!` never returns.

Trace sketch: f2 registers `t2`; f0a pushes (snapshot `{t2}`, clear,
ring); f0b pops the message first; f2 parks; `t2` sweeps — not ready,
not flipped; f0a closes — snapshot `∅`; f2 parked forever with
`closed = TRUE`.

The repair makes §4's wake-all literal; losers run, re-park, and
re-register. Alternatives (persistent registrations; sweep-side
re-registration) are recorded in §5 as rejected-for-v1 — they trade
spurious retries for channel-lock traffic inside the sweep.

## Finding 2 — an admitted send could be abandoned across close

**Violated:** §8's "tasks submitted before shutdown all run" (property
4's user-visible face). **Witness:** `strand_flipall`
(`NoAbandonedTask`, 17-step counterexample). **Repaired in §4 receive
step 6 / §6:** EOF requires `closed ∧ queue empty ∧ reserved == 0`;
registration is permitted when `closed ∧ reserved > 0`.

§4 makes reservation the point of no return, and the original text
promised the admitted message "is never lost" — but *enqueued* is not
*receivable*: f1 reserves; f0a closes (rings nobody — no one parked);
both until-EOF workers see empty+closed and take EOF; f1's push lands;
teardown destroys the message unreceived. The submitting `channel-send`
**returned successfully**, so the §8 pool would hang a `task-wait` with
no error anywhere. With the repair, a receiver arriving inside the copy
window parks and is rung by the late push; verified in
`strand_waitres` including liveness.

## Finding 3 — the naive Finding-2 repair strands receivers on copy failure

**Witness:** `core_cap4_waitres_naive` (deadlock, 22-step
counterexample). **Repaired in §4 step 9:** the failure path's
snapshot-and-clear also covers `recv_waiters` when the channel is
closed.

With only the EOF guard added, a receiver parked waiting out a
reservation (`closed ∧ reserved > 0`) was never woken when that
reservation died on the copy-failure path — the original failure path
rang only `send_waiters`, because pre-repair only senders could wait on
a reservation. The full repair passes `core_cap1_waitres` /
`core_cap4_waitres` with failures enabled, including liveness.

## The receive-side copy-failure rule (new §4 receive step 5)

The original text left receive-side `deepCopy` failure unspecified —
and as written it would have *lost* the popped message. The amended
rule, checked in `core_cap1_recvfail` / `core_cap4_waitres`: push the
envelope back at the queue head (FIFO preserved, stubs intact — the
envelope was never touched), snapshot-and-clear + ring `recv_waiters`
(receivers may have parked while the queue was momentarily empty), and
raise. "Receive fails ⇒ nothing received."

Two consequences the model surfaced, now stated in the KEP:

- **Transient capacity overshoot.** The pop's ring may already have
  admitted a sender into the freed slot before the re-queue restores
  the message, so a bounded queue can briefly exceed its capacity by
  the number of concurrently failing receives. Admission stays strict;
  the overshoot drains on the next receive. Exercised at capacity 1 in
  `core_cap1_recvfail`.
- **Persistent failure is not rescuable — by design.** The model bounds
  copy failures per receiver (`failLeft`); a receiver that fails
  *forever* is an effectively-dead consumer, and producers parked
  behind it hang exactly as KEP-0002's weakened deadlock detection
  documents (timeouts are the hatch). The re-queue rule guarantees no
  *message* loss and no *wakeup* loss, not progress against a consumer
  that can never complete a receive. (An early model draft let failures
  consume receive budgets and rediscovered this as a spurious
  "deadlock" — the fix was the model's workload, not the protocol.)

## Finding 4 — rendezvous demand that grows silently strands parked senders

**Violated:** property 6 (no lost wakeup), on a rendezvous channel.
**Witness:** `rv_noring` (deadlock, found in under a thousand states).
**Repaired in §4 receive step 7a:** a receiver registration that grows
`rvDemand` also snapshot-and-clears `send_waiters` under the lock and
rings after unlock — new demand is a send-side event, exactly like a
freed slot.

On a `Cap ≥ 1` channel the only events that can unblock a parked sender
are a pop and a close, and both already ring `send_waiters`. Capacity 0
adds a third: the admission bound itself *grows* when a receiver
commits. A demand increment that only registers the receiver's own
notifier (the natural transliteration of the existing park path) wakes
nobody: both senders can attempt their sends before any receiver
commits — the bound is 0, so both park — and the receivers' subsequent
registrations grow the bound silently. Every fiber is then parked with
all four wakeup sources (pop, close, push-ring, demand-ring) either
unreachable or missing, and TLC reports the all-parked deadlock
immediately.

The repair reuses the existing snapshot-under-lock / ring-after-unlock
discipline verbatim (`recv_demand_ring` in the model is the same
two-step flag-then-fd ring every other wake uses), and the retry race
it opens — a woken sender re-checks admission through `send()` under
the lock — is the same wake-all/retry pattern §4 already commits to.

## Finding 5 — a token counted through the pop window admits a strandable send

**Violated:** §6's "a completed send had a committed receiver"
(property 4's rendezvous face). **Witness:** `rv2_popwindow`
(`NoAbandonedTask`). **Repaired in §4 receive steps 2–4 / §6:** a pop
by a token-holding receiver withdraws its demand in the same mutex
section as the pop (`RvPopWithdraw = "at_pop"`).

Found by implementation review
([kaappi#1604](https://github.com/kaappi/kaappi/pull/1604)), not by the
first model run — the original rv scenario's send and receive budgets
are matched, so a handoff admitted against an already-satisfied
receiver was always collected by the *other* receiver and every
property held. With releases only at envelope deinit, the window
between the pop (which decrements `queue_len` and rings `send_waiters`)
and the deinit (after the unlocked copy-out) leaves the receiver's
token counted while the receiver already owns a value: a second sender
is admitted against it, pushes, and reports success; when no receiver
remains, the handoff is destroyed unreceived at teardown. rv2's
geometry (two sends, one receive, no second receiver) makes the strand
visible. On the copy-failure path the token stays withdrawn either way
— the raise is a terminal exit and the re-queued envelope falls under
§6's abnormal-exit rule.

## Finding 6 — a timeout withdraw racing a reservation strands an admitted send

**Violated:** same §6 guarantee, through the timeout path.
**Witness:** `rva_naive` (`NoAbandonedTask`). **Repaired in §6:** the
timeout withdraw's queue check, reservation check, and demand decrement
are one mutex section (`RvAbandon = "atomic"`); it is enabled only with
the queue empty (delivery-wins: a committed handoff outranks the timer)
and no reservation in flight (the drain rule: an admitted send must
land or abort first).

Timers stay scoped out; abandonment is modeled as a bounded spontaneous
decision whose *enabling condition is the amended protocol*, so TLC
checks the protocol content of the timeout rules without modeling time.
The naive variant — reservation check and withdrawal in separate mutex
sections, the natural transliteration of a `reservedCount()` peek
followed by `withdrawRvDemand()` — lets a sender reserve against the
still-held token after the receiver's zero observation: the receiver
withdraws and times out, the sender pushes into demand that no longer
exists and reports success, and the handoff is destroyed unreceived.

---

## Amendment record

Landed in KEP-0002 together with this suite (all four changes
model-checked first):

1. **§5** — unconditional sweep (Finding 1), with the rejected
   readiness filter and its failure mode documented inline.
2. **§4 receive step 6 / §6** — `reserved == 0` EOF guard; §8's
   shutdown claim now holds as stated (Finding 2).
3. **§4 step 9** — failure path rings `recv_waiters` on a closed
   channel (Finding 3).
4. **§4 receive step 5** — receive-side copy failure re-queues at the
   head and rings `recv_waiters`; capacity may transiently overshoot
   (previously unspecified).
5. **§4 send step 3 / receive step 7a, §6 "Rendezvous channels"**
   (2026-07-16, [kaappi#1601](https://github.com/kaappi/kaappi/issues/1601))
   — capacity 0 becomes demand-bounded rendezvous; the demand-growth
   `send_waiters` ring (Finding 4) is normative; demand tokens acquire
   idempotently per logical wait and release on every terminal exit.
6. **§4 receive steps 2–4 / §6** (2026-07-16,
   [kaappi#1604](https://github.com/kaappi/kaappi/pull/1604) review) — a
   token-holding pop withdraws its demand atomically with the pop
   (Finding 5).
7. **§6 timeout rules** (same) — the timeout withdraw is a single mutex
   section over the queue check, the reservation check, and the demand
   decrement (Finding 6); with it, delivery-wins and the
   reservation-drain rule are structural rather than advisory.

KEP-0002's Phase 1 now carries this suite as a merge gate, and Phases
3–4 list the findings' interleavings as required regression tests.

## Fidelity caveats

This model checks the *specified protocol*, not the future Zig
implementation — the Phase 3 PCT-style stress harness (P2 method
step 2) covers the code-vs-spec gap. Known coarsenings, each argued
sound in comments in the module: mutex regions are atomic actions; the
sweep is atomic per swap-loop iteration (justified by §5's acq_rel
happens-before argument); `PollWake` is enabled whenever the fd is
pending (a superset of real schedules — kqueue triggers and eventfd
counters stay armed until retrieved); local-channel wake modeling
covers only the one local waiter the scripts can produce; receive-side
copy failures strike before any partial stub is taken (send-side
`BuildFail` covers the partial-copy-release path, and real partial
copy-out garbage releases through the same `freeObject` route).
