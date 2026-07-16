# Phase 7 benchmark plan and the KEP-0003 acceptance gate (P5)

This is the pre-registered protocol for KEP-0002 Phase 7's performance
evaluation ([kaappi#1472](https://github.com/kaappi/kaappi/issues/1472))
and for the KEP-0003 acceptance-gate decision it feeds
([kaappi#1474](https://github.com/kaappi/kaappi/issues/1474)). It
operationalizes [P5 of `open-problems.md`](../open-problems.md): the
workload matrix, the statistics discipline, and the gate rule — written
**before any Phase 7 code or numbers exist**, so the numbers judge the
design instead of the other way around.

**Provenance and change control.** The classification thresholds (25%,
10%, ≥ 2 in-place workloads, 8 workers) were registered 2026-07-12 in
`open-problems.md` P5 and are carried over verbatim — this document
adds operational definitions, not new thresholds. Until Phase 7 data
collection starts, changes to this protocol are ordinary PRs to this
file (each noting what moved and why). Once data collection has
started, the thresholds and gate-relevant definitions are frozen; a
defect discovered mid-run voids the run, fixes the protocol, and starts
over. That is the cost of being able to trust the classification.

**Amendments (pre-freeze).** Ordinary PRs per the rule above — each made
*before* data collection started, from what the Phase 7 harness
([kaappi#1546](https://github.com/kaappi/kaappi/pull/1546)) surfaced
during bring-up, noting what moved and why. None touches a threshold:

- **2026-07-15 — FO-TREE nodes: records → 4-slot vectors.** A
  `define-record-type` instance cannot cross a Kaappi channel and stay
  usable: `deepCopy` mints a fresh record *type* per envelope, so a copied
  node no longer matches the top-level type its accessors close over
  (record-type identity is not interned the way symbols are). §1's FO-TREE
  node becomes a 4-slot vector `#(left right tag count)` — same tree shape
  and the same symbol-heavy `tag`, so the §1 symbol-table measurement is
  unchanged; only the node container moves from a record to a vector.
  Revisit if record-type identity is ever made to survive the copy.
- **2026-07-15 — lever D scope: bytevectors only, no source promotion.**
  §2's side-heap ships for **bytevectors** only; large *strings* are a
  deferred follow-up (no gate workload carries one). And D elides the
  zero-copy *receive* of a distinct payload but does not promote a plain
  *source* bytevector to shared on first send, so a fan-out of the same
  plain bytevector still snapshots per task envelope. That touches only
  FO-DIGEST (the one bytevector fan-out), which is compute-dominated, so
  the classification is unaffected. Flonum-vector (IP-MAP, IP-MATMUL,
  FO-SLICE) and tree (FO-TREE) payloads are byte-opaque and correctly
  untouched by D — that walk tax is exactly the pre-KEP-0003 reality being
  measured.
- **2026-07-15 — IP-MATMUL sizes capped at 64 KiB and 1 MiB.** The kernel
  is interpreted O(M³); at 8 MiB (M ≈ 724) and 64 MiB (M = 2048) the
  multiply count (~4·10⁸ and ~9·10⁹) makes the cell computationally
  infeasible at §4 iteration counts, and compute so dominates wall time
  that `share` collapses toward zero for reasons unrelated to copy — a
  contaminated cell, not a signal. IP-MATMUL therefore runs only 64 KiB
  and 1 MiB; IP-BAND and IP-MAP still run all four sizes, so every `IP-*`
  workload keeps a size ≥ 1 MiB (what Rule 1 requires) and the
  DRAM-bound copy-domination signal is carried by the two O(size)
  workloads that can actually reach it.

## 1. Workloads

Six workloads (three per shape) plus two controls. "Copy-semantics
encoding" is what Phase 7 actually runs — the KEP-0002 world where
every payload crosses by envelope; the gate asks how much of that
encoding's time is copy machinery.

### In-place-shaped (the gate counts these)

| Id | Payload | Computation | Copy-semantics encoding |
|----|---------|-------------|------------------------|
| `IP-BAND` | RGBA byte image, `bytevector` of 4·W·H bytes | each worker renders a disjoint horizontal band (per-pixel arithmetic, no neighbor reads) | task carries band spec; worker returns its band as a fresh bytevector; parent `bytevector-copy!`s each into the output |
| `IP-MAP` | vector of flonums (NaN-boxed — Kaappi has no flat f64 storage pre-KEP-0003; that walk tax is part of what is being measured) | `out[i] = a·x[i] + b` over a disjoint chunk | task carries the chunk (copied in); worker returns the transformed chunk; parent `vector-copy!`s into place |
| `IP-MATMUL` | two f64 square matrices (vectors of flonums, row-major); *64 KiB and 1 MiB sizes only, see Amendments* | blocked matrix multiply: each worker computes a disjoint block of C, reading all of A and B | tasks carry A and B (fan-in copy) plus block spec; worker returns its C block; parent assembles |

### Read-only fan-out

| Id | Payload | Computation | Copy-semantics encoding |
|----|---------|-------------|------------------------|
| `FO-DIGEST` | `bytevector` | each worker computes an 8-byte checksum of the whole payload | payload copied to every worker; result is a fixnum pair |
| `FO-TREE` | balanced binary tree of nodes, each node a 4-slot vector `#(left right tag count)` with `tag` a symbol — symbol-heavy on purpose (measures the §1 shared-symbol-table lock alongside); *amended from records, see Amendments* | each worker counts nodes matching a tag over the whole tree | tree copied to every worker; result is a fixnum |
| `FO-SLICE` | vector of flonums | each worker sums only its assigned index range — but receives the **whole** vector (the over-copying idiom `parallel-map` naturally produces) | whole payload copied per worker; result is a flonum |

### Controls

| Id | Purpose |
|----|---------|
| `C-EMPTY` | empty-task pool round trip: control-plane floor (submit → worker no-op → reply) |
| `C-SERIAL` | single-thread, no-pool implementation of each kernel: the serial baseline `S` for speedup curves and sanity |

Payload sizing note: "size" always means the envelope-side payload
bytes of the *dominant* payload (the image, the vector, the tree, the
matrices combined), not the result.

## 2. Matrix and gate cells

Axes:

- **Size:** 64 KiB, 1 MiB, 8 MiB, 64 MiB (log-spaced; spans
  L2-resident to DRAM-bound on both reference machines). IP-MATMUL is
  the sole exception — 64 KiB and 1 MiB only (see Amendments).
- **Workers `w`:** 1, 2, 4, 8, 2×cores.
- **Elision levers** (from [P3](../open-problems.md), which Phase 7's
  A/B/C/D harness implements): `none` (per-message envelopes as
  specified), `C` (immediates — fixnums/booleans/chars — skip the
  envelope heap), `C+D` (plus the refcounted immutable side-heap for
  large **bytevectors**, implemented **behind a flag** — its shipping
  decision belongs to this gate, not to P3's benchmark; strings deferred,
  no plain-source promotion, see Amendments).

**Gate cells** (full statistics discipline, §4): the three `IP-*`
workloads × all four sizes × `w = 8` × levers `C+D`; plus the same
cells at levers `none` (to report how much the levers themselves
recovered). **Supporting cells** (full discipline): `FO-*` × all sizes
× `w = 8` × levers `{none, C+D}` — these decide Erlang-shapedness.
All other cells (worker sweeps for scaling curves, lever `C` alone)
run at reduced repetition and are exploratory: they inform
interpretation, never classification.

Dependency this registers: **the gate cannot be evaluated until lever
D exists behind its flag.** If Phase 7 reaches its other goals first,
the gate waits.

## 3. Metrics and operational definitions

- **`E`** — end-to-end wall time, parent side: from first
  `pool-submit` to the assembled result being fully materialized in
  the parent heap (all reassembly copies done). Measured with
  `current-jiffy` around the whole parallel section.
- **`S`** — `C-SERIAL` time for the same kernel and size.
- **Speedup** — `S / E` (reported for scaling curves; not gating).
- **Copy+reassembly overhead share** — the gate's quantity, measured
  by runtime instrumentation (Phase 7 adds counters; they are compiled
  out in release builds):

  ```
  share = (T_submit_copy + T_result_copy + T_reassembly) / E
  ```

  - `T_submit_copy`: parent-side time building task envelopes
    (`deepCopy` in). These serialize on the submitting thread, so they
    sit fully on the critical path.
  - `T_result_copy`: parent-side time copying results out of reply
    envelopes (`deepCopy` out on the parent).
  - `T_reassembly`: parent-side time in the harness's explicit
    assembly copies (`bytevector-copy!` / `vector-copy!` into the
    output object).

  Worker-side copy time is deliberately **not** counted — it overlaps
  with other workers and with the parent. This makes `share` a
  *conservative under-count* of what sharing could recover, i.e. the
  measurement error biases **against** KEP-0003 (toward Erlang-shaped
  or stays-gated). Registered as acceptable: the gate should err
  toward the smaller mechanism.

- **Secondary, non-gating:** peak RSS and peak live envelope bytes
  (the invisible-to-GC footprint from KEP-0002's Drawbacks); scheduler
  stall time during large submits (the head-of-line drawback);
  symbol-table lock wait during `FO-TREE` (feeds KEP-0002 §1's
  contention question); notifier ring counts.

## 4. Statistics protocol

Per Georges et al. (OOPSLA 2007), Kalibera & Jones (ISMM 2013), and
Mytkowicz et al. (ASPLOS 2009):

1. **Two levels:** invocations (fresh `kaappi` process) × iterations
   (in-process repetitions after warm-up). Pilot run: 5 invocations ×
   20 iterations per gate cell to estimate variance at each level;
   Kalibera–Jones then sets the counts for a 95% confidence interval
   within ±2% of the mean, with floors of **20 invocations** and
   **10 iterations** regardless. Exploratory cells: 5 × 10 flat.
2. **Report** mean and 95% CI (bootstrap over invocation means). Never
   best-of-N; never discard "outliers" (a slow invocation is data).
3. **Randomization:** workload/cell execution order shuffled per
   invocation; a dummy environment variable of random length
   (0–4096 bytes) exported per invocation (the Mytkowicz
   environment-size effect); ASLR left on.
4. **One binary:** all levers and modes selected by runtime flag, not
   rebuild, so link order and code layout are held constant across
   compared cells. Where a lever genuinely requires a rebuild, that is
   a protocol defect to fix before running (make it a flag).
5. **Build & environment:** ReleaseSafe (the shipped default);
   machines idle, power-adapter/performance profile, cores and SMT
   documented. Kernel/OS versions, `kaappi` commit, and this
   protocol's commit hash recorded in the results file.
6. **Two reference machines**, both required: macOS aarch64 (Apple
   Silicon dev box — heterogeneous P/E cores, noted) and Linux x86_64
   (homogeneous cores). `w = 8` requires ≥ 8 physical cores on each.

## 5. The gate rule, operationalized

Thresholds verbatim from the 2026-07-12 registration; terms bound to
§1–§4 definitions. Evaluate per machine, on the gate cells, using
`share` at `w = 8`:

1. **Racket-shaped — KEP-0003 proceeds** iff, with levers `C+D` on, at
   least **2 of the 3 `IP-*` workloads** have `share ≥ 25%` at any
   size ≥ 1 MiB (CI lower bound above the threshold — i.e., the ≥ is
   statistically resolved, not a point-estimate graze).
2. **Erlang-shaped — KEP-0003 rejected in favor of Alternative 1**
   (refcounted immutable payloads become a KEP-0002 UQ 1 follow-up)
   iff, with levers `C+D` on, **every** gate and supporting cell
   (`IP-*` and `FO-*`, all sizes, `w = 8`) has `share < 10%` (CI upper
   bound below threshold).
3. **Absent** — if even at levers `none` no `IP-*` or `FO-*` cell
   reaches `share ≥ 10%`, copying isn't the bottleneck at all: reject
   both KEP-0003 and the Alternative-1 work, revisit only with field
   evidence (this is KEP-0003's "absent" outcome).
4. **Between** — anything else: KEP-0003 stays gated; the revisit
   trigger is real application traces from `kaappi-examples` exhibiting
   an `IP-*`-shaped hot loop.

**Cross-machine rule:** the classification must agree on both
reference machines. Disagreement ⇒ outcome 4 (stays gated), with both
datasets published — a demand shape that exists on only one
microarchitecture is not enough to carve out the GC model.

**What each outcome triggers:** (1) ⇒ KEP-0003 status → Accepted,
[kaappi#1475](https://github.com/kaappi/kaappi/issues/1475) split into
real phase issues; (2) ⇒ KEP-0003 → Rejected with the data linked,
Alternative-1 issue opened under KEP-0002 UQ 1; (3) ⇒ both closed
with the data linked; (4) ⇒ gate issue stays open with the trigger
documented. In every case the numbers and the mechanical worksheet
(§6) are attached to kaappi#1474 before the status PR.

## 6. Deliverables

Phase 7 files results as CSV + a rendered table per machine:

```
machine, workload, size_bytes, workers, levers, invocations, iterations,
E_mean_ms, E_ci95_lo, E_ci95_hi, share_mean, share_ci95_lo, share_ci95_hi,
S_ms, speedup, rss_peak_mib, envelope_peak_mib
```

plus a classification worksheet that applies §5 mechanically — each
rule's cells, the CI bound used, and the resulting outcome — so the
gate decision in kaappi#1474 is a *reading*, not an argument.

## 7. Relation to the other research items

- The **P3 A/B/C/D envelope decision** (arena vs. per-message GC
  struct) uses the same harness and statistics discipline but its own
  pre-registered criteria in `open-problems.md` P3; it is decided
  independently of the gate, except that lever D's *shipping* decision
  belongs here.
- `FO-TREE` doubles as KEP-0002 §1's symbol-table contention
  measurement.
- The tail-latency and notifier-coalescing measurements of
  kaappi#1472 are outside this protocol (no classification hangs on
  them); they follow §4's discipline informally.

## 8. Outcome (recorded after evaluation — not a protocol change)

**2026-07-16 — the gate read outcome 4, Between, on both reference
machines independently**
([kaappi#1474](https://github.com/kaappi/kaappi/issues/1474)) — genuine
agreement, not the §5 cross-machine fallback. Only `IP-MAP` cleared
Rule 1's 25% CI-lower bound (26.0% [25.7, 26.3] at 64 MiB on macOS; at
8 MiB and 64 MiB on Linux) where 2 of 3 `IP-*` are required; Rules 2
and 3 failed on `IP-MAP`, `FO-TREE`, and `FO-SLICE`, all far above the
10% upper bound at both lever settings. KEP-0003 stays gated with the
§5 outcome-4 revisit trigger.

Datasets: [kaappi#1549](https://github.com/kaappi/kaappi/pull/1549)
(macOS aarch64, kaappi commit `b6d349c0`, K–J floor 20×10, `w = 8`,
both levers, 920 launches, 0 failures) and
[kaappi#1580](https://github.com/kaappi/kaappi/pull/1580) (Linux
x86_64, dedicated 8-physical-core droplet, kaappi commit `807fd64a`,
~1000 launches, 0 failures). One per-machine exclusion, mirroring the
IP-MATMUL amendment's reasoning: Linux's 64 MiB `FO-DIGEST` cell was
dropped for runtime (~74–82 s/iteration; documented in the dataset
metadata) — compute-dominated, under 2% share at every collected size
on both machines, classification-neutral. The filled §6 worksheet is
`docs/dev/kep-0003-acceptance-gate-worksheet.md` in the kaappi repo.

The same dataset settles the one decision §7 assigns to the gate:
**lever D does not ship.** Both machines read `cd` ≈ `none` on every
cell — the payloads where copy dominates (flonum vectors, the FO-TREE
vector tree) are byte-opaque to a bytevector side-heap (the
pre-KEP-0003 walk tax), and the two bytevector workloads leave D
nothing end-to-end (FO-DIGEST compute-dominated, IP-BAND
reassembly-bound). The side-heap stays behind `-Dchannel-instrument`
as gate lever `d` — any re-run of this protocol needs both lever
settings — rather than becoming a shipped default. Full statement and
revisit condition: KEP-0002 UQ 1 (D).

This section records a result; §§1–7 stay as frozen. One deviation
from §5's outcome-4 action (gate issue stays open): the maintainer
deliberately closed kaappi#1474 along with the epic kaappi#1465 and
the gated kaappi#1475, recording the call in their closing comments;
the revisit trigger survives in the worksheet, and firing it opens
fresh issues rather than reopening those.
