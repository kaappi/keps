# KEP-0006: Explicit-Renaming Macros (er-macro-transformer)

| Field | Value |
|-------|-------|
| **KEP** | 0006 |
| **Title** | Explicit-Renaming Macros (er-macro-transformer) |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (`expander.zig`, `compiler_macro.zig`, `types.zig`, `vm_library.zig`, `memory.zig`, `gc_collect.zig`) |
| **Created** | 2026-07-21 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit
[`7949e497`](https://github.com/kaappi/kaappi/commit/7949e497) (main, 2026-07-21)
and were read directly from that source. That commit completed the SRFI
Phase 1 milestone — it added `lib/srfi/241.sld` and `lib/srfi/202.sld` — so
both the Zig engine references below and the shipped SRFI ports this KEP
cites as evidence exist and are readable at that single revision. See
KEP-0007 for the (deferred) full `syntax-case` alternative and the
R7RS-large research behind choosing not to pursue it now — split out of an
earlier draft of this KEP because the two proposals have no build-order
dependency on each other and belong under different `Status` fields.*

## Summary

Adds a second, procedural macro-transformer kind alongside `syntax-rules`:
**explicit-renaming macros** (`er-macro-transformer`), in the tradition of
Chibi Scheme, Chicken, and MIT/GNU Scheme's historic `sc-macro-transformer`
family. A transformer is a real Scheme procedure — `(lambda (form rename
compare) ...)` — that runs and returns the expansion, instead of a template
the expander pattern-matches against. This is proposed as a **documented
Kaappi extension**, not a preview of any future R7RS-large facility — see
KEP-0007 for why full `syntax-case` is deliberately not this KEP's proposal.

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
  before relying on it (a custom-ellipsis probe script, not part of the
  merged library, confirmed the behavior on this build first).
- **Drop the SRFI's own ellipsis-aware `quasiquote`** that it binds inside
  `match` bodies — reimplementing splicing-with-ellipsis as a nested macro
  is itself close to reimplementing a template facility from scratch, and
  was cut for scope.
- **Restrict ellipsis-repeated sub-patterns** to plain `,var`, `,_`, and a
  single hand-added case for repeated default-cata `,(var)` (needed because
  the SRFI's own canonical example, `(+ ,[x*] ...)`, uses exactly that
  shape) — arbitrary compound patterns under an ellipsis are unsupported,
  because collecting "which identifiers does this arbitrary sub-pattern
  bind" generically is itself the kind of problem real code, not a
  template, solves naturally.
- **Drop vector patterns with a mixed mandatory prefix/suffix around an
  ellipsis** — only whole-vector-ellipsis and fixed-length are supported.

None of this is a Kaappi implementation bug — every workaround is a
standard, independently-documented `syntax-rules` idiom (the custom-ellipsis
trick, the peel-the-last-element idiom used again in SRFI 202's general
multi-pattern `and-let*` claw, a CPS-style "pass the continuation as another
macro argument" style used throughout both libraries to avoid combinatorial
code blowup). But five macros' worth of these idioms, in two SRFIs, is a
strong signal: this is a recurring cost, not a one-off.

SRFI 202's own reference implementation description says outright: "The
reference implementation is a `syntax-case` macro matching on claw shape,
using `match`... for destructuring" — i.e. the SRFI's own authors built it
on exactly the two facilities (`syntax-case`, and a `match` that assumes
`syntax-case`) that Kaappi does not have.

### Why explicit-renaming specifically

`syntax-case` is the standard-track answer (see KEP-0007), but it needs a
persistent syntax-object representation and, most likely, a from-scratch
hygiene rewrite — high cost, and the spec it would target is still moving
(target 2028). Explicit-renaming macros solve the *same* immediate problem —
"a macro transformer needs to be real code, not a template" — with a much
smaller mechanism that, as the Reference-level design below shows, reuses
rather than replaces most of Kaappi's existing hygiene machinery. The
R7RS-large committee's own discussion (cited in KEP-0007) independently
weighs explicit-renaming and syntactic closures as "older, simpler, and
more in the spirit of Scheme" than `syntax-case`, while noting neither gives
as clean an answer to *deliberately* breaking hygiene — a tradeoff this KEP
makes deliberately, see Alternatives considered.

### Prior art

Explicit renaming is well-trodden ground — new to Kaappi, not to Scheme.
William Clinger introduced it (*"Hygienic Macros Through Explicit
Renaming,"* Lisp Pointers IV(4), 1991) as a deliberately small **procedural
interface over the hygiene algorithm of "Macros That Work"** (Clinger &
Rees, POPL 1991) — the same family of pattern-plus-hygiene algorithm
Kaappi's `matchPattern`/`renameForHygiene` already implement. `rename` and
`compare` are essentially the two primitives that algorithm needs
internally, which is the historical grounding for this KEP's claim that
they are a *procedure wrapper around existing machinery, not new mechanism*.
ER is the middle of three low-level systems — syntactic closures (Bawden &
Rees, 1988) and `syntax-case` (Dybvig, Hieb & Bruggeman, 1992) are the
others — whose relative expressiveness is still a genuinely open question,
so adopting ER is not settling for a weaker `syntax-case`, only choosing a
different point in the design space (see KEP-0007).

The `(form rename compare)` convention has broad precedent: MIT/GNU Scheme
(which implements ER *atop* its syntactic-closures layer), CHICKEN (which
later added the implicit-renaming inverse `ir-macro-transformer` in 4.7),
Gauche, Larceny, Sagittarius, Picrin, and — most directly relevant —
**Chibi Scheme, which implements `syntax-rules` itself on top of
`er-macro-transformer`**, a real-world instance of exactly the layering
this KEP proposes. SRFI 211 (Nieper-Wißkirchen, finalized 2022) already
standardizes a portable library namespace and `cond-expand` feature for
`er-macro-transformer` and its siblings, so the feature identifier in
Implementation-plan step 6 has a conventional name to adopt rather than one
to invent.

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

What the same fragment looks like as an explicit-renaming macro — real
Scheme code, no pattern-matching indirection needed to ask "is the second
element the ellipsis symbol?":

```scheme
(define-syntax match
  (er-macro-transformer
    (lambda (form rename compare)
      (let ((clauses (cdr form)))
        ;; ordinary list processing: split wherever the ellipsis symbol
        ;; occurs, build the expansion with ordinary helper procedures.
        (expand-match-clauses (rename 'let) clauses rename compare)))))
```

A second, classic example (Chicken's tutorial `swap!`) shows the shape for
a small, everyday macro — no template at all, just list destructuring:

```scheme
(define-syntax swap!
  (er-macro-transformer
    (lambda (form rename compare)
      (let ((x (cadr form)) (y (caddr form)))
        `(,(rename 'let) ((,(rename 'tmp) ,x))
           (,(rename 'set!) ,x ,y)
           (,(rename 'set!) ,y ,(rename 'tmp)))))))
```

## Reference-level design

### The prerequisite: compile-time procedure execution

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
must, for `(er-macro-transformer expr)`, **compile and execute** `expr` (an
ordinary `lambda`) *before* continuing to compile the rest of the program,
to obtain a closure value — and then, at every *use* site of that macro,
`compiler_macro.zig`'s macro-invocation dispatch must **call that closure
via the VM** (`vm_calls.callValue` or equivalent) and use its return value
as the form to keep expanding, instead of calling `expandMacro`.

This is a real, new capability — reentrant VM execution nested inside
`compile()` — with consequences the current pipeline doesn't need to
consider:

- **GC rooting across the reentrant call.** Every in-flight IR/AST node
  being compiled around the macro use must stay rooted across a full
  `vm.execute()` call, which itself allocates and can collect.
  `.claude/rules/gc-safety.md`'s "root `Function*` before `vm.execute()`"
  rule generalizes to "root the entire partially-built form."
- **Error handling.** A transformer procedure can raise a normal Scheme
  error (wrong type, unbound variable in a buggy macro). That has to
  surface as a *compile* error with a source location pointing at the
  macro use, not as an uncaught runtime exception three layers into the
  expander.
- **`kaappi check` / `--sandbox` interaction — the sharpest finding here.**
  `kaappi check` is documented (`docs/dev/check.md`) as compile-only: it
  "reads, macro-expands, and compiles every top-level form ... but executes
  no *program* code." That promise is airtight *today* specifically because
  expansion is pure Zig with no VM calls. The instant a transformer is a
  called procedure, `kaappi check`-ing a file that defines one **does
  execute Scheme code** — the transformer body — even though the check still
  never executes the *program's* top-level code. The doc's own "no *program*
  code" wording already draws exactly this compile-time-vs-program line, but
  whether running transformer bodies under `check` is an acceptable,
  clearly-documented carve-out or something `--sandbox` needs to additionally
  gate is a real design decision — see Unresolved questions.
- **WASM / native-compile backend.** Both `zig build wasm` and `kaappi
  compile`'s LLVM backend share the same front-end pipeline through
  expansion, so this has to work identically there. Mechanically low-risk
  (the WASM build already runs the same interpreter loop single-threaded)
  but should be verified with an actual cross-compiled `kaappi.wasm` once
  there's running code, not assumed.

### `rename`: mostly a reuse of `renameForHygiene`

`rename` must be *referentially transparent* — the same input symbol,
called twice within one macro expansion, must return `eqv?` results (Chibi
achieves this with a per-expansion `renames` alist built fresh on each
macro use). Kaappi already has the equivalent mechanism:
`renameForHygiene` (`expander.zig:1195`) plus `freshScope()`
(`expander.zig:71`, called once per `expandMacro` invocation) plus the
`scope_table` dedup cache give exactly "same name, same gensym, within one
invocation; different gensym across invocations" today, for
`syntax-rules` templates.

Concretely:

- At the point `compiler_macro.zig` calls the stored closure for an
  `.explicit_renaming` transformer, it calls `freshScope()` once (mirroring
  what `expandMacro` does today) to get an invocation-scoped id.
- `rename` becomes a native closure over that scope id, calling a
  **simplified** `renameForHygiene` — simplified because the
  `BINDING_FLAG`/`LET_PAIR_FLAG`/`NESTED_SR_FLAG`/`QQ_DEPTH_MASK` machinery
  in the current code exists specifically so the expander can *guess* which
  identifiers in a static template are binding positions vs. references
  vs. quoted data. An explicit-renaming macro doesn't need any of that
  guessing: the macro author calls `(rename 'tmp)` exactly where a fresh
  identifier is wanted, and doesn't call it where deliberate capture is
  wanted (the classic `loop`/`exit` hygiene-breaking idiom, where the
  macro's `exit` must resolve to a binding the *caller's* macro
  introduces — precisely the kind of case the current template-walker's
  flag soup exists to approximate statically, and which explicit-renaming
  sidesteps by putting the decision in the macro author's hands directly).
  This is the concrete reason this KEP's mechanism is cheaper than it might
  look: it needs a *procedure wrapper* around existing gensym/scope
  machinery, not a redesign of it.
- Well-known forms (`isWellKnown`, `expander.zig:55`) should short-circuit
  `rename` to return the name unchanged, matching what `instantiateTemplate`
  already does for `syntax-rules` (rule 3 in its symbol-handling branch) —
  no reason to gensym `if`/`let`/`else`.

### `compare`: mostly a reuse of the literal-matching logic in `matchPattern`

The R7RS 4.3.2 rule — "match only if both identifiers refer to the same
binding, or both are unbound" — is already implemented, in `matchPattern`'s
symbol-literal branch (`expander.zig:290`–`301`), using `literal_bound`
(definition-site binding slot) and `use_check.resolve` (use-site binding
slot, via a callback the compiler already provides). `compare(a, b)` needs
the same shape of answer for two arbitrary identifiers instead of one
pattern literal against one input symbol:

- If both are unrenamed (no `__hyg_N_` prefix) and textually equal, resolve
  both via `use_check` at their respective sites and apply the existing
  "both unbound, or same binding slot" rule.
- If one is a rename produced by `rename`, the `scope_table` entry already
  records its `original_name` (`expander.zig:84`) — a reverse lookup
  recovers the name whose binding status needs checking, rather than
  inventing a new representation for it.

This is the same machinery, exposed a second way — not new logic designed
from scratch. It's also, honestly, an approximation relative to Chibi's
`identifier=?` (which compares against full lexical environments); it needs
enough real-world exercise against Kaappi's own library ecosystem to know
whether the approximation holds up — see Unresolved question 2.

### Surface changes

1. **`types.Transformer` grows a `kind` tag** (`.syntax_rules` |
   `.explicit_renaming`), or becomes a tagged union with the existing fields
   under `.syntax_rules`. The `.explicit_renaming` variant holds a single
   `Value` — the transformer closure.
2. **`compiler_macro.zig` recognizes `(er-macro-transformer expr)`** as a
   sibling production to `(syntax-rules ...)` wherever the latter is
   recognized today, compiles and executes `expr` to a closure (see
   prerequisite above), and stores it as an `.explicit_renaming`
   transformer.
3. **Macro-use dispatch branches on `kind`.** For `.explicit_renaming`, call
   the stored closure with `(form rename compare)` — `form` unwrapped the
   same way `expandMacro` does today, or the whole use-form including the
   keyword (Chibi's convention); picking one is Unresolved question 1. The
   closure's return value becomes the expansion, fed into the same
   downstream pipeline `expandMacro`'s result feeds today.
4. **No new heap type, no phase separation, no `syntax->datum`/
   `datum->syntax`.** The transformer operates on plain data in, plain data
   out — the same representation `syntax-rules` templates already produce.

Estimated blast radius, from a direct count against `7949e497`:
`Transformer` is consumed across **nine** files. Seven treat it as a
`syntax-rules` rule set — reading `patterns`/`templates`/`num_rules`/
`literal_bound`, capturing locals onto it, or naming its type — and each
needs a `switch` on the new `kind` tag or an early return for the
non-`syntax_rules` case: `compiler_lambda.zig`, `compiler_macro.zig`,
`expander.zig`, `gc_deep_copy.zig`, `tests_deepcopy.zig`, `types.zig`, and
`vm_library.zig` (library-body macros). The other two are the GC files, and
they are the load-bearing ones: `memory.zig` needs an `allocTransformer`
sibling that stores the closure `Value`, and `gc_collect.zig` handles the
`.transformer` heap tag in five arms — `referencesYoung` (the generational
write barrier), `markObjectContents` and `markValueInner` (marking),
`objectSize`, and `freeObject`. The two marking arms and the barrier are a
**GC-safety correctness obligation, not mechanical plumbing**: the
`.explicit_renaming` variant's closure `Value` must be traced there, or the
collector frees a closure a live macro still references — a use-after-free.
That is a second, distinct GC hazard on top of the reentrant-execution
rooting flagged in the prerequisite section above.

### Scope: which transformer kinds

SRFI 211 gives portable names to a whole family of procedural transformers
(`er-`, `ir-`, `sc-`, `rsc-macro-transformer`, and more), but that is a
namespace registry, not a shopping list — an implementation provides the
subset it supports and advertises each via `cond-expand`. This KEP
deliberately proposes **one** primitive and derives at most one convenience
from it:

- **`er-macro-transformer` — the primitive (this KEP).** Everything above
  builds it as a wrapper over existing hygiene machinery.
- **`ir-macro-transformer` (implicit renaming) — in scope as a cheap
  follow-on, not a separate KEP.** It is `er` with the hygiene default
  inverted: rename every identifier by default, and let the author mark the
  few that should leak to the use site. CHICKEN implements it as a thin
  library over `er`, and Kaappi can do the same — no new core mechanism, no
  new entry in the blast radius above. Because it inherits every hard
  decision from this KEP (reentrant execution, GC rooting, the
  `check`/`--sandbox` policy) and has a strict build-order dependency on
  `er`, it should ship as an ordinary PR against `kaappi` core — a Scheme
  library plus a `cond-expand` feature (`ir-macro-transformer`) and tests,
  referencing this KEP — added when a concrete macro wants the nicer
  default, not speculatively. Only if implementing it turned out to need
  core changes beyond what `er` provides would it warrant an *amendment* to
  this KEP, still not a document of its own.
- **`sc-` / `rsc-macro-transformer` (syntactic closures) — out of scope.**
  These expose first-class *syntactic environments* and
  `make-syntactic-closure`, a different abstraction than `rename`/`compare`,
  for negligible expressiveness beyond `er`/`ir` and little real-world code
  that depends on them today. Adding them would be parity for its own sake.
  Revisit only on a concrete need (e.g. porting MIT/GNU Scheme macro code),
  or let them fall out as thin veneers if full `syntax-case` (KEP-0007) is
  ever built.

The governing principle is *one hygiene substrate, derive the rest*: `er`
here, `ir` as a library over it if wanted, and nothing that introduces a
second, parallel mechanism to maintain.

## Drawbacks

- **Two macro systems to maintain and document**: `syntax-rules` (fast,
  template-only, what the whole existing library ecosystem uses) and
  `er-macro-transformer` (procedural, for the cases `syntax-rules` genuinely
  cannot express). Every future contributor needs to know which to reach
  for.
- **Not standard.** Code written against Kaappi's `er-macro-transformer` is
  not portable to implementations that lack it — though the mechanism
  itself (not the exact calling convention) is precedented enough across
  existing Schemes that porting *to* Kaappi from one of them is usually
  mechanical.
- **The reentrant-VM-during-compile capability is new load-bearing
  machinery**, and its interaction with `kaappi check`/`--sandbox` needs a
  real answer, not silence — shipping this without settling that is a
  security-relevant gap.
- **`compare`'s approximation may not hold in all cases** — it reuses
  binding-slot comparison rather than full lexical-environment comparison;
  real usage may surface gaps the existing `syntax-rules` literal-matching
  logic never had to handle because it only ever compared one pattern
  literal against one input symbol, never two arbitrary computed
  identifiers.

## Alternatives considered

- **Do nothing; keep documenting per-library workarounds.** What this
  session actually did for SRFI 241/202. Zero implementation risk, but the
  idioms this KEP's Motivation catalogs are exactly the kind of hard-won
  tribal knowledge that either needs a durable macro-writing guide in
  `docs/dev/` (a much smaller, immediately actionable alternative to this
  whole KEP) or gets replaced by this proposal. Recorded here as the honest
  zero-cost baseline everything else is measured against.
- **Full `syntax-case` instead.** See KEP-0007 — deferred, both because the
  target spec (R7RS-large) isn't finalized until 2028 and because the
  implementation cost (syntax-object type, likely reimplementing
  `syntax-rules` on top, possible phase separation) is categorically larger
  than this proposal for solving the same immediate problem.
- **Syntactic closures** (pass an explicit *environment* rather than a
  rename/compare pair) — older than explicit-renaming, similarly
  non-standard for R7RS-large's eventual answer, no clearer implementation
  cost advantage identified over the rename/compare design here. Not
  pursued further for lack of a concrete reason to prefer it.
- **SRFI 148 (eager syntax-rules).** Its own reference implementation is
  pure `syntax-rules`, so it adds no expressive power beyond what
  `syntax-rules` already has — confirmed independently while researching
  this KEP. It would not have helped SRFI 241 or 202 and is not an
  alternative to this proposal.
- **SRFI 149 (Basic Syntax-rules Template Extensions)** — a different,
  much narrower SRFI that just relaxes two `syntax-rules` *template*
  validity restrictions (multiple consecutive ellipses; pattern variables
  followed by more ellipses in the template than in the pattern). Its
  entire implementation is "re-export `syntax-rules`." Unrelated to the
  problem this KEP addresses — worth a separate, small look some time
  (`instantiateEllipsis`, `expander.zig:1048`–`1062`, already flattens
  consecutive ellipsis tokens for depth-2 bindings, so Kaappi may already
  be close to SRFI 149-compliant), but not a substitute for this proposal.

## Cross-platform / compatibility impact

- **WASM (`zig build wasm`):** Should work identically in principle (see
  Reference-level design's prerequisite section) but is unverified until
  there's running code; must be exercised with a real transformer-defining
  `.scm` file before this is called done, not assumed safe from the
  existing atomics precedent alone.
- **Native compile backend (`kaappi compile`, LLVM):** Macro expansion
  happens before IR lowering for both interpreted and native-compiled
  programs, so this is a front-end change only — no LLVM-emission changes
  expected. Should still be smoke-tested through `kaappi compile` once
  implemented, since its own test suite (`tests/scheme/compile/`) exercises
  real programs, not just the interpreter path.
- **`kaappi check` / `--sandbox`:** Genuinely affected, as detailed above —
  the one item here that is a compatibility/security question, not just an
  implementation one, and needs an explicit decision before shipping.
- **`--sandbox`'s capability model specifically:** if transformers can run
  arbitrary code, a sandboxed program that merely *defines* (but never
  calls) a malicious macro could still execute its transformer body the
  moment another part of the same file uses that macro during compilation —
  i.e. before the sandbox's runtime restrictions would otherwise apply to
  the program's own execution. This needs to be resolved by design, not
  discovered by a security report.
- **Existing `syntax-rules` behavior:** This KEP adds a new transformer kind
  alongside the existing one and should not change `syntax-rules` semantics
  at all — the full `tests/scheme/hygiene/` and `src/tests_macros.zig`
  suites should stay green with zero modifications, as an explicit
  acceptance criterion.

## Unresolved questions

1. **What exactly does the transformer procedure receive?** The whole
   macro use-form including the keyword (Chibi's convention) or just the
   arguments (`expandMacro`'s current convention, stripping the keyword via
   `types.cdr(expr)`)? Picking Chibi's whole-form convention makes porting
   existing `er-macro-transformer` libraries more direct.
2. **Does `compare` need definition-site environment awareness, or is the
   binding-slot approximation sufficient** for the cases Kaappi's own
   library ecosystem would actually exercise? Worth a spike (re-porting a
   macro like `cond`-with-`else`/`=>` under this mechanism) before
   committing to the API.
3. **`kaappi check`/`--sandbox` policy, precisely.** Candidate answers: (a)
   transformer bodies always run under `check`/`--sandbox`, documented as
   "macro-defining code is compile-time code, not sandboxed program code";
   (b) transformer bodies run under the *same* sandbox restrictions as the
   rest of the file; (c) `check` refuses to fully expand files that define
   `.explicit_renaming` transformers and reports a diagnostic instead. No
   candidate has been evaluated against `docs/dev/check.md`'s existing
   guarantees in enough depth to recommend one yet.
4. **Does Kaappi's own SRFI-porting style actually prefer this once it
   exists**, or do contributors keep reaching for `syntax-rules`-plus-idioms
   out of habit? Only observable after this ships and a few more
   pattern-matcher-shaped SRFIs get ported with it available.
5. **Should the naming (`er-macro-transformer`) match Chibi Scheme's
   exactly**, to maximize direct portability of existing libraries written
   against it, or diverge where Kaappi's calling convention differs for a
   good reason? Leans toward matching unless a concrete reason not to
   surfaces during implementation.

## Implementation plan

Phased so the highest-risk, most architecturally novel piece (reentrant
compile-time execution) is proven in isolation before the macro-facing API
is built on top of it, and so the `check`/`--sandbox` question (Unresolved
question 3) is settled by design before it can be a security incident.

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
3. **`types.Transformer` gains its `kind` tag**; audit and update every
   call site across the nine files listed in Reference-level design to
   handle both kinds, with the `.syntax_rules` path byte-for-byte unchanged
   in behavior — verified by the existing hygiene/macro test suites passing
   with zero modifications. Include `gc_collect.zig`'s marking arms in this
   audit: tracing the new closure `Value` is a correctness requirement, not
   optional cleanup, and is the easiest thing to forget.
4. **`er-macro-transformer` special form + `rename`/`compare`
   implementation**, reusing `renameForHygiene` and the literal-matching
   logic identified in Reference-level design rather than rebuilding either.
5. **Re-port SRFI 241 and/or SRFI 202** on top of this as the acceptance
   test for the whole feature — if the ellipsis-aware quasiquote, compound
   ellipsis sub-patterns, and mixed vector prefix/suffix limitations
   documented in `lib/srfi/241.sld`'s header can now be lifted, that is the
   concrete, falsifiable signal that this delivered what the KEP set out to
   fix. If they can't be lifted cleanly, that is equally valuable signal
   that the design needs another iteration before wider use.
6. **Document as a Kaappi extension**, in the same spirit as KEP-0004: a
   `cond-expand` feature identifier (e.g. `kaappi-er-macros`) and a
   kaappi-lang.org page stating plainly that this is beyond R7RS-small and
   is *not* R7RS-large's eventual `syntax-case` (see KEP-0007).

## Sources

- [Mini-tutorial on explicit (and implicit) renaming macros — CHICKEN wiki](https://wiki.call-cc.org/explicit-renaming-macros)
- [Explicit Renaming — MIT/GNU Scheme Reference](https://www.gnu.org/software/mit-scheme/documentation/stable/mit-scheme-ref/Explicit-Renaming.html)
- [chibi-scheme `init-7.scm` (er-macro-transformer, make-renamer, cond)](https://github.com/ashinn/chibi-scheme/blob/master/lib/init-7.scm)
- [Precise definition of er-macro-transformer — chibi-scheme mailing list](https://groups.google.com/g/chibi-scheme/c/2i3R4vwicp8/m/8IG640naKgAJ)
- [SRFI 149: Basic Syntax-rules Template Extensions](https://srfi.schemers.org/srfi-149/srfi-149.html)
- [SRFI 211: Scheme Macro Libraries](https://srfi.schemers.org/srfi-211/srfi-211.html) — portable namespaces and `cond-expand` features for `er-macro-transformer` and its siblings (Nieper-Wißkirchen, finalized 2022)
- [Syntax definitions — Scheme Surveys](https://docs.scheme.org/surveys/syntax-definitions/) — which implementations support explicit renaming
- William D. Clinger, "Hygienic Macros Through Explicit Renaming," *Lisp Pointers* IV(4):25–28, 1991 — the original ER paper
- William D. Clinger & Jonathan Rees, "Macros That Work," *POPL* 1991 — the pattern-plus-hygiene algorithm ER exposes as `rename`/`compare`
- Alan Bawden & Jonathan Rees, "Syntactic Closures," *ACM Conf. on LISP and Functional Programming*, 1988 — the sibling low-level system ER simplifies
- R. Kent Dybvig, Robert Hieb & Carl Bruggeman, "Syntactic Abstraction in Scheme," *Lisp and Symbolic Computation* 5(4), 1992 — `syntax-case` (see KEP-0007)
