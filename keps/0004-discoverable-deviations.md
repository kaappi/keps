# KEP-0004: Discoverable Deviations from R7RS-small

| Field | Value |
|-------|-------|
| **KEP** | 0004 |
| **Title** | Discoverable Deviations from R7RS-small |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Accepted |
| **Type** | Standards |
| **Target** | `kaappi` core (compiler, VM library loader), `kaappi.github.io` (new conformance page) |
| **Created** | 2026-07-13 |
| **Requires** | KEP-0001 (Final) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit
[`55ccff0b`](https://github.com/kaappi/kaappi/commit/55ccff0b) (main, 2026-07-13,
post KEP-0002 Phase 2) and were verified against that source, including by
building `zig-out/bin/kaappi` at that commit and running the repro snippets in
the Motivation directly. Doc-site references are pinned against the
`kaappi.github.io` `main` branch as of the same date.*

## Summary

Kaappi's core language is essentially complete R7RS-small — but the KEP
process itself (this repository) exists precisely to add things R7RS-small
has no opinion on: fibers and an I/O reactor (KEP-0001, shipped), cross-thread
channels (KEP-0002, partially shipped), and eventually shared mutable buffers
(KEP-0003, drafted). None of this is currently **discoverable** by a Scheme
program or a Scheme programmer without reading Zig source or this KEP
repository. This proposal adds two independent, complementary surfaces for
exactly that:

1. **A code-level surface** — `cond-expand` (SRFI 0) feature identifiers for
   the KEP subsystems, so portable library code can branch on what a given
   build actually has, the same way every implementation surveyed in
   [research/](../research/) already lets a program test `(chicken)`,
   `(gauche)`, or `(gambit)`.
2. **A docs-level surface** — a new page on kaappi-lang.org that states, in
   one place a human reads instead of greps, exactly where Kaappi's core
   language has known gaps against R7RS-small and exactly where it
   deliberately extends past R7RS-small's scope — modeled on the
   conventions other Schemes already use for this (Prior art, below).

## Motivation

### The gap this closes

[CONFORMANCE.md](https://github.com/kaappi/kaappi/blob/55ccff0b/CONFORMANCE.md)
and the README's ["Known limitations"](https://github.com/kaappi/kaappi/blob/55ccff0b/README.md#L338)
section already do real work here — they are, in substance, Kaappi's
equivalent of Guile's *R7RS Incompatibilities* page or Gauche's *Standard
conformance* chapter. But they live in the `kaappi` core repo's root, not on
kaappi-lang.org where a user evaluating or already writing Kaappi code
actually looks, and — because CONFORMANCE.md predates KEP-0001 — neither
document says anything about fibers, the reactor, or cross-thread channels at
all. A user reading kaappi-lang.org today has no single page telling them
"the core language is R7RS-small-complete; the concurrency layer is a
deliberate, documented extension beyond it, currently at this state." That
framing — *gap against the spec* vs. *deliberate extension beyond the spec's
scope* — is exactly the distinction [docs/dev/vision.md](https://github.com/kaappi/kaappi/blob/55ccff0b/docs/dev/vision.md#L26)
draws internally ("R7RS-small is the contract" for the core language,
"Pragmatism over purity" for everything built on top), but it has no
external-facing statement.

### The code-level gap, verified

`types.platform_features`
([`types.zig:1262`](https://github.com/kaappi/kaappi/blob/55ccff0b/src/types.zig#L1262))
is a flat six-entry array: `r7rs`, `kaappi`, `ieee-float`, `posix`,
`exact-closed`, `exact-complex`. There is no bare symbol for fibers, the
reactor, or threads. Confirmed by running the built binary at this commit:

```scheme
(cond-expand (kaappi-fibers "yes") (else "no"))   ; => "no" — no such feature exists today
(cond-expand (posix "yes") (else "no"))            ; => "yes" — confirms the array is what's checked
```

The `(library (kaappi fibers))` requirement form *does* already work
correctly — a fact worth stating plainly because an earlier draft of this KEP
assumed otherwise and was wrong. `evalFeatureReq`'s hardcoded `known_libs`
array
([`compiler_conditionals.zig:315`](https://github.com/kaappi/kaappi/blob/55ccff0b/src/compiler_conditionals.zig#L315))
omits every `kaappi.*` library and `srfi.18`/`srfi.170`, but falls through to
`globals.libraryExists`
([`globals.zig:104`](https://github.com/kaappi/kaappi/blob/55ccff0b/src/globals.zig#L104)),
a VM-registered callback that checks the live library registry — so
`(cond-expand ((library (kaappi fibers)) ...))` and
`(cond-expand ((library (srfi 18)) ...))` both resolve correctly today, at
top level and nested, verified directly:

```scheme
(cond-expand ((library (kaappi fibers)) "yes") (else "no"))  ; => "yes", correct
(cond-expand ((library (srfi 18)) "yes") (else "no"))        ; => "yes", correct
```

`known_libs` is therefore dead weight (a fast-path the callback already
subsumes), not a source of wrong answers — worth a cleanup, not a fix. It's
also correctly WASM-gated one level down: `Lib.wasmAvailable()`
([`primitives.zig:108`](https://github.com/kaappi/kaappi/blob/55ccff0b/src/primitives.zig#L108))
marks `srfi_18` unavailable on `wasi` and `kaappi_fibers` available, matching
KEP-0002 §5's claim that no SRFI-18 threads exist on WASI while fibers do.

**What library-existence checks structurally cannot express** is the actual
gap: KEP-0002 changes the *behavior* of the already-existing `(kaappi
fibers)` channel primitives (`channel-send`/`channel-receive` gain safe
cross-thread promotion) without introducing a new library name.
`(library (kaappi fibers))` returns `#t` today, before promotion is even
implemented, and will continue to return `#t` once it lands — it cannot
distinguish "channels exist" from "channels are safe across an OS thread
boundary." R7RS's SRFI-0 offers exactly two requirement shapes for a reason:
`(library ...)` answers "does this named collection of bindings exist," and a
bare symbol answers "does this capability exist" — a question a library name
alone cannot express when the capability is a behavior change to existing
bindings. This is the one gap in Motivation that is irreducible, not merely
inconvenient.

Two further variances are real but **not expressible by cond-expand at
all**, and this KEP should say so rather than pretend otherwise: whether a
given WASI host's reactor actually multiplexes I/O or silently degrades to
blocking (`fd_fdstat_set_flags(NONBLOCK)` failing is a *runtime*
host-capability probe, per KEP-0001 §"Cross-platform"), and whether
`--sandbox` blocks SRFI-18 thread creation (a *runtime* CLI flag). `cond-
expand` is an expand-time construct; both of these are per-run facts. Filed
under Unresolved questions, not solved here.

## Guide-level explanation

**cond-expand.** A library author writing against `(kaappi fibers)` gets a
short, memorable way to test for cross-thread channel safety once it ships,
instead of inventing an ad-hoc runtime probe:

```scheme
(import (scheme base) (kaappi fibers))

(cond-expand
  (kaappi-shared-channels
    ;; safe to hand a channel to thread-start! and use it from both sides
    (define (make-worker-channel) (make-channel)))
  (else
    (error "this build's channels are fiber-local only")))
```

And a library that wants to degrade gracefully rather than fail to import at
all on an older or minimal build:

```scheme
(cond-expand
  ((library (kaappi fibers)) (import (kaappi fibers)))
  (else (define (spawn thunk) (thunk))))  ; synchronous fallback
```

**The docs page.** A user lands on kaappi-lang.org, follows a "Standards
Conformance" link from the About section (next to Stability), and reads,
top to bottom:

- *Core language*: R7RS-small, complete — every Appendix A identifier, 1,391
  conformance tests passing, link to CONFORMANCE.md for the SRFI-by-SRFI
  detail.
- *Known gaps*: the handful of things README already lists (`syntax-case`
  absent by the spec's own design, `call/cc` REPL-boundary behavior shared
  with every mainstream Scheme, the native-driver fiber-parking limitation)
  — reframed for a reader who has never read the Zig source.
- *Deliberate extensions beyond R7RS-small's scope*: fibers + reactor
  (Final, shipped, link to the Concurrency guide), cross-thread channels
  (status taken live from the KEPs index — Accepted, partially shipped, not
  yet safe for the promotion path), shared buffers (Draft, unimplemented) —
  each with its `cond-expand` feature identifier if one exists yet, so the
  code-level and docs-level surfaces point at each other.

## Reference-level design

### 1. New feature identifiers

Extend the identifier set checked by `evalFeatureReq` /
`evalLibFeatureReq` (unify these — see §2) with bare symbols scoped to what's
compile-time-decidable:

| Identifier | True when | Ships |
|---|---|---|
| `kaappi-fibers` | `(kaappi fibers)` compiled in — true on every target today, including WASI (KEP-0001 Phase 4) | Phase 1 |
| `kaappi-reactor` | An OS-multiplexing reactor backend (kqueue/epoll/`poll_oneoff`) is compiled in, as opposed to no reactor at all | Phase 1 |
| `kaappi-threads` | SRFI-18 OS threads compiled in — `!is_wasm`, matching `Lib.wasmAvailable()`'s existing `srfi_18 => false` on `wasi` | Phase 1 |
| `kaappi-shared-channels` | Cross-thread channel promotion (KEP-0002) is implemented *and* the cross-thread wakeup path is merged | Phase 2, gated |
| `kaappi-shared-buffers` | `shared-bytevector`/`shared-f64vector` (KEP-0003) exist | Phase 3, gated |

`kaappi-fibers` and `kaappi-threads` are true almost everywhere today and so
are individually low-value versus the existing `(library ...)` checks — they
earn their keep mainly by being short, by matching the naming convention the
gated identifiers below need anyway, and by being decidable purely from
`builtin.os.tag` (no VM callback required), which keeps them usable from
contexts `(library ...)` cannot reach (see §2).

`kaappi-shared-channels` **does not ship in Phase 1**. The KEP-0002 Phase 3
commit message (`d969ad98`, currently on branch `fix/1468`, not on `main`)
records that Phases 1–2 alone left cross-thread wakeup "an unwired `@panic`"
reachable by an ordinary program (a channel closed over by a `thread-start!`
thunk, received-from before the other side sends) — SIGABRT, not a clean
error. Advertising a feature identifier for a capability that can crash the
process is worse than advertising nothing; this identifier is added only
once KEP-0002's cross-thread wakeup is on `main` and its own review findings
are resolved.

### 2. Unify the two feature evaluators (cleanup, not a fix) — **implemented, revised from the original design**

The original draft of this section proposed routing the compiler's
`evalFeatureReq` through the `vm.vm_instance` threadlocal directly, "the same
mechanism the GC root marker already relies on." That claim didn't survive
contact with the import graph: `vm.zig` imports `compiler.zig` (line 4), and
`compiler.zig` reaches `compiler_conditionals.zig` via the `compiler_forms.zig`
re-export hub — so `compiler_conditionals.zig` importing `vm.zig` directly
would close a real cycle
(`compiler_conditionals.zig → vm.zig → compiler.zig → compiler_forms.zig →
compiler_conditionals.zig`). `globals.zig`'s own doc comment already said as
much ("used by the compiler/expander for thread-safe globals access without
importing vm.zig") — the callback indirection isn't incidental, it's the
established way this codebase's compiler layer stays decoupled from `vm.zig`
without fighting Zig's import resolution.

What actually shipped instead: the two evaluators' `(library ...)` arms were
never really doing different lookups — `vm.zig`'s `checkLibraryExists`
(registered as the `globals.library_exists_checker` callback) and
`vm_library.zig`'s `evalLibFeatureReq` both independently hand-wrote
`vm.libraries.get(lib_name) != null` then a fallback to `libraryFileExists`.
That two-line check is now one function,
`vm_library.libraryIsAvailable(vm, lib_name, lib_name_list)`, called by both
`checkLibraryExists` (compiler side, via the existing callback) and
`evalLibFeatureReq` (define-library side, direct `*VM` access, no cycle
there). `evalFeatureReq`'s `known_libs` array — verified empirically against
a built binary to already be fully redundant, since `(cond-expand ((library
(kaappi fibers)) ...))` and `(cond-expand ((library (srfi 18)) ...))` both
resolved correctly *before* this change too, via the callback fallback the
array never reached — is deleted outright rather than reconciled. Net effect:
one implementation of "does this library exist" instead of two, reached
through the two entry points the layering actually requires, with no new
import edges. Regression tests lock in that `(kaappi fibers)` and `(srfi 18)`
resolve correctly without the array (`tests_advanced.zig`).

### 3. The kaappi-lang.org page

New page `docs/conformance.md`, nav entry `Standards Conformance:
conformance.md` under the existing `About:` section
([`mkdocs.yml:136`](https://github.com/kaappi/kaappi.github.io/blob/main/mkdocs.yml#L136)),
next to `Stability: stability.md` — the two pages answer adjacent questions
("what does version X guarantee" vs. "how closely does this track the
spec") and belong side by side. Content sourced from, and kept in sync
with, CONFORMANCE.md and README's "Known limitations" (single source of
truth stays in the core repo per
[CLAUDE.md's "Docs location"](https://github.com/kaappi/kaappi.github.io/blob/main/CLAUDE.md);
the doc page is a curated, narrative front end for a first-time reader, not
a fork of the data). The KEP-status table pulls its Accepted/Draft/Final
wording directly from this repo's `README.md` index so it can't silently
drift out of date the way CONFORMANCE.md drifted before KEP-0001 shipped.

## Drawbacks

- A second place (`conformance.md`) that must be kept in sync with
  CONFORMANCE.md, README, and this KEPs repo's own status table — three
  sources of truth for one narrative, with the attendant risk one updates
  and the others don't. Mitigated, not eliminated, by making the page
  explicitly link to (rather than restate in full) CONFORMANCE.md's
  per-SRFI table.
- Feature identifiers for subsystems that don't exist yet, or aren't safe
  yet, are a standing temptation to ship early; the KEP-0002 SIGABRT case in
  Motivation is the concrete reason this proposal gates `kaappi-shared-
  channels` behind the underlying KEP's own safety bar rather than its
  Draft/Accepted status.
- `kaappi-fibers`/`kaappi-reactor`/`kaappi-threads` are true on nearly every
  build that exists today, so on their own they don't yet let a library do
  anything `(library ...)` checks couldn't already do — their value is
  mostly in establishing the naming convention and evaluator unification the
  gated identifiers need later, which is a real but deferred payoff.

## Alternatives considered

- **Fold OS/architecture identifiers (`unix`, `windows`, `aarch64`, ...)
  into this KEP.** Deferred: `platform_features` has zero OS/arch entries
  today, which is a real, separate gap, but it's orthogonal to the
  concurrency-subsystem question this KEP was asked to address — a future
  KEP.
- **Docs-only, no feature identifiers.** Rejected: a human-readable page
  doesn't help a library author write one codebase that runs correctly
  against both a pre- and post-KEP-0002 Kaappi; every implementation
  surveyed in Prior art pairs its deviations documentation with a
  machine-checkable mechanism, not one or the other.
- **Feature identifiers only, no docs page.** Rejected: `cond-expand` is
  invisible to someone evaluating whether to adopt Kaappi in the first
  place — they are not yet writing code to `import` anything. Guile,
  Gauche, and CHICKEN all maintain a prose page precisely because a
  feature-identifier table only serves people already past that decision.
- **A single coarse `kaappi-concurrency` flag.** Rejected: collapses
  meaningfully different capabilities (fibers without cross-thread
  channels will be the norm for a while yet) into one flag, forcing authors
  back to `(library ...)` probing anyway.

## Cross-platform / compatibility impact

- WASI: `kaappi-fibers` and `kaappi-reactor` both true (`poll_oneoff`
  backend ships in KEP-0001 Phase 4); `kaappi-threads` false, matching
  `Lib.wasmAvailable()`'s existing `srfi_18 => false`.
- Sandbox mode: no compile-time distinction exists for it (it's a CLI flag,
  not a build), so `kaappi-threads` stays true in a sandboxed run even
  though `--sandbox` blocks thread creation at runtime — documented as an
  explicit limitation of `cond-expand` itself, not something a new
  identifier can paper over (Unresolved question 3).
- Backward compatible: purely additive identifiers and a new doc page;
  existing `(library ...)` behavior is unchanged, only its implementation is
  deduplicated.

## Prior art

Directly reuses the comparative research already done for this codebase
(session research, 2026-07-13, citing each implementation's official docs):

| System | Code-level mechanism | Docs-level mechanism |
|---|---|---|
| **CHICKEN** | `cond-expand` with `chicken`, `chicken-5`, `srfi-N` features | ["Deviations from the standard"](https://wiki.call-cc.org/man/5/Deviations%20from%20the%20standard) — tiered Confirmed/Unconfirmed/Doubtful, alongside a sibling "Extensions to the standard" page |
| **Guile** | Per-port reader toggles (`read-enable 'r7rs-symbols`, etc.) more than `cond-expand` | ["R7RS Incompatibilities"](https://www.gnu.org/software/guile/manual/html_node/R7RS-Incompatibilities.html) / ["R6RS Incompatibilities"](https://www.gnu.org/software/guile/manual/html_node/R6RS-Incompatibilities.html) |
| **Gauche** | `cond-expand` with `gauche`/`gauche-X.X.X`; deprecates the old bare `srfi-N` shorthand with a runtime warning | ["Standard conformance"](https://practical-scheme.net/gauche/man/gauche-refe/Standard-conformance.html) — enumerates every SRFI's support shape |
| **Gambit** | `cond-expand` (`gambit` feature, `define-cond-expand-feature`) *and* `-:r5rs`/`-:r7rs`/`-:gambit` runtime flags *and* the `##`-namespace convention marking non-standard bindings in the identifier itself | Deviations noted inline per-section in the manual, not a separate page |
| **MIT/GNU Scheme** | `cond-expand`, documented as extended beyond SRFI-0's own scope (any context, not just toplevel) | Compliance verdict ("fully supported, with exceptions") stated inline in the R7RS manual section itself |
| **Racket** | `#lang` line as the whole-file version of this problem — `#lang r7rs` opts in explicitly | ["Standards"](https://docs.racket-lang.org/guide/standards.html) states plainly that `#lang racket` is not R5RS/R7RS |

The pattern across all six: nobody relies on documentation alone, and
nobody relies on a feature-test mechanism alone. CHICKEN's tiered honesty
(Confirmed/Unconfirmed/Doubtful) and Gambit's `##`-namespace (marking
non-standard-ness in the code itself, not just in docs) are the two most
distinctive ideas surfaced; neither is adopted directly here, but both
inform the tone recommended for `conformance.md` — state confidence
levels rather than false precision, since Kaappi's own concurrency layer
is, by KEP-0002's own admission, still finding correctness bugs in review.

## Unresolved questions

1. **Naming**: `kaappi-fibers` (prefixed) vs. `fibers` (bare, matching the
   unprefixed style of `posix`/`ieee-float`). Prefixed avoids collision with
   any future officially standardized concurrency feature name; this KEP's
   table above assumes prefixed but the choice is genuinely open.
2. **`kaappi-shared-channels` ship gate**: the moment KEP-0002 Phase 3
   merges to `main`, or only once the full KEP reaches Final? Leaning
   toward Phase 3 merge — cross-thread send/receive is safe and complete at
   that point; later phases (`(kaappi parallel)`, multi-core HTTP) are
   ecosystem-library work built on top, not core-subsystem safety.
3. **Runtime-variance companions**: sandbox thread-blocking and WASI
   reactor degradation are real but fundamentally unexpressible by
   `cond-expand`. Worth a paired runtime predicate (`(kaappi-threads-
   available?)`, `(kaappi-reactor-async?)`) as a follow-up KEP, or is a
   clearly worded caveat on `conformance.md` sufficient until real demand
   shows up?
4. **`conformance.md` staleness risk**: should CI in `kaappi.github.io`
   check the page's KEP-status table against this repo's `README.md` index
   (a cross-repo link check), or is that more machinery than a doc page
   warrants?

## Implementation plan

**Phase 0 — Evaluator unification (cleanup). Shipped:
[kaappi#1488](https://github.com/kaappi/kaappi/pull/1488).** Not gated on
anything; pure simplification, verified by the existing `cond-expand` test
suite (`tests_advanced.zig`, `tests_libraries.zig`). Landed as designed in
§2's revised form, not the original draft's `vm.vm_instance`-routing
proposal: `vm.zig`'s `checkLibraryExists` callback and `vm_library.zig`'s
`evalLibFeatureReq` now both call one shared
`vm_library.libraryIsAvailable()` instead of each hand-writing the same
check, and the redundant `known_libs` array is deleted outright. A
follow-up review round on the same PR also closed a pre-existing sandbox
gap in that shared function (`libraryIsAvailable` now returns `false`
under `--sandbox` instead of probing the filesystem) — not part of the
original Phase 0 scope, but a natural side effect of consolidating the
two call sites.

**Phase 1 — Base identifiers. Shipped: [kaappi#1488](https://github.com/kaappi/kaappi/pull/1488).**
Added `kaappi-fibers`, `kaappi-reactor`, `kaappi-threads` to
`types.platform_features`, gated on `builtin.os.tag` at comptime (`kaappi-
threads` omitted on `wasi`). Verified against a built binary and via
`features-consistency.scm` (#1177), extended with the three new
identifiers for Scheme-level parity with the Zig-side tests.

**Phase 2 — `kaappi-shared-channels`. Still blocked, correctly.** Gated on
KEP-0002's cross-thread wakeup (Phase 3) landing on `main` with its review
findings resolved. Phase 3 itself shipped
([kaappi#1485](https://github.com/kaappi/kaappi/pull/1485),
[#1486](https://github.com/kaappi/kaappi/pull/1486)), but "review findings
resolved" is not yet true: two bugs opened against the exact mechanism this
identifier would advertise are still open —
[kaappi#1487](https://github.com/kaappi/kaappi/issues/1487) (a dirty-
snapshot dispatch hazard in `mutex-lock!`/`condition-variable-wait!`/
`thread-sleep!`) and, more directly on point,
[kaappi#1489](https://github.com/kaappi/kaappi/issues/1489) (a **permanent
hang**: a local sibling send+receive during the `SharedChannelPoll` drive
can disarm the notifier registration before park). This is precisely the
gating scenario Motivation described in the abstract (the earlier
unmerged-wakeup SIGABRT risk); #1489 is its concrete successor. Phase 2
does not start until both are closed.

**Phase 3 — `kaappi-shared-buffers`.** Gated on KEP-0003 reaching Accepted
and shipping its own Phase 1. KEP-0003 is unchanged (Draft, skeleton, no
code) as of this update.

**Phase 4 — `conformance.md`. Shipped:
[kaappi.github.io#5](https://github.com/kaappi/kaappi.github.io/pull/5).**
New page linked from the `About:` nav next to Stability, cross-linked from
`guide/concurrency.md` (a new admonition covering the Phase 2 caveat above)
and `guide/srfi-support.md`. Documents cross-thread channels honestly as
shipped-but-unhardened rather than waiting for Phase 2's gate to clear —
the page's job is to state current reality, not just what has a `cond-
expand` identifier yet.

**Phase 5 (follow-up, not this KEP) — Runtime-variance predicates**, per
Unresolved question 3, if real usage shows the gap matters in practice.
Not started.
