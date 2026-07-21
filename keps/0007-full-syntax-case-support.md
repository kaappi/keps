# KEP-0007: Full syntax-case Support (Deferred)

| Field | Value |
|-------|-------|
| **KEP** | 0007 |
| **Title** | Full syntax-case Support (Deferred) |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (informational — no implementation proposed) |
| **Created** | 2026-07-21 |
| **Requires** | — |
| **Supersedes** | — |

*Search results cited below are current as of query date 2026-07-21. Split
out of an earlier combined draft with KEP-0006 (Explicit-Renaming Macros)
because the two proposals have no build-order dependency on each other:
this KEP is external-standard-tracking and deliberately not proposing
near-term work, while KEP-0006 is a concrete, independently actionable
proposal. Read KEP-0006 first — its Motivation section is this KEP's
motivation too, and is not repeated in full here.*

## Summary

This is a **tracking KEP, not an implementation proposal**. It records what
is known about R7RS-large's adoption of `syntax-case` — real, voted on,
but not finalized until a 2028 target — and why Kaappi should not build a
conformant implementation against today's still-moving draft. It documents,
concretely, why `syntax-case` cannot be added as a small extension of
Kaappi's current `syntax-rules` engine, so that a future implementer
doesn't have to rediscover the same architecture facts from scratch. No
work is proposed here; see KEP-0006 for what *is* proposed to address the
same underlying problem sooner.

## Motivation

KEP-0006's Motivation section documents the concrete pain (SRFI 241 and
SRFI 202 both assuming `syntax-case` in their reference implementations)
that prompted this whole line of investigation. This KEP exists because,
having confirmed that pain is real, the natural next question is "should
Kaappi just implement the standard's actual answer" — and the honest answer
right now is no, for reasons worth recording rather than re-deriving the
next time this comes up.

### R7RS-large has adopted syntax-case — but it is not finalized

Per the WG2 (Scheme Reports Working Group 2) FAQ and the `scheme/r7rs`
Codeberg repository (see Sources):

- The working group **voted to adopt `syntax-case`** in 2023, specifically
  because `syntax-rules` cannot express macros whose behavior depends on
  real computation over the input syntax — the same class of problem
  KEP-0006's Motivation demonstrates concretely against Kaappi's own SRFI
  ports.
- `syntax-case` lives in R7RS-large's **"Macrological Fascicle"**, one part
  of a three-volume "Foundations" document.
- **Target completion is 2028.** Committee activity (meeting agendas and
  minutes) is ongoing through at least June 2026, including *unresolved*
  questions as basic as **how `syntax-case` should be named as a library**
  — one contributor's position, quoted directly: "I don't see any reason
  for `(scheme syntax-case)` to exist; instead `(rnrs syntax-case (6))`
  would be the R7RS-large syntax-case library." That is not a settled
  detail two years after the adoption vote.
- The alternative the committee explicitly rejected for this purpose,
  **SRFI 148 (eager syntax-rules)**, is confirmed by its own reference
  implementation to add no power beyond `syntax-rules` — convenience sugar,
  not a fix for the class of problem in KEP-0006's Motivation.
- The committee's own discussion acknowledges two lighter alternatives —
  **syntactic closures** and **explicit-renaming macros** (KEP-0006's
  proposal) — as "older, simpler, and more in the spirit of Scheme," while
  noting neither gives a fully correct answer to *deliberately breaking*
  hygiene the way `syntax-case`'s `datum->syntax` can. KEP-0006 makes that
  tradeoff deliberately for the sake of shipping something sooner, cheaper,
  and lower-risk to Kaappi's core.

The practical conclusion: `syntax-case` is a real, load-bearing future
requirement for full R7RS-large conformance, not a rumor — but its concrete
shape is still moving. Building a full, conformant implementation against a
2026 draft risks a second rewrite before 2028.

## Guide-level explanation

For comparison against KEP-0006's `er-macro-transformer` sketch, what the
same macro looks like under full `syntax-case`: the transformer receives
and returns **syntax objects** (not raw data), so hygiene is automatic
rather than manual (no `rename` calls needed), and `with-syntax`/`#'`/`#,`
give pattern-style destructuring back on top of the procedural core:

```scheme
(define-syntax match
  (lambda (stx)
    (syntax-case stx ()
      ((_ e clause ...)
       #'(let ((t e)) (match-clauses t clause ...))))))
```

Contrast with KEP-0006's explicit-renaming version of the same fragment,
which needs manual `rename` calls at every identifier that must be fresh,
in exchange for a dramatically smaller implementation.

## Reference-level design

Recorded for completeness, not proposed for near-term work. All of this is
**in addition to** the reentrant-compile-time-execution prerequisite
KEP-0006 already identifies and proposes to build (which this KEP would
also depend on, if pursued):

- A genuine **syntax object** heap type wrapping a datum with hygiene
  context (marks/scope-sets, in the Dybvig-Hieb-Bruggeman or
  "sets-of-scopes" tradition) that survives being pulled apart and
  reassembled by arbitrary transformer code. This is the one piece
  KEP-0006's mechanism cannot be incrementally grown into: Kaappi's current
  renaming (bake gensyms into a freshly-built S-expression once, during one
  template walk, or — under KEP-0006 — one explicit `rename` call at a
  time) produces hygiene as a *side effect of walking output once*.
  `syntax-case` needs hygiene information to travel *with* a value a
  transformer stores in a variable and re-emits later, arbitrarily far from
  where it was first produced — a different representation, not a bigger
  version of the same one.
- `syntax->datum`, `datum->syntax`, `free-identifier=?`, `bound-identifier=?`,
  `generate-temporaries`, `with-syntax`, and the `syntax`/`quasisyntax`
  template forms (with or without `#'`/`#,`/`#,@` reader shorthand, which
  is its own reader-syntax decision this KEP doesn't need to make yet).
- Almost certainly, **reimplementing `syntax-rules` itself in terms of
  `syntax-case`** to keep one hygiene algorithm instead of two permanently
  diverging ones — which is exactly the R7RS-large committee's own stated
  tension ("were it not for the interdependency of syntax-rules and
  syntax-case, the latter might have been kicked out ... and made a
  portable library"). That risks regressing the existing, fast,
  well-tested `syntax-rules` path (`tests/scheme/hygiene/`,
  `src/tests_macros.zig`) for the sake of the new one.
- Possibly **phase separation** (R6RS-style `for-syntax`/expand-time vs.
  run-time environments) if Kaappi wants to track the eventual R7RS-large
  library-import story precisely — itself a multi-week design question on
  top of everything above.

## Drawbacks

- Building now, against an unfinished spec, risks a costly rewrite once
  R7RS-large's Macrological Fascicle actually finalizes (target 2028) and
  differs from whatever draft Kaappi implemented against.
- The full cost (new heap type, likely `syntax-rules` reimplementation,
  possible phase separation) is categorically larger than KEP-0006's
  proposal for addressing the same immediate, already-demonstrated pain.
- Two hygiene algorithms living side by side indefinitely (if `syntax-rules`
  is *not* reimplemented on top of `syntax-case`, to avoid the regression
  risk above) is its own long-term maintenance cost.

## Alternatives considered

This KEP *is* the "wait and track" alternative to KEP-0006. The
alternatives properly belong there; see KEP-0006's Alternatives considered
section for the full comparison (do nothing / per-library workarounds,
explicit-renaming, syntactic closures, SRFI 148, SRFI 149).

## Cross-platform / compatibility impact

Not evaluated in depth — premature while this remains a tracking KEP with
no committed design. Whatever WASM, native-compile, and `kaappi
check`/`--sandbox` considerations apply to KEP-0006's reentrant-execution
prerequisite would apply here too, at minimum.

## Unresolved questions

1. **When does R7RS-large's Macrological Fascicle stabilize enough to act
   on?** Re-check committee status (Sources below) periodically; the
   naming question alone (`(scheme syntax-case)` vs. `(rnrs syntax-case
   (6))`) blocks writing a conformant `import` story today.
2. **Does KEP-0006's real-world experience change what Kaappi would want
   here?** If explicit-renaming macros ship and prove sufficient for
   Kaappi's own SRFI-porting needs, the case for also building full
   `syntax-case` weakens to "conformance for its own sake" rather than
   "solves a problem nothing else solves." If they prove insufficient in
   some concrete, recurring way, that's a strong signal for revisiting this
   KEP with much better evidence than is available today.
3. **Should Kaappi track R7RS-large conformance at all**, given it is
   already a deliberate R7RS-**small**-plus-extensions implementation
   (KEP-0004)? This KEP assumes "probably, eventually, for the macro system
   specifically" without having made that case rigorously — worth revisiting
   if the answer turns out to be no.

## Implementation plan

None proposed. Revisit this KEP when either:

- R7RS-large's Macrological Fascicle reaches a stable draft (watch
  `scheme/r7rs` on Codeberg), or
- KEP-0006 has shipped and been used in practice long enough to know
  whether its `rename`/`compare` approximation is sufficient for Kaappi's
  actual needs, giving this KEP either much weaker or much stronger
  motivation than it has today.

## Sources

- [scheme/r7rs wiki — Codeberg](https://codeberg.org/scheme/r7rs/wiki)
- [scheme/r7rs FAQ — Codeberg](https://codeberg.org/scheme/r7rs/wiki/FAQ)
- [#126 "R6RS and R7RS-large" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/126)
- [#5 "General principle: What is mandatory for R7RS Large implementations?" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/5)
- [#127 "RωRS" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/127)
- [scheme-reports-wg2 Google Group — R7RS-large backward compatibility](https://groups.google.com/g/scheme-reports-wg2/c/BiHu18vmXng/m/3a5qU9GxGwAJ)
- [scheme-reports-wg2 Google Group — R7RS-large discussion: Miscellaneous](https://groups.google.com/g/scheme-reports-wg2/c/oKuhgwaM45w)
- [Scheme Standards index — standards.scheme.org](https://standards.scheme.org/)
