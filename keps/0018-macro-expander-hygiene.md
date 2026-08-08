# KEP-0018: The Macro Expander — Expansion Algorithm and Hygiene Mechanism

| Field | Value |
|-------|-------|
| **KEP** | 0018 |
| **Title** | The Macro Expander — Expansion Algorithm and Hygiene Mechanism |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/expander.zig`, `src/expander_instantiate.zig`, `src/compiler_macro.zig`, `src/compiler_define_syntax.zig`, `src/types_macro.zig`, `src/types.zig`, `src/ir.zig`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. `docs/dev/architecture.md`
describes the expander in one row; there is no dedicated expander/hygiene
dev-doc. This KEP records a source-verified fact that post-dates
[KEP-0006](0006-explicit-renaming-macros.md) and
[KEP-0007](0007-full-syntax-case-support.md): procedural transformers are
now shipped (as SRFI 211, v0.22.0) — see the scope note.*

## Scope

This KEP specifies the **expansion algorithm and the hygiene mechanism** —
the internal machinery of `src/expander.zig` and its siblings — and
deliberately defers the *user-facing transformer surfaces* to the KEPs that
own them:

- **KEP-0006 / SRFI 211** owns the `er-macro-transformer` /
  `lisp-transformer` user contract (the `(form rename compare)` interface,
  the library packaging, the `--sandbox`/`check` policy). This KEP records
  only what the expander *internally provides* to that surface:
  `expandProceduralMacro` and the native `rename`/`compare` closures it
  builds.
- **KEP-0007** owns `syntax-case`, syntax objects, `datum->syntax`, and
  phasing — none of which are implemented. This KEP explains *why* the
  current identifier representation cannot support them.
- **KEP-0005** owns the diagnostic code taxonomy (`KP2xxx`). This KEP records
  only the expander's error *conditions*, not their diagnostic shape.

In scope: the pipeline placement, the gensym-rename hygiene engine, the
`syntax-rules` pattern/template engine, the identifier representation, the
expansion-depth/chain/fixpoint machinery, the special-form boundary and
`define-syntax` registration, and the library def-env plumbing.

### A correction the source forces

KEP-0006 and KEP-0007 (both Draft, 2026-07-21) describe procedural
transformers as *unbuilt future work* — KEP-0006's "prerequisite" section
claims `expandMacro` "never calls into the VM" and `types.Transformer` has
"no 'kind' tag, no procedure-value field." **Both are now false in-tree.**
`types_macro.zig:18` defines `TransformerKind = enum { syntax_rules,
er_macro, lisp_macro }`; the transformer carries `kind` and `proc: Value`
fields; and `expander.zig:246` branches to `expandProceduralMacro`, which
calls back into the VM. This shipped as **SRFI 211 in v0.22.0
(2026-07-30)**, ~8 days after those KEPs merged as Draft — implemented as a
SRFI library rather than the kaappi-native extension KEP-0006 sketched. This
KEP describes the expander *as built*, and flags the stale framing so the
two Draft KEPs can be reconciled.

## Summary

Kaappi's macro expander is a **hygienic, gensym-rename expander interleaved
with compilation** — there is no standalone expand pass; macros are expanded
at each use site during IR emission. Hygiene is achieved by renaming
template-introduced identifiers to fresh `__hyg_<id>_<name>` symbols, with a
per-invocation scope table ensuring the same template name maps to the same
gensym *within* one expansion and to different gensyms *across* expansions.
The `syntax-rules` engine supports the full R7RS pattern language —
literals, `_`, `...`, nested and consecutive ellipses, dotted tails, vector
patterns — plus SRFI 46/149 custom ellipsis. Identifiers remain **plain
interned symbols**: hygiene rides in the name string, which is
simultaneously the engine's great simplification and the precise reason
`syntax-case` (KEP-0007) cannot be built on it. Recursive expansion is
bounded two ways: nested expansions recurse natively (depth ≤ 256) while
head-position macro chains *iterate* (≤ 10,000 steps) so a CK-machine-style
macro runs in constant native stack.

This is a retroactive, *as-built* KEP. It proposes no change. Its value is to
write down the one mechanism most responsible for the language's correctness
and most opaque from the outside — how hygiene actually works here — and to
mark, precisely, where this rename-on-instantiate engine stops (no syntax
objects, no phase separation) so a future `syntax-case` effort knows exactly
what it must replace.

## Motivation

The expander is foundational and uniquely under-documented relative to its
importance:

- **Hygiene is correctness-critical and genuinely subtle here.** The
  mechanism is not the textbook marks-and-substitutions or sets-of-scopes —
  it is a one-shot rename performed while walking template output once, with
  binding-position tracking heuristically packed into high bits of a scope
  id (`BINDING_FLAG`, `FORMAL_FLAG`, `QUOTE_FLAG`, …). That design has real
  consequences (it works for `syntax-rules` and a bounded `er` surface, and
  it cannot grow into `syntax-case`), and those consequences are only
  legible from a dense trail of issue-numbered fixes. A written record makes
  the design and its limits reviewable.
- **The KEP set currently mis-describes reality.** KEP-0006/0007 froze a
  snapshot in which procedural transformers didn't exist; the code shipped
  them a week later as SRFI 211. Anyone reading the KEPs today gets a false
  picture of the expander. An as-built KEP corrects the record and draws the
  boundary between "the expander's internal machinery" (here) and "the SRFI
  211 user surface" (KEP-0006's lineage).
- **A future `syntax-case` needs a precise baseline.** KEP-0007 is
  explicitly deferred. The single most useful thing for whoever picks it up
  is an exact statement of what the current expander *is* — because
  `syntax-case` is not an addition to this engine, it is a replacement of
  its identifier representation. This KEP is that baseline.

## Guide-level explanation

Most users interact with the expander only through `define-syntax` and
`syntax-rules`:

```scheme
(define-syntax swap!
  (syntax-rules ()
    ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))

(let ((tmp 1) (other 2))
  (swap! tmp other)   ; the macro's own `tmp` does not capture the user's `tmp`
  (list tmp other))   ; => (2 1)
```

That "does not capture" is *hygiene*, and Kaappi implements it by renaming:
the `tmp` the macro introduces becomes a fresh symbol like
`__hyg_47_tmp`, distinct from any `tmp` the user wrote, so the two never
collide. References the macro introduces to names from *its own* definition
site resolve back there, not to whatever the use site happens to have in
scope. You never see the renamed names — quoted data is stripped back to
plain symbols before it reaches your program, so `(eq? 'x 'x)` still holds.

The `syntax-rules` matcher understands the full R7RS pattern language —
literals, the `_` wildcard, `...` ellipsis (including nested and
back-to-back ellipses), dotted tails, and vector patterns — plus a
user-chosen custom ellipsis symbol. Runaway macros are caught: a macro that
expands into itself forever hits a step limit rather than crashing.

Two honest boundaries worth stating plainly, both about what this engine
*isn't*:

- **There are no syntax objects.** An identifier is just a symbol wearing a
  renamed name. This is why Kaappi has `syntax-rules` and a bounded
  procedural (`er`) surface but **not** `syntax-case` (KEP-0007) — that
  needs identifiers to carry a lexical context a bare symbol cannot.
- **There is no phase separation.** Procedural transformer bodies are
  evaluated at macro-definition time in the global environment; the expander
  does not model separate expansion phases.

## Reference-level design

### Pipeline placement

Expansion sits at the Expander stage of `Source → Reader → Expander → IR →
… → VM`, but it is **interleaved with compilation, not a separate pass**:
`compiler_macro.zig` drives expansion at each macro *use* during IR
emission ("Expansion runs during emission," `expander.zig:238`). The
implementation is split across two file pairs sharing a per-expansion
thread-local context:

- `expander.zig` — macro-use entry points, the pattern matcher, and the
  hygiene/usertext walks.
- `expander_instantiate.zig` — template instantiation, ellipsis, and
  `renameForHygiene`.
- `compiler_macro.zig` / `compiler_define_syntax.zig` — the compiler-side
  driver and the defining forms.

The sole expansion chokepoint is `expander.expandMacro(gc, expr,
transformer, globals, macros, use_check)` (`expander.zig:222`).

### Hygiene mechanism (gensym rename-on-instantiate)

The engine is described in-source as "sets-of-scopes, simplified"
(`expander.zig:32`), but it is **not** true sets-of-scopes — as KEP-0007
notes, it "produces hygiene as a side effect of walking output once." The
accurate description: a one-shot rename performed during template
instantiation, keyed by a per-invocation scope id.

Data structures:

- Atomic counters `gensym_counter` and `next_scope_id`; `freshScope()` mints
  a scope per expansion (`expander.zig:117`).
- A thread-local `scope_table: [256]ScopeEntry` of
  `{original_name, scope, renamed_to}` (`expander.zig:127`), saved and
  restored around each expansion so a template name maps to *one* gensym
  within an invocation and to *different* gensyms across invocations.
- The rename format `__hyg_<gensym_id>_<name>`, minted by
  `mintHygienicRename` (`expander_instantiate.zig:1130`).

The core routine is `renameForHygiene(gc, name, scope, globals)`
(`expander_instantiate.zig:906`), whose decision order is:

1. **Already-renamed passthrough** — names starting `__hyg_`, `__nlet_`, or
   the def-env prefix are returned as-is, so macro-generating macros don't
   double-rename (#919).
2. **Usertext splice** (`VERBATIM_FLAG`) → bare.
3. **Quoted** (`QUOTE_FLAG`) → still hygiene-renamed (#1801), deduped via a
   cleaned scope.
4. **Binding vs reference** — context flags are stripped to a `clean_scope`
   so a binder and its references share one gensym.
5. **Def-env resolution** (#1812) — a free reference bound in the macro's own
   library environment is rewritten to a
   `__kaappi_defenv__<lib>\x1f<name>` symbol so it resolves through *that*
   library regardless of import site.
6. **Globals check** (#2003) — a global *procedure* is hygiene-renamed like
   any template identifier so a use-site local cannot capture it (except a
   `FORMAL_FLAG` lambda formal, kept bare for SRFI 190 anaphora); a global
   *transformer* stays bare so the keyword remains recognizable.
7. Cross-frame def-site local references stay bare.
8. Otherwise, scope-table lookup or mint.

Binding-position information is tracked heuristically through high-bit flags
packed into the scope id — `BINDING_FLAG`, `LET_PAIR_FLAG`, `FORMAL_FLAG`,
`NESTED_SR_FLAG`, `QUOTE_FLAG`, `ESCAPE_FLAG`, `QQ_DEPTH_MASK`
(`expander_instantiate.zig:39`). Macro-generating macros use a "usertext
marker" protocol (`USERTEXT_MARKER = "__hyg-usertext"`, `expander.zig:956`)
to distinguish text originating in the user's use from text the inner macro
introduces. The compiler completes hygiene after expansion by injecting
aliases so renamed names resolve to the right slots
(`injectHygienicCapturedLocals`, `injectHygienicGlobalAliases`, #1832).

### syntax-rules engine

Matching: `matchPattern` (`expander.zig:553`), list spine
`matchListPattern` (`:667`), ellipsis `matchEllipsis` (`:755`), into a
pattern-variable binding buffer (`MAX_BINDINGS = 128`,
`MAX_ELLIPSIS_VALUES = 1024`). Supported pattern forms:

- **Literals** with the R7RS 4.3.2 same-binding rule (`:595`), plus a
  hygiene-renamed-vs-unbound-literal carve-out (#1720).
- **`_` wildcard**, self-evaluating **constants**, **vector patterns**
  (converted to lists), and **dotted tails**.
- **Ellipsis and nesting**: match depth is seeded from the pattern structure
  (`patternVarNesting`, fixes zero-match depth #682); the template side
  (`instantiateEllipsis`, `expander_instantiate.zig:680`) handles
  consecutive-ellipsis flattening `(x ... ...)` (SRFI 149), per-depth count
  validation (R7RS equal-count; SRFI 149 min-count zip), and reports
  `EllipsisDepthMismatch` / `EllipsisNoPatternVariable` on misuse.
- **Custom ellipsis** via `Transformer.custom_ellipsis` (SRFI 46/149).

Template instantiation gensym-renames every introduced identifier that is
not a pattern variable, a literal, a reserved form, or the macro's own
keyword.

### Identifier representation (and why syntax-case can't sit on it)

There is **no syntax-object type**. Identifiers stay plain interned symbols;
hygiene rides in the name string as the `__hyg_N_` prefix (and
`__kaappi_defenv__…` for def-env references). Round-trip helpers live in
`types.zig`: `stripHygienicPrefix` (`:1251`), the `def_env_binding_prefix`
`"__kaappi_defenv__"` and separator `\x1f`. The reader produces bare
symbols; the expander mints prefixed symbols; the compiler recognizes them
by **effective-name stripping** everywhere it dispatches; and quoted data is
stripped back to plain symbols at compile time
(`stripHygieneFromDatum`, #1801) so runtime `eq?` on quoted symbols holds.

This is the crux of KEP-0007's deferral: because an identifier is a bare
symbol with an encoded name and no attached lexical context, there is
nothing for `datum->syntax` to transfer or for `syntax-case` to inspect. A
`syntax-case` implementation would have to replace this representation, not
extend it.

### What the expander provides to procedural transformers

*(The user-facing `er`/`lisp` contract is KEP-0006/SRFI 211; this is only
the expander-internal machinery.)* Dispatch on `Transformer.kind`
(`expander.zig:246`) routes `.er_macro`/`.lisp_macro` to
`expandProceduralMacro` (`:373`), which fully unwraps the input form, mints a
fresh `er_scope`, saves/restores the thread-local context for re-entrancy,
roots the arguments across the reentrant VM call, and invokes the Scheme
transformer via `globals.call_proc_for_macro` (the expander cannot import
`vm.zig`). For `.er_macro` it builds two native closures: `rename`
(`erRenameFn`, reusing `renameForHygiene` under the fresh `er_scope`) and
`compare` (`erCompareFn`, approximating `free-identifier=?` as equal
hygiene-stripped effective names). The source is candid that this gives ER
"exactly the hygiene strength of this engine's own `syntax-rules` — no more,
no less" (`expander.zig:361`). The eight other SRFI 211 transformer kinds
"a symbol-based expander cannot honestly provide" are deliberately not
exported; `sc-`/`rsc-macro-transformer` and `syntax-case` are unimplemented.

### Expansion depth, chains, and fixpoint

Two constants bound recursion (`compiler_macro.zig:12`):
`MAX_MACRO_EXPANSION_DEPTH = 256` and `MAX_MACRO_EXPANSION_STEPS = 10_000`;
exceeding either raises `MacroExpansionLimit`. The two limits guard
different shapes:

- **Nested** expansions recurse natively and are bounded by 256 to protect
  the native stack (raising it segfaults, #1796).
- **Head-position chains** — where a macro expands directly into another
  macro use in the same position (e.g. a SRFI 148 CK-machine
  `(loop) → (loop)`) — **iterate** in a `while` loop at O(1) native stack,
  bounded by the 10,000-step limit (`chainNextMacroUse`, `:92`).

A fixpoint guard (`valuesStructurallyEqual`) suppresses re-expansion when a
macro expands to itself *and* its keyword is a special form, letting the
built-in take over (SRFI 219 `(define x e) → (define x e)`). Otherwise macro
output is re-scanned for further macros by re-entering `compileExpr`.

### Special forms and define-syntax registration

The expander distinguishes macros from core special forms via a table in
`ir.zig` (`sexpr_form_map` + `other_special_forms`, predicate
`isSpecialForm`, `:608`), consulted through the hygiene strip. Two curated
lists in `expander.zig` govern template behaviour: `well_known_forms`
(`:47`) and `reserved_template_forms` (`:88`) — the subset kept bare in
templates (definition/library forms, `syntax-rules`, `else`, `...`, `_`,
quote family). Notably, operator keywords like `if` and `let` are
**deliberately hygiene-renamed** and recognized via effective-name stripping
(#2074), and are intentionally omitted from `well_known_forms` because the
R7RS test suite rebinds them.

`define-syntax` is handled by `compileDefineSyntax`
(`compiler_define_syntax.zig:36`): it resolves the transformer spec, roots
the transformer via `extra_roots` (#1401, since the compiler-local
`self.macros` map is invisible to the GC), records the definition
environment and library name, finalizes the transformer, and stores it into
`self.macros` and — at library top level — the library environment.
`let-syntax`/`letrec-syntax` parse all specs before registering (R7RS 4.3.1
two-phase) and restore peer bindings LIFO.

### Library interaction (def-env plumbing)

Imported macros resolve free references through *their own* library via the
transformer's `def_env` / `def_lib_name` (`types_macro.zig:53`), set at
definition and consumed by `renameForHygiene` (#1812) to emit def-env-prefix
references (resolved by `globals.lookupDefEnvBinding`). The R7RS 4.3.1
referential-transparency injection at use sites is driven by
`bound_free_refs` / `captured_locals` / `def_site_local_refs` computed by
`finalizeTransformer`. There is **no phase separation**: procedural specs are
evaluated at macro-definition time in the global environment.

### Error conditions (diagnostic shape deferred to KEP-0005)

The expander's `ExpandError` set (`expander.zig:328`) is `NoMatchingPattern`,
`ScopeTableFull`, `PatternTooComplex`, `EllipsisCountMismatch`,
`EllipsisDepthMismatch`, `EllipsisNoPatternVariable`, `TransformerFailed`,
`OutOfMemory`. These map to compile errors in `compiler_macro.zig:392`
(ellipsis/no-match → `InvalidSyntax`; limits → `InternalLimit`;
`TransformerFailed` copies the real Scheme condition into
`syntax_error_detail`, #1846). The *diagnostic codes and JSON shape*
(`KP2xxx`) belong to KEP-0005 and are not re-specified here.

### Tests

Zig units: `tests_macros.zig`, `tests_macros_nested_sr.zig`,
`tests_macro_chains.zig`, `tests_ellipsis.zig`. Scheme: the
`tests/scheme/hygiene/` suite (21 files — `arg-vs-free.scm`,
`free-global-vs-arg-1832.scm`, `def-env-redefinition-1812.scm`,
`define-shadows-macro-keyword.scm`, …), ~16 macro files elsewhere, and the
SRFI 211 suite. KEP-0006 names `tests/scheme/hygiene/` plus
`tests_macros.zig` as the regression guard that must stay green.

## Drawbacks

The hygiene engine is under active hardening (a cluster of fixes in v0.22.0
and later: operator-keyword renaming #2074, ellipsis-depth validation,
def-env resolution #1812), so an as-built KEP risks drifting from a moving
target. Mitigation: the KEP records the *mechanism and its boundaries* (the
rename-on-instantiate approach, the scope-table dedup contract, the
no-syntax-object limit, the depth/chain split) rather than each rename rule,
and pins line references to a commit.

There is also a real risk of appearing to endorse the current design as
final when much of it (the flag-soup binding heuristics, the name-string
encoding) is exactly what KEP-0006/0007 flag as limiting. Mitigation: this
KEP is explicit that the representation is the barrier to `syntax-case` and
frames that as a recorded limitation, not a recommendation.

## Alternatives considered

- **Leave it to `architecture.md`.** That doc gives the expander one row and
  is now stale ("Only syntax-rules is supported for macro definitions" —
  false since SRFI 211). A KEP both corrects the record and gives the
  hygiene mechanism its first real spec.
- **Fold this into KEP-0006/0007.** Rejected: those are *proposal* KEPs about
  user-facing transformer surfaces (ER, syntax-case), frozen at a 2026-07-21
  snapshot. Merging the as-built expander internals into them would either
  rewrite their proposals or bury the internals. The clean split is
  "KEP-0006/0007 own the transformer surfaces; KEP-0018 owns the expansion
  algorithm and hygiene engine underneath them." This KEP references them
  rather than superseding.
- **Two KEPs (hygiene engine; syntax-rules engine).** Rejected: the matcher,
  the template instantiator, and the renamer are one interleaved algorithm
  sharing the scope table and flag encoding; splitting them would cut the
  invariant in half.
- **Wait for `syntax-case`.** Rejected: the greatest value of this record is
  precisely to give a deferred `syntax-case` effort an exact statement of
  what it must replace — which is most useful *before* that work starts.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- The expander is platform-independent Scheme-level machinery; it has no
  per-OS behaviour. Procedural transformers re-enter the VM, so they are
  subject to the same `--sandbox`/WASM policy as any Scheme evaluation
  (owned by KEP-0011/0013 and the SRFI 211 packaging).
- Hygiene is encoded in symbol names, so it is representation-stable across
  targets; quoted-data hygiene stripping preserves `eq?` semantics
  everywhere.
- The `syntax-rules` feature set (R7RS + SRFI 46/149 custom ellipsis) and the
  bounded `er`/`lisp` surface (SRFI 211) are identical on all platforms;
  `syntax-case` is unavailable on all.

## Unresolved questions

1. **Reconcile KEP-0006/0007 with the shipped SRFI 211 reality.** Should
   those Draft KEPs be updated (or annotated) to reflect that procedural
   transformers now exist as SRFI 211, and should this KEP be listed as the
   internal counterpart they build on?
2. **Is the name-string hygiene encoding a permanent representation**, or the
   thing a future `syntax-case` (KEP-0007) must replace with real syntax
   objects? If the latter, should this KEP record the migration path as an
   explicit non-goal-until-then?
3. **The 256/10,000 expansion limits**: are these fixed contracts or tunables?
   Raising 256 segfaults (native stack), so is converting more nested cases
   to the iterative chain path the intended direction?
4. **Binding-position flag heuristics** (`BINDING_FLAG`, `FORMAL_FLAG`, …):
   are these a stable internal contract, or acknowledged debt that a proper
   syntactic environment would remove?
5. **Phase separation**: evaluating procedural specs at definition time in
   the global environment is a simplification. Is phase separation ever in
   scope, and would it be a KEP-0007-era change?
6. **ER hygiene strength**: the source states ER is exactly as hygienic as
   `syntax-rules` here. Should that equivalence be a documented guarantee of
   the SRFI 211 surface (KEP-0006), referenced from this KEP?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Correct the stale record**: update `architecture.md` ("Only
   syntax-rules …") and annotate KEP-0006/0007 that procedural transformers
   shipped as SRFI 211 (v0.22.0), with this KEP as the internal reference.
3. **Write the first `docs/dev/expander.md`** (hygiene mechanism, scope
   table, the flag encoding, the depth/chain split) seeded from this KEP's
   reference section, and link it here.
4. **Resolve the representation question** (Unresolved 2) jointly with
   KEP-0007, stating explicitly that `syntax-case` requires replacing the
   symbol-name hygiene encoding.
5. **Cross-link KEP-0005** for the `KP2xxx` mapping of the expander error
   conditions, and KEP-0006/SRFI 211 for the ER/lisp user surface.
6. **On acceptance**, triage the limit-tuning, flag-heuristic, and
   phase-separation questions (Unresolved 3–5) into tracked issues so future
   expander work amends this KEP rather than the scattered fixes.
