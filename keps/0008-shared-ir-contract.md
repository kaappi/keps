# KEP-0008: A Shared IR Contract for kaappi, paal, and chaaya

| Field | Value |
|-------|-------|
| **KEP** | 0008 |
| **Title** | A Shared IR Contract for kaappi, paal, and chaaya |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (`src/ir.zig`), `paal` (`lib/kaappi/paal/ir.sld`, `lib/kaappi/paal/compiler.sld`), `chaaya` (`include/chaaya/ir.h`, `src/ir_opt.c`, `src/ir_analyze.c`) |
| **Created** | 2026-08-02 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `e43f0f5b` (main,
2026-08-01), paal commit `7bc8919` (main, 2026-08-01), and chaaya commit
`429f407` (main, 2026-08-01), and were verified directly against that
source — not just each repo's own `ir.md` / `docs/dev/ir.md` — as of
2026-08-02.*

## Summary

kaappi (Zig), paal (self-hosted Kaappi Scheme), and chaaya (C) each
implement an independent compiler intermediate representation for the same
language, R7RS-small. None were designed together. Comparing their
`ir.md`/`docs/dev/ir.md` documents, then verifying directly against
source, shows the three have already converged — without coordination —
on the same core-form set, the same five peephole optimizations, and the
same primitive-shadowing safety principle. This KEP writes that
convergence down as an explicit contract: a shared reference the three
repos are expected to stay consistent with going forward. It does **not**
propose merging the three IRs into one implementation, one language, or
one runtime.

## Motivation

Right now there is no shared reference for what a Kaappi-family compiler
IR is supposed to guarantee, so each implementation's IR design is a
private judgment call. That already produced a real, if harmless, gap:
chaaya's `docs/dev/ir.md` documents an explicit "Safety gates" section for
its constant-folding optimizer, but kaappi's `docs/dev/ir.md` says nothing
about the equivalent guard — even though kaappi's code has one
(`ir.isRedefined()`, see Reference-level design). A future contributor
reading only kaappi's doc would not know this invariant exists, and a
future contributor changing chaaya's fold rules would have no way to know
whether kaappi and paal need the same change, or why paal doesn't.

Nothing today would catch a real behavioral divergence — e.g. one repo's
`(- x 0)` identity elimination changing shape, or a future primitive being
added to one repo's fold list without the others being told it exists as
a candidate. A written contract turns "the three happen to agree" into
"the three are checked against the same rules."

## Guide-level explanation

Anyone adding or modifying an IR node type, an optimization pass, or a
tail-position rule in kaappi, paal, or chaaya should check this KEP first.

### Canonical core-form table

| Canonical form | kaappi (`NodeTag`) | paal (tagged-list symbol) | chaaya (`ChIrKind`) |
|---|---|---|---|
| Literal/constant | `.constant` | `'const` | `CH_IR_LITERAL` |
| Variable reference | `.global_ref` | `'ref` | `CH_IR_VAR` |
| If | `.if` | `'if` | `CH_IR_IF` |
| Sequence | `.begin` | `'begin` | `CH_IR_SEQ` |
| Lambda | `.lambda` | `'lambda` | `CH_IR_LAMBDA` |
| Call | `.call` | `'call` | `CH_IR_CALL` |
| Set! | `.set_form` | `'set!` | `CH_IR_SET` |
| Define | `.define` | `'define` | `CH_IR_DEFINE` |
| And | `.and_form` | *(none — desugars before the IR)* | `CH_IR_AND` |
| Or | `.or_form` | *(none — desugars before the IR)* | `CH_IR_OR` |

Notes:

- kaappi additionally has structured `when_form`/`unless_form` tags; paal
  and chaaya treat `when`/`unless` as fully derived syntax with no IR node
  of their own. This is an **accepted deviation**, not a defect — kaappi's
  choice to keep them structured predates this KEP and isn't required
  elsewhere.
- paal has no `and`/`or` nodes at all — its expander desugars them away
  before the analyzer ever runs. Also an accepted deviation.
- chaaya splits `quote` into its own `CH_IR_QUOTE` kind and known
  arithmetic/comparison calls into `CH_IR_PRIM_CALL`, where kaappi and paal
  fold both into their ordinary `constant`/`const` and `call`/`'call`
  nodes respectively. `CH_IR_PRIM_CALL` is an optimization-targeting tag,
  not a different call semantics — it emits back to an ordinary call.

### Escape-hatch principle

Derived syntax (`let`, `cond`, `case`, `do`, quasiquote, `guard`,
`define-record-type`, …) must never get a first-class IR node of its own.
Each repo picks one of two strategies:

- **Fully desugar before the IR** (paal): the expander reduces everything
  to the core-form table above; the analyzer never sees derived syntax.
- **Delegate untouched to the existing special-form compiler** (kaappi's
  `sexpr_form` tag + `passthrough` fallback; chaaya's `CH_IR_RAW`): the
  node carries the original, unlowered form and is handed to legacy
  compilation logic rather than being modeled structurally.

A new derived form must not be given a dedicated node tag in any of the
three without amending this KEP first.

### Optimization contract

All optimizations are applied only when semantically safe (see the Safety
invariant below) and are all no-ops when they don't apply — none of them
may change behavior when their precondition doesn't hold.

| Optimization | Rule |
|---|---|
| Constant fold | Evaluate a call to a known arithmetic/comparison primitive when all arguments are constant; skip on fixnum overflow |
| Dead-branch elimination | `(if #t A B)` → `A`; `(if #f A B)` → `B`; `(if #f A)` → unspecified |
| Boolean simplification | `(not (not X))` → `X`; `(if (not X) A B)` → `(if X B A)` |
| Identity elimination | `(+ x 0)`/`(+ 0 x)` → `x`; `(* x 1)`/`(* 1 x)` → `x`; `(* x 0)`/`(* 0 x)` → `0`; `(- x 0)` → `x` |
| Sequence flattening | `(begin X)` → `X`; nested/singleton sequences collapse |

kaappi and chaaya both implement all five. **paal implements none of
them** — its analyzer is purely structural, by design, so that a
paal-compiled copy of itself stays simple enough to bootstrap. This is
documented non-conformance by choice, not a gap to close.

### Tail-position table

Regardless of *how* each backend tracks it (see Reference-level design),
the following must hold everywhere:

| Form | Non-tail positions | Tail position(s) |
|---|---|---|
| `if` | test | consequent, alternate |
| `begin`/sequence | all but the last | last expression |
| `and`/`or` | all but the last | last expression |
| `lambda` | — | body (always) |
| `call` | operator, all arguments | *(none — a call is never itself in tail position of its own subexpressions)* |
| `set!`/`define` | value expression | — |

## Reference-level design

### Safety invariant

Any implementation that folds or rewrites a call to a named primitive
**must** first confirm the name still refers to that primitive and hasn't
been shadowed by user code — otherwise `(define (+ a b) 'user-plus) (+ 1 2)`
would silently fold to `3` instead of calling the user's procedure.

- **kaappi**: `ir.isRedefined(name)` (`src/ir.zig`) is checked in
  `foldConstants` (line 1144), the identity-elimination path (line 984),
  and the boolean-simplification `not` check (line 1296). Lexical
  shadowing (e.g. a lambda parameter named `+`) is handled earlier, at
  lowering time: a name only lowers to a `.global_ref` node if lowering
  has already determined it isn't locally bound, so `foldConstants`
  — which only fires when the call operator is a `.global_ref`
  (`src/ir.zig:1140`) — never sees a shadowed local in the first place.
  kaappi therefore needs no separate lambda-depth gate.
- **chaaya**: `src/ir_opt.c` builds a `prim_disabled[]` table
  (`ChIrOptCtx`, lines 7–10) via two checks — `vm_binding_is_builtin_primitive`
  (lines 92–112, catches VM-level global shadowing) and
  `collect_redefinitions` (lines 150–213, catches top-level `define`/
  `set!`, including inside unlowered `CH_IR_RAW` forms) — plus an
  additional `lambda_depth > 0` gate (lines 637–639, 583) that disables
  constant-folding and identity-simplification (but *not* dead-branch
  elimination or sequence flattening) for any primitive call nested inside
  a lambda, as an extra conservative margin.
- **paal**: not applicable — paal has no optimizer to guard.

kaappi's and chaaya's mechanisms are believed to provide an equivalent
guarantee by different means (structural lexical resolution vs. an
explicit depth counter), but this has not been proven with an adversarial
test in either repo. See Unresolved questions.

### Per-repo file map

| Repo | IR definition | Optimizer/analysis |
|---|---|---|
| kaappi | `src/ir.zig` | `foldConstants`, `eliminateDeadBranches`, `simplifyBooleans`, `eliminateIdentity`, `simplifyBegin` (all in `src/ir.zig`); tail marking via `markTailPositions` |
| paal | `lib/kaappi/paal/ir.sld` | none (`lib/kaappi/paal/compiler.sld`'s `paal-analyze` is purely structural) |
| chaaya | `include/chaaya/ir.h` | `src/ir_opt.c` (`ch_ir_optimize`), `src/ir_analyze.c` (`ch_ir_analyze`) |

## Drawbacks

- This contract is advisory only; nothing enforces it automatically today,
  across three different test harnesses (`zig build test`, `make test`,
  `ctest`). It can drift out of date the same way the doc gap it was
  written to fix did.
- One more document to keep in sync as any of the three IRs evolves.
- paal's near-total non-conformance on the optimization contract could be
  misread as "the contract doesn't really apply to paal" — worth stating
  plainly (as above) that it's an intentional, permanent exception rather
  than a TODO.

## Alternatives considered

1. **A shared/common runtime IR across all three.** Rejected: kaappi
   (Zig), paal (Scheme), and chaaya (C) have incompatible runtime
   representations (NaN-boxed tagged union, cons-cell tagged lists, and
   `calloc`'d structs with `ChValue` fields respectively) and different GC
   models, and paal's entire design goal is staying small enough to
   self-host — taking on a shared cross-language IR dependency would work
   directly against that.
2. **Transpile each IR into a fourth common IR** (e.g. as a differential-
   testing oracle across the three front ends). Plausible future work, but
   only pays off once there's a real consumer for the common shape. Today,
   kaappi's `sexpr_form`/`passthrough` and chaaya's `CH_IR_RAW` escape
   hatches mean a naive transpile would mostly re-export raw, unlowered
   syntax rather than real structure for most derived forms — front-end
   lowering coverage would need to improve first for this to be worth the
   engineering cost.
3. **Adopt MLIR as a shared dialect.** Rejected: MLIR's dialect-based,
   multi-level progressive-lowering model is built for heterogeneous
   hardware/ML/HLS-scale problems, not for peephole-scale tree
   optimizations over a small Scheme core-form set. It also does not solve
   garbage collection itself — GC integration is punted to LLVM's
   statepoint intrinsics, and the current prior art (Pylir, Serene) is all
   single-frontend, not a merge point for three pre-existing IRs. It would
   be a defensible individual choice for chaaya's own not-yet-built native
   backend, but does not solve the cross-repo consistency problem this KEP
   addresses.
4. **Do nothing.** Rejected: this already produced one confirmed,
   silent documentation gap (kaappi's undocumented `isRedefined` guard),
   with no mechanism to catch the next one, or an actual behavioral
   divergence, before it ships.

## Cross-platform / compatibility impact

None. This KEP proposes a documentation/contract artifact only — no
runtime, compiler, or IR behavior changes. The one code-adjacent change is
a documentation fix to kaappi's `docs/dev/ir.md` describing an
already-existing guard (`ir.isRedefined()`); it does not alter behavior.

## Unresolved questions

1. Should this contract eventually be enforced by automated conformance
   checks rather than staying advisory-only, given the three repos use
   three different test harnesses (`zig build test`, `make test`, `ctest`)?
   If so, what would a check even assert, given the IRs are structurally
   different by design?
2. Should derived-form desugaring equivalence become a v2 section of this
   KEP — e.g. does named-`let` reduce to the same conceptual shape in all
   three, does `cond`/`case`/`do` agree? This needs its own per-repo
   verification pass and was deliberately left out of this version's scope.
3. Is kaappi's lowering-time lexical-shadowing defense actually equivalent
   in strength to chaaya's explicit `lambda_depth` gate? This KEP states
   them as believed-equivalent by different mechanisms, but neither repo
   has an adversarial test (e.g. a lambda parameter literally named `+`
   whose body also calls the shadowed name) confirming it.

## Implementation plan

1. Merge this KEP as `Draft`; add it to `keps/README.md`'s `## Index` table.
2. Once `Accepted`: add a short "See also" pointer near the top of
   `kaappi/docs/dev/ir.md`, `paal/docs/ir.md`, and `chaaya/docs/dev/ir.md`,
   linking back to this KEP.
3. Fix the concrete documentation gap this KEP's research surfaced: add a
   line to kaappi's `docs/dev/ir.md` "Optimization Passes" section
   documenting the `ir.isRedefined()` guard.
4. Leave the three Unresolved questions above as follow-up work, not
   blockers to accepting this KEP in its initial form.
