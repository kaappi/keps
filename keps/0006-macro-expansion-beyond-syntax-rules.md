# KEP-0006: Macro Expansion Beyond syntax-rules

| Field | Value |
|-------|-------|
| **KEP** | 0006 |
| **Title** | Macro Expansion Beyond syntax-rules |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (`expander.zig`, `compiler_macro.zig`, `types.zig`, `vm_library.zig`) |
| **Created** | 2026-07-21 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit
[`fe05ec92`](https://github.com/kaappi/kaappi/commit/fe05ec92) (main, 2026-07-21)
and were read directly from that source. Line numbers for `expander.zig` and
`types.zig` were verified by reading the full files at that commit.*

## Summary

Kaappi's macro system is `syntax-rules` only — a deliberate R7RS-small choice
(`syntax-case` is explicitly out of scope for R7RS-small; see
[README.md#Macros](https://github.com/kaappi/kaappi/blob/fe05ec92/README.md)).
That is correct for the core language today. But porting several recent
portable SRFIs (241 "Match", 202 "Pattern-matching and-let*", and by
extension anything shaped like a pattern matcher) has repeatedly hit the same
wall: their reference implementations assume `syntax-case` — a macro
transformer that is *arbitrary Scheme code*, not a fixed template — and doing
without it means either a substantially scoped-down port or an elaborate
workaround.

This KEP does **not** propose implementing R7RS-large's `syntax-case`
wholesale right now. Instead it:

1. Confirms, with sources, that `syntax-case` is real, adopted, but not yet
   finalized standard track (target 2028) — so building to today's draft
   risks a costly rewrite later.
2. Documents, from Kaappi's own macro-expansion source, exactly why
   `syntax-case` cannot be added as a small extension of the current
   `syntax-rules` engine — the two are architecturally different in a way
   that matters for a project this size.
3. Proposes a smaller, well-precedented intermediate step — **explicit-
   renaming macros** (`er-macro-transformer`, in the tradition of Chibi
   Scheme, Chicken, and MIT/GNU Scheme's historic `sc-macro-transformer`) —
   that solves the concrete "I need real code as a macro body" problem at a
   fraction of the implementation and risk cost, while being explicit that
   it is a **Kaappi extension**, not an R7RS-large preview.
4. Flags the one prerequisite both paths share — the compiler being able to
   *run* a macro transformer as code, rather than just pattern-match against
   it — as its own risk surface, including a real interaction with the
   `kaappi check` / `--sandbox` "executes nothing at compile time" guarantee
   that is worth resolving before either path is built.

## Motivation

### First-hand evidence: SRFI 241 and SRFI 202

While implementing SRFI 241 (Match) for the SRFI Phase 1 milestone, the
reference implementation's own text says: "a portable implementation for
R7RS systems that support `syntax-case` is possible" — implying the
reference authors did not expect `syntax-rules`-only implementations to
manage a full port. Kaappi's port (`lib/srfi/241.sld`) had to:

- Use a **custom ellipsis identifier** in every helper macro (`(syntax-rules
  %%% (unquote _ -> ...) ...)`) purely so the literal three-dot token could
  be pattern-matched as ordinary data — the standard `syntax-rules` trick
  for "I need `...` to mean `...`, not repetition," verified empirically
  before relying on it (a custom-ellipsis probe script, not cited in the
  merged library, confirmed the behavior on this build before the real
  implementation was written).
- **Drop the SRFI's own ellipsis-aware `quasiquote`** that it binds inside
  `match` bodies — reimplementing splicing-with-ellipsis as a nested macro
  is itself close to reimplementing `syntax-case`'s template facility, and
  was cut for scope.
- **Restrict ellipsis-repeated sub-patterns** to plain `,var`, `,_`, and a
  single hand-added case for repeated default-cata `,(var)` (needed because
  the SRFI's own canonical example, `(+ ,[x*] ...)`, uses exactly that
  shape) — arbitrary compound patterns under an ellipsis are unsupported,
  because collecting "which identifiers does this arbitrary sub-pattern
  bind" generically is itself a small `syntax-case`-shaped problem
  (enumerate identifiers, build code that walks and zips them) that
  `syntax-rules` has no facility for.
- **Drop vector patterns with a mixed mandatory prefix/suffix around an
  ellipsis** — only whole-vector-ellipsis and fixed-length are supported.

None of this is a Kaappi implementation bug — every workaround is a standard,
independently-documented `syntax-rules` idiom (the custom-ellipsis trick, the
peel-the-last-element idiom used again in SRFI 202's general multi-pattern
`and-let*` claw, a CPS-style "pass the continuation as another macro
argument" style used throughout both libraries to avoid combinatorial code
blowup). But five macros' worth of these idioms, in two SRFIs, is a strong
signal: this is a recurring cost that a `syntax-case`-shaped facility would
remove, not a one-off.

SRFI 202's own reference implementation description says outright: "The
reference implementation is a `syntax-case` macro matching on claw shape,
using `match`... for destructuring" — i.e. the SRFI's own authors built it
on exactly the two facilities (`syntax-case`, and a `match` that assumes
`syntax-case`) that Kaappi does not have.

### R7RS-large has adopted syntax-case — but it is not finalized

Per the WG2 (Scheme Reports Working Group 2) FAQ and the `scheme/r7rs`
Codeberg repository (see Sources below), current as of query date 2026-07-21:

- The working group **voted to adopt `syntax-case`** in 2023 for R7RS-large,
  specifically because `syntax-rules` cannot express macros whose behavior
  depends on real computation over the input syntax — the same class of
  problem this KEP's Motivation section demonstrates concretely.
- `syntax-case` lives in R7RS-large's **"Macrological Fascicle"**, one part
  of a three-volume "Foundations" document.
- **Target completion is 2028.** Committee activity (meeting agendas/minutes)
  is ongoing through at least June 2026, including *unresolved* questions as
  basic as **how `syntax-case` should be named as a library** — one
  contributor's position, quoted directly: "I don't see any reason for
  `(scheme syntax-case)` to exist; instead `(rnrs syntax-case (6))` would be
  the R7RS-large syntax-case library." That is not a settled detail.
- The alternative the committee explicitly rejected for *this* purpose,
  **SRFI 148 (eager syntax-rules)**, is confirmed by its own reference
  implementation to add no power beyond `syntax-rules` — it's convenience
  sugar, not a fix for the class of problem in this KEP's Motivation.
- The committee's own discussion acknowledges two lighter alternatives —
  **syntactic closures** and **explicit-renaming macros** — as "older,
  simpler, and more in the spirit of Scheme," while noting neither gives a
  fully correct answer to *deliberately breaking* hygiene the way
  `syntax-case`'s `datum->syntax` can. That tradeoff is exactly the one this
  KEP asks Kaappi to make deliberately, in Alternatives considered.

The practical conclusion: **`syntax-case` is a real, load-bearing future
requirement, not a rumor** — but its concrete shape (library name, exact
primitive set) is still moving two years into the project. Building a full,
conformant implementation against a 2026 draft risks a second rewrite before
2028.

## Guide-level explanation

What today's workaround looks like (from the shipped `lib/srfi/241.sld`) —
a helper macro that has to smuggle the *token* `...` through pattern
matching instead of writing the obvious code:

```scheme
;; "does this pattern have the shape (something <literal-dots> . rest)?"
;; -- %%% is a stand-in ellipsis so "..." can be an ordinary pattern datum.
(define-syntax %match-pat
  (syntax-rules %%% (unquote _ -> ...)
    ((_ val self (p1 ... . prest) kt kf)
     (%match-ellipsis-list val self p1 prest kt kf))
    ...))
```

What the same fragment looks like as an **explicit-renaming** macro — real
Scheme code, no pattern-matching indirection needed to ask "is the second
element the ellipsis symbol?":

```scheme
(define-syntax match
  (er-macro-transformer
    (lambda (form rename compare)
      (let ((clauses (cdr form)))
        ;; ordinary list processing: split on the ellipsis symbol wherever
        ;; it occurs, build the expansion by calling ordinary procedures.
        ;; `rename` produces a hygienic reference to a helper identifier;
        ;; `compare` answers "do these two identifiers mean the same thing
        ;; at their respective definition sites" (replaces syntax-rules'
        ;; literal-identifier matching).
        (expand-match-clauses (rename 'let) clauses rename compare)))))
```

The transformer body is a **real lambda that runs**, not a template the
expander pattern-matches against — arbitrary helper procedures, recursion,
and data structures are available, which is precisely what was missing.

What full `syntax-case` adds on top of that (for comparison, not proposed
for immediate implementation): the transformer receives and returns
**syntax objects** (not raw data), so hygiene is automatic rather than
manual (no `rename` calls needed), and `with-syntax`/`#'`/`#,` give
pattern-style destructuring back on top of the procedural core:

```scheme
(define-syntax match
  (lambda (stx)
    (syntax-case stx ()
      ((_ e clause ...)
       #'(let ((t e)) (match-clauses t clause ...))))))
```

## Reference-level design

### The shared prerequisite: compile-time procedure execution

Both tracks below need the same foundational capability that Kaappi does
not have today: **a macro transformer that is a called procedure, not a
static template the expander walks in pure Zig.**

Today, `expander.zig`'s `expandMacro` (line 168) and everything it calls
(`matchPattern`, `instantiateTemplate`, `renameForHygiene`, ...) is pure Zig
— it never calls into the VM. `types.Transformer` (`types.zig:455`) is a
fixed-shape struct: `literals`/`patterns`/`templates` arrays plus
`num_rules`, modeling exactly one thing, a `syntax-rules` rule set. There is
no "kind" tag, no procedure-value field, and no path by which
`compileMacroForm`/`vm_library.zig`'s library loading (the two other
`Transformer` producers, alongside `compiler_macro.zig`) could construct a
transformer that is "call this closure" instead of "match these patterns."

Making a transformer callable means: `define-syntax`'s special-form handling
must, for a new transformer-producing form, **compile and execute** the
transformer expression (an ordinary `lambda`) *before* continuing to compile
the rest of the program, to obtain a closure value — and then, at every
*use* site of that macro, `compiler_macro.zig`'s macro-invocation dispatch
must **call that closure via the VM** (`vm_calls.callValue` or equivalent)
and use its *return value* as the form to keep expanding, instead of calling
`expandMacro`.

This is a real, new capability — reentrant VM execution nested inside
`compile()` — not a detail. It has consequences the current pipeline does
not need to consider:

- **GC rooting across the reentrant call.** Every in-flight IR/AST node
  being compiled around the macro use must stay rooted across a full
  `vm.execute()` call, which itself allocates and can collect. `.claude/rules/gc-safety.md`'s
  "root `Function*` before `vm.execute()`" rule generalizes to "root the
  entire partially-built form."
- **Error handling.** A transformer procedure can raise a normal Scheme
  error (division by zero, wrong type, an unbound variable in a buggy
  macro). That has to surface as a *compile* error with a source location
  pointing at the macro use, not as an uncaught runtime exception three
  layers into the expander.
- **`kaappi check` / `--sandbox` interaction — the sharpest finding here.**
  `kaappi check` is documented (`docs/dev/check.md`) as read-only: "reads,
  expands, compiles, executes nothing." That promise is airtight *today*
  specifically because expansion is pure Zig with no VM calls. The instant
  a transformer is a called procedure, `kaappi check`-ing a file that
  defines one **does execute Scheme code** — the transformer body — even
  though the check still never executes the *program's* top-level code.
  Whether that's an acceptable, clearly-documented carve-out (transformer
  bodies are "compile-time code" and always run, even under `check`) or
  something `--sandbox` needs to additionally gate (e.g. transformers run
  under the same sandboxed capability set as the rest of the program) is a
  real design decision, not an implementation detail — see Unresolved
  questions.
- **WASM / native-compile backend.** Both `zig build wasm` and `kaappi
  compile`'s LLVM backend share the same front-end pipeline through
  expansion, so a reentrant-VM-during-expand capability has to work
  identically there. This looks low-risk mechanically (the WASM build
  already runs the same interpreter loop single-threaded, and the two
  process-wide counters this KEP's changes would add anywhere,
  `gensym_counter`-style, are `u32` atomics — the pattern the codebase
  already uses to stay clear of the "no 64-bit atomics on wasm32"
  constraint) but should be verified with an actual cross-compiled
  `kaappi.wasm` build once either track has running code, not assumed.

### Track A (proposed near-term): explicit-renaming macros

Lower cost, well-precedented, and — this is important to be explicit about —
**not a preview of R7RS-large's `syntax-case`**. It should ship as a
documented Kaappi extension (the same posture KEP-0004 established for
fibers/reactor/channels: things R7RS-small has no opinion on, clearly
labeled as going beyond it).

Sketch:

1. **`types.Transformer` grows a `kind` tag** (`.syntax_rules` |
   `.explicit_renaming`), or becomes a tagged union with the existing fields
   under `.syntax_rules`. The `.explicit_renaming` variant holds a single
   `Value` — the transformer closure.
2. **`compiler_macro.zig` recognizes `(er-macro-transformer expr)`** as a
   sibling production to `(syntax-rules ...)` wherever the latter is
   recognized today, compiles and executes `expr` to a closure, and stores
   it as an `.explicit_renaming` transformer.
3. **Macro-use dispatch branches on `kind`.** For `.explicit_renaming`, call
   the stored closure with three arguments: `(form rename compare)`.
   - `form` is the macro-use S-expression, unwrapped exactly as
     `expandMacro` does today (`types.cdr(expr)` to strip the keyword, or
     the whole form — precedent varies across implementations; picking one
     is an Unresolved question below).
   - `rename` is a **native closure that calls Kaappi's existing
     `renameForHygiene`** (`expander.zig:1195`) — this is the one piece of
     the current hygiene machinery Track A can reuse directly rather than
     rebuild: the gensym-per-scope table already does exactly "give me a
     name that can't collide with a user binding," which is all
     explicit-renaming's `rename` needs. This is the concrete reason Track
     A is materially cheaper than Track B: it needs a *procedure wrapper*
     around existing machinery, not a new hygiene representation.
   - `compare` answers `free-identifier=?`-shaped questions; a first cut can
     be `eq?` on symbol names post-rename, tightened later against the
     existing literal-matching logic in `matchPattern` (`expander.zig:266`
     already implements the real R7RS 4.3.2 "same binding or both unbound"
     rule for `syntax-rules` literals — Track A should reuse that logic
     through a shared helper rather than reimplement it).
   - The closure's **return value becomes the expansion**, fed back into
     the same downstream pipeline `expandMacro`'s result feeds today.
4. **No new heap type, no phase separation, no `syntax->datum`/
   `datum->syntax`.** The transformer operates on plain data in and plain
   data out — the same representation `syntax-rules` templates already
   produce.

Estimated blast radius, from a direct count against `fe05ec92`: `Transformer`
is consumed at 23 call sites across 6 files (`compiler_lambda.zig`,
`compiler_macro.zig`, `expander.zig`, `gc_deep_copy.zig`,
`tests_deepcopy.zig`, `types.zig`, plus `vm_library.zig` for library-body
macros). Every one needs a `switch` on the new `kind` tag or an early return
for the non-`syntax_rules` case — mechanical, but real, and it is precisely
the surface the user's original concern was about.

### Track B (deferred): full syntax-case

Recorded for completeness and to make the cost difference concrete, not
proposed for near-term work:

- A genuine **syntax object** heap type wrapping a datum with hygiene
  context (marks/scope-sets, in the Dybvig-Hieb-Bruggeman or
  `sets-of-scopes` tradition) that survives being pulled apart and
  reassembled by arbitrary transformer code — Kaappi's current renaming
  (bake gensyms into a freshly-built S-expression once, during one
  template walk) cannot do this: hygiene information has to travel *with*
  a value a transformer stores in a variable and re-emits later, not be
  produced once as a side effect of walking a fixed template.
- `syntax->datum`, `datum->syntax`, `free-identifier=?`, `bound-identifier=?`,
  `generate-temporaries`, `with-syntax`, and the `syntax`/`quasisyntax`
  template forms (with or without `#'`/`#,`/`#,@` reader shorthand, which is
  its own reader-syntax decision `.claude/rules` doesn't currently need to
  make for anything else).
- Almost certainly, **reimplementing `syntax-rules` itself in terms of
  `syntax-case`** to keep one hygiene algorithm instead of two permanently
  diverging ones — which is exactly the R7RS-large committee's own stated
  tension ("were it not for the interdependency of syntax-rules and
  syntax-case, the latter might have been kicked out ... and made a
  portable library"). That risks regressing the existing, fast,
  well-tested `syntax-rules` path (`tests/scheme/hygiene/`,
  `src/tests_macros.zig`) for the sake of the new one.
- Possibly **phase separation** (R6RS-style `for-syntax`/expand-time vs
  run-time environments) if Kaappi wants to track the eventual R7RS-large
  library-import story precisely — itself a multi-week design question, not
  included in Track A at all.

## Drawbacks

- **Two macro systems to maintain and document**, if Track A ships:
  `syntax-rules` (fast, template-only, what the whole existing library
  ecosystem uses) and `er-macro-transformer` (procedural, for the cases
  `syntax-rules` genuinely cannot express). Every future contributor needs
  to know which to reach for.
- **Track A is not standard.** Code written against Kaappi's
  `er-macro-transformer` is not portable to implementations that lack it
  (though the mechanism itself — not the exact calling convention — is
  precedented enough across existing Schemes that porting *to* Kaappi from
  one of them is usually mechanical).
- **The reentrant-VM-during-compile capability is new load-bearing
  machinery** regardless of which track is chosen, and its interaction with
  `kaappi check`/`--sandbox` needs a real answer, not silence — shipping
  either track without settling that is a security-relevant gap.
- **Effort spent on Track A is not effort spent on Track B.** If Kaappi
  later wants full R7RS-large conformance, Track A's `rename`/`compare`
  design does not upgrade into `syntax-case`'s syntax-object model for
  free — it is a genuinely different mechanism, not a subset.

## Alternatives considered

- **Do nothing; keep documenting per-library workarounds.** What this
  session actually did for SRFI 241/202. Zero implementation risk, but the
  custom-ellipsis / peel-last-element / CPS-continuation-argument idioms
  this KEP's Motivation catalogs are exactly the kind of "hard-won tribal
  knowledge" that should either be captured as a durable macro-writing guide
  in `docs/dev/` (a much smaller, immediately actionable alternative to this
  whole KEP) or replaced by Track A. Recorded here as the honest zero-cost
  baseline everything else is measured against.
- **Wait for R7RS-large to finalize (2028), implement syntax-case then.**
  Lowest risk of building the wrong thing, at the cost of years of continued
  workarounds for every SRFI shaped like SRFI 241/202. Reasonable if the
  project's SRFI-porting pace is expected to slow; less so given three
  Phase milestones of portable SRFIs are already tracked (`docs/dev/srfi-exclusions.md`
  and the four SRFI Phase milestones on the `kaappi` issue tracker).
- **Syntactic closures** (the other alternative the R7RS-large committee
  itself weighed) — pass an explicit *environment* rather than a
  rename/compare pair; older than explicit-renaming, similarly non-standard
  for R7RS-large's eventual answer, no clearer implementation-cost
  advantage identified over Track A. Not pursued further here for lack of
  a concrete reason to prefer it over the more widely-precedented
  explicit-renaming style.
- **SRFI 148 (eager syntax-rules).** Explicitly ruled out by the R7RS-large
  committee's own reasoning, confirmed independently in this KEP's research:
  its reference implementation is pure `syntax-rules`, so it cannot express
  anything `syntax-rules` cannot express today — it would not have helped
  SRFI 241 or 202.

## Cross-platform / compatibility impact

- **WASM (`zig build wasm`):** Should work identically in principle (see
  Reference-level design's prerequisite section) but is unverified until
  either track has running code; the WASM build must be exercised with a
  real transformer-defining `.scm` file before either track is called
  done, not assumed safe from the existing atomics precedent alone.
- **Native compile backend (`kaappi compile`, LLVM):** Macro expansion
  happens before IR lowering for both interpreted and native-compiled
  programs, so this is a front-end change only — no LLVM-emission changes
  expected for either track. Should still be smoke-tested through `kaappi
  compile` once implemented, since the backend's own test suite
  (`tests/scheme/compile/`) exercises real programs, not just the
  interpreter path.
- **`kaappi check` / `--sandbox`:** Genuinely affected, as detailed above —
  this is the one item in this KEP that is a compatibility/security
  question, not just an implementation one, and needs an explicit decision
  before shipping either track.
- **`--sandbox`'s capability model specifically:** if transformers can run
  arbitrary code, a sandboxed program that merely *defines* (but never
  calls) a malicious macro could still execute its transformer body the
  moment another part of the same file uses that macro during compilation
  — i.e. before the sandbox's runtime restrictions would otherwise apply
  to the program's own execution. This needs to be resolved by design, not
  discovered by a security report.
- **Existing `syntax-rules` behavior:** Track A adds a new transformer kind
  alongside the existing one and should not change `syntax-rules` semantics
  at all — the full `tests/scheme/hygiene/` and `src/tests_macros.zig`
  suites should stay green with zero modifications as an explicit
  acceptance criterion. Track B's "reimplement syntax-rules on top of
  syntax-case" risk is exactly why it is deferred rather than proposed here.

## Unresolved questions

1. **What exactly does the transformer procedure receive?** The whole macro
   use-form including the keyword (Chibi's convention) or just the
   arguments (`expandMacro`'s current convention, stripping the keyword via
   `types.cdr(expr)`)? Picking Chibi's whole-form convention makes porting
   existing `er-macro-transformer` libraries more direct.
2. **Does `compare` need definition-site environment awareness**, or is
   post-rename `eq?`-on-symbol-name sufficient for the cases Kaappi's own
   library ecosystem would actually exercise? `matchPattern`'s existing
   `literal_bound`/`use_check` machinery (`expander.zig:266`–`301`) already
   solves a version of this correctly for `syntax-rules` literals; whether
   it generalizes directly or needs its own pass is worth a spike before
   committing to an API.
3. **`kaappi check`/`--sandbox` policy, precisely.** Candidate answers: (a)
   transformer bodies always run under `check`/`--sandbox`, documented as
   "macro-defining code is compile-time code, not sandboxed program code";
   (b) transformer bodies run under the *same* sandbox restrictions as the
   rest of the file; (c) `check` refuses to fully expand files that define
   `.explicit_renaming` transformers and reports a diagnostic instead. No
   candidate has been evaluated against `docs/dev/check.md`'s existing
   guarantees in enough depth to recommend one yet.
4. **Does the community's macro-writing style for Kaappi's own SRFI ports
   prefer Track A once it exists**, or do contributors keep reaching for
   `syntax-rules`-plus-idioms out of habit? Only observable after Track A
   ships and a few more pattern-matcher-shaped SRFIs get ported with it
   available.
5. **Should this KEP's Track A naming (`er-macro-transformer`) match Chibi
   Scheme's exactly**, to maximize direct portability of existing libraries
   written against it, or diverge where Kaappi's calling convention differs
   for a good reason? Leans toward matching unless a concrete reason not to
   surfaces during implementation.

## Implementation plan

Phased so that the highest-risk, most architecturally novel piece (reentrant
compile-time execution) is proven in isolation before either macro-facing
API is built on top of it, and so that the `check`/`--sandbox` question
(Unresolved question 3) is settled by design before it can be a security
incident.

1. **Spike: reentrant VM execution from within `compile()`.** No new
   surface syntax yet — a Zig-internal proof of concept that
   `compiler_macro.zig` can compile-and-execute an arbitrary expression to
   get a closure `Value`, then call that closure via the VM, with correct
   GC rooting across the call and a compile-error (not a crash) on a
   transformer that raises. Exit criterion: a hand-written test in
   `tests_macros.zig` that defines a "transformer" this way and confirms
   rooting survives a forced GC (`-Dgc-stress=true`) during the call.
2. **Resolve Unresolved question 3** (the `check`/`--sandbox` policy) as a
   short, standalone design note before writing user-facing macro syntax —
   this is the one item with security consequences if skipped.
3. **`types.Transformer` gains its `kind` tag**; audit and update all 23
   existing call sites (the six files listed in Reference-level design) to
   handle both kinds, with the `.syntax_rules` path byte-for-byte unchanged
   in behavior — verified by the existing hygiene/macro test suites passing
   with zero modifications.
4. **`er-macro-transformer` special form + `rename`/`compare`
   implementation**, reusing `renameForHygiene` and the literal-matching
   logic identified in Reference-level design rather than rebuilding either.
5. **Re-port SRFI 241 and/or SRFI 202 on top of Track A** as the acceptance
   test for the whole feature — if the ellipsis-aware quasiquote, compound
   ellipsis sub-patterns, and mixed vector prefix/suffix limitations
   documented in `lib/srfi/241.sld`'s header can now be lifted, that is the
   concrete, falsifiable signal that Track A delivered what this KEP set
   out to fix. If they can't be lifted cleanly, that is equally valuable
   signal that Track A's design needs another iteration before wider use.
6. **Document as a Kaappi extension**, in the same spirit as KEP-0004: a
   `cond-expand` feature identifier (e.g. `kaappi-er-macros`) and a
   kaappi-lang.org page stating plainly that this is beyond R7RS-small and
   is *not* the eventual R7RS-large `syntax-case`.
7. **Track B stays a Draft placeholder inside this KEP** (not split out)
   until R7RS-large's Macrological Fascicle is closer to final — revisit
   the "wait" alternative's cost/benefit at that point with the benefit of
   Track A's real-world experience.

## Sources

- [scheme/r7rs wiki — Codeberg](https://codeberg.org/scheme/r7rs/wiki)
- [scheme/r7rs FAQ — Codeberg](https://codeberg.org/scheme/r7rs/wiki/FAQ)
- [#126 "R6RS and R7RS-large" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/126)
- [#5 "General principle: What is mandatory for R7RS Large implementations?" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/5)
- [#127 "RωRS" — scheme/r7rs issues](https://codeberg.org/scheme/r7rs/issues/127)
- [scheme-reports-wg2 Google Group — R7RS-large backward compatibility](https://groups.google.com/g/scheme-reports-wg2/c/BiHu18vmXng/m/3a5qU9GxGwAJ)
- [scheme-reports-wg2 Google Group — R7RS-large discussion: Miscellaneous](https://groups.google.com/g/scheme-reports-wg2/c/oKuhgwaM45w)
- [Scheme Standards index — standards.scheme.org](https://standards.scheme.org/)
