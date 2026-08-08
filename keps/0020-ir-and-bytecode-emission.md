# KEP-0020: The IR Pipeline and Bytecode Emitter

| Field | Value |
|-------|-------|
| **KEP** | 0020 |
| **Title** | The IR Pipeline and Bytecode Emitter |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/ir.zig`, `src/compiler.zig`, `src/compiler_ir.zig`, `src/compiler_bindings.zig`, `src/compiler_conditionals.zig`, `src/compiler_lambda.zig`, `src/compiler_advanced.zig`, `src/compiler_passthrough.zig`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. `docs/dev/ir.md` and
`docs/dev/bytecode.md` are current and match source closely; the one place
older lore is stale (the "3 analysis passes" figure) is corrected below.*

## Scope

This KEP specifies **kaappi's own IR pipeline and bytecode emitter** — the
middle of `Reader → Expander → IR (lower + analyze + optimize) → Bytecode
Emission → VM`. It defers, by reference:

- **The shared cross-implementation IR contract** — the canonical core-form
  set, the peephole optimizations, and the primitive-shadowing safety
  principle *as an agreement among kaappi, paal, and chaaya* — to
  [KEP-0008](0008-shared-ir-contract.md). This KEP records kaappi's
  *concrete* `NodeTag` set and passes as implemented; where a pass realizes
  a KEP-0008 shared optimization, it says so without re-arguing the
  contract.
- **`.sbc` serialization** of the emitted bytecode →
  [KEP-0014](0014-sbc-bytecode-format.md). The emitter produces *in-memory*
  bytecode; the on-disk format is KEP-0014's.
- **VM execution semantics** of the opcodes → the VM. This KEP records the
  opcode *set* the emitter targets and the calling convention it and the VM
  agree on, not how the VM executes them.
- **Value representation** → [KEP-0017](0017-gc-and-value-model.md).
- **Macro expansion during emission** → [KEP-0018](0018-macro-expander-hygiene.md).
  This KEP notes the interleaving but does not re-spec it.
- **Diagnostic code shape** (`KP2xxx`) → [KEP-0005](0005-diagnostic-contract.md).
  Only the compiler's error *conditions* are recorded here.

## Summary

Kaappi compiles through a **tree-structured, direct-style intermediate
representation**. The lowerer turns expanded S-expressions into an 18-tag
`Node` tree; a single analysis pass marks tail positions; five optimization
passes fold and simplify (each gated by a primitive-shadowing safety check);
and a register-based bytecode emitter, split across nine `compiler*.zig`
files, walks the IR into instructions for a ≤65535-register-per-frame VM.
The IR is deliberately direct-style and shared: **the LLVM native backend
(KEP-0010) consumes the same IR after the same lower/analyze/optimize
stages, and the pipeline forks only at emission.** All compilation was
unified onto this IR path in the v0.13.0 era, which also deleted two dead
analysis passes — so the once-quoted "3 analysis passes" is now one.

This is a retroactive, *as-built* KEP. It proposes no change. Its value is to
record kaappi's concrete middle-end — the exact node set, the *one* analysis
pass and *five* optimization passes with their shadowing gate, the
nine-file emitter split, the register calling convention, and the
shared-IR-then-split-emission architecture — as a numbered reference,
correcting the stale pass-count lore and pinning the contracts the emitter
and VM agree on.

## Motivation

The IR and emitter are the least externally visible but most central part of
the compiler, and several of their properties are worth a written record:

- **The analysis/optimization surface is small, specific, and mis-described
  in lore.** There is exactly one analysis pass (`markTailPositions`) and
  five optimization passes (`foldConstants`, `eliminateDeadBranches`,
  `simplifyBooleans`, `eliminateIdentity`, `simplifyBegin`). The "3 analysis
  passes" figure is stale — two passes were removed as dead code in v0.13.0.
  A source-verified KEP fixes the record and states exactly what the
  optimizer does and, importantly, does *not* do (no inlining, no
  beta-reduction, no let-folding in the IR).
- **The shadowing safety gate is a correctness invariant.** Every fold that
  treats an operator as a known primitive first calls `ir.isRedefined` —
  consulting lexical binding, the `set!`-target scan, and a
  truncation-to-conservative fallback. This is kaappi's concrete realization
  of KEP-0008's shared shadowing principle, and getting it wrong silently
  miscompiles a program that redefines `+`. It deserves an explicit
  statement.
- **The shared-IR-then-split-emission architecture is load-bearing and
  subtle.** Because the same IR feeds both the bytecode emitter and the LLVM
  backend, and because binding forms keep raw S-expr tails that get
  *re-lowered* during native emission, only the scope-preserving lowerer is
  safe there (the scope-less variants were deleted after #2117/#2118).
  Recording this prevents a whole class of regression.
- **The calling convention is a contract between emitter and VM.** Operator
  in `base`, args in consecutive registers, `call base, nargs`, result in
  `dst`, ≤255 args, ≤65535 registers — this is an agreement two subsystems
  must keep in lockstep, and it currently lives only in code and
  `bytecode.md`.

## Guide-level explanation

Between "read" and "run," Kaappi compiles. A form like `(if (> x 0) x (- x))`
is first turned into a small tree of typed nodes (an `if` node with a `call`
test and two branch nodes), then lightly optimized, then emitted as
register-based bytecode:

```
Reader  → Expander → IR: lower → analyze (tail positions) → optimize (5 passes) → emit bytecode → VM
```

The optimizer is intentionally modest — it folds constant arithmetic,
removes branches with constant tests, cancels double negation, drops
identities like `(+ x 0)`, and flattens `begin` — and every one of those is
*guarded*: if your program has rebound `+` or `not`, the optimizer notices
and leaves the call alone. You can turn the whole optimizer off with
`--no-ir-opt`.

Two facts worth knowing:

- **One IR, two backends.** The interpreter's bytecode emitter and the LLVM
  native compiler (KEP-0010) consume the *same* IR after the *same*
  analysis and optimization. They diverge only at the final emission step.
- **The bytecode is register-based.** Instead of a stack, each function has
  a window of registers (up to 65535); a call puts the operator in a base
  register and the arguments in the ones after it. Tail calls get their own
  opcode so deep recursion runs in constant space.

## Reference-level design

### IR data model

The IR is **tree-structured and direct-style** (not SSA/CFG), so both the
bytecode emitter and the LLVM backend consume one representation without CPS
conversion. The `NodeTag` enum has **18 tags** (`ir.zig:13`):
`constant`, `global_ref`, `call`, `if`, `begin`, `and_form`, `or_form`,
`when_form`, `unless_form`, `define`, `set_form`, `lambda`, `let_form`,
`let_star`, `letrec`, `letrec_star`, `sexpr_form`, `passthrough`. A `Node`
(`ir.zig:242`) is `{ tag, data: Data, ann: Annotations }` where `Data` is an
18-arm union mirroring the tags.

Lowering depth is deliberately three-tiered:

1. **Fully lowered** — sub-expressions are IR nodes: `constant`, `global_ref`,
   `call`, `if`, `begin`/`and_form`/`or_form`, `when_form`/`unless_form`,
   `define`, `set_form`, `lambda`.
2. **Binding forms** keep their body as a raw S-expr tail in
   `LetData{args: Value}`: `let_form`, `let_star`, `letrec`, `letrec_star`.
3. **`sexpr_form`** — one tag carrying `SexprFormData{form: FormKind, args}`,
   discriminated by **18 `FormKind`s** (`ir.zig:34`): `do_form`, `delay`,
   `delay_force`, `cond`, `case_form`, `case_lambda`, `guard`, `quasiquote`,
   `parameterize`, `define_values`, `let_values`, `let_star_values`,
   `define_syntax`, `define_property`, `named_let`, `let_syntax`,
   `letrec_syntax`, `cond_expand`.
4. **`passthrough`** — a raw S-expr handed to the legacy syntax-directed
   `compileExpr` (macro uses, `syntax-rules`, `apply`, …).

A key consequence: `cond`, `case`, `do`, named `let`, `quasiquote`,
`guard`, `parameterize`, and `case-lambda` are **not** structurally
desugared in the IR — they are recognized and boxed with raw tails, then
re-parsed by the form compilers at emission. So "cond → if" and "named-let →
loop" happen at *emission time*, not in IR lowering.

*(KEP-0008 overlap, noted not re-argued: `ir.zig:80` holds an
`llvm_node_table` marking each tag `.native` vs `.eval_fallback` for the
native backend — kaappi's concrete realization, distinct from the shared
core-form contract.)*

### Lowering

`lowerWithMacros(ir, expr, macros)` (`ir.zig:612`) is the primary lowerer;
`lowerAndOptimize` (`ir.zig:729`) is the full driver (lower → analyze →
optimize). It dispatches on the head symbol of a pair, with per-form helpers
(`lowerIf`, `lowerQuote`, `lowerBegin`, `lowerLet`, `lowerDefine`,
`lowerSet`, `lowerList` for and/or, `lowerCondBody` for when/unless,
`lowerCall`). Only `if`, `begin`, `and`, `or`, `when`, `unless`, `define`,
`set!`, `lambda`, and `call` are truly lowered to core nodes; everything
else is boxed. The lowerer strips `__hyg_N_` prefixes before matching
special forms (KEP-0018) and strips hygiene from quoted data
(`stripHygieneFromDatum`, #1801). An early constant fold `tryFoldFromAST`
fires during the lowering of constant-fixnum arithmetic, *before* the
optimization passes.

### The analysis pass (one, not three)

The single analysis pass is `markTailPositions(node, is_tail)`
(`ir.zig:1080`), called from `lowerAndOptimize`. It sets `ann.is_tail`, which
`compileFromNode` reads to choose `tail_call` vs `call`. Propagation: an
`if` test is non-tail and its branches inherit; a `begin`/`and`/`or` last
subform inherits and the rest are non-tail; a `call`'s operator and args are
always non-tail. *(The two removed passes' primitive list survives as
`isKnownGlobal` (`ir.zig:1133`), but it annotates nothing now — its only
caller is the LLVM backend.)*

### The five optimization passes

`lowerAndOptimize` applies them in fixed order, each `(ir, *Node) → *Node`,
behind `optimize_enabled` (`--no-ir-opt` sets it false; `kaappi check` also
disables it while linting):

1. **`foldConstants`** (`ir.zig:1162`) — evaluates constant primitive calls
   (`not`, `zero?`, unary `-`; binary `+ - * < > <= >= =`); skips on i48
   overflow.
2. **`eliminateDeadBranches`** (`ir.zig:1267`) — `(if #t A B) → A`,
   `(if #f A B) → B`, `(if #f A) → #void`.
3. **`simplifyBooleans`** (`ir.zig:1309`) — `(not (not X)) → X`,
   `(if (not X) A B) → (if X B A)`.
4. **`eliminateIdentity`** (`ir.zig:1361`) — `(+ x 0) → x`, `(* x 1) → x`,
   `(* x 0) → 0`, `(- x 0) → x`.
5. **`simplifyBegin`** (`ir.zig:1434`) — `(begin X) → X`, recursive
   flattening.

Deliberately **absent**: no dead-code elimination beyond dead branches, no
inlining, no beta-reduction, no let-folding in the IR (fixnum inline
fast-paths and self-tail-call-to-loop live at emission / in the native
backend, not as IR passes).

**The shadowing safety gate.** `foldConstants`, `eliminateIdentity`, and the
`not` case of `simplifyBooleans` each call `ir.isRedefined(name)`
(`ir.zig:374`) before treating an operator as a known primitive.
`isRedefined` consults lexical binding (`isLexicallyBound`), the
`set_targets_all` conservative flag (set when the `set!`-scan is truncated,
#1775), and the `set_targets` map. Lexical shadowing never even reaches
these, because folds fire only on `.global_ref` operators and a shadowed
name lowers to something else first. This is kaappi's realization of
KEP-0008's shared shadowing invariant.

### Bytecode emission — the nine files

Emission enters at `compileFromNode(self, node, dst, is_tail)`
(`compiler_ir.zig:15`), a tag switch dispatched from `Compiler.compile`.

| File | ~Lines | Role |
|---|---:|---|
| `compiler.zig` | 1393 | The `Compiler` struct, register allocation, `emit*` primitives, constant pool, jump patching, top-level `compile*` entry points, and the legacy `compileExpr` path. |
| `compiler_ir.zig` | 567 | `compileFromNode` — the IR-tree → bytecode dispatcher; call/if/begin/define/set/and/or emission. |
| `compiler_forms.zig` | 45 | Barrel re-exporting the sub-compilers. |
| `compiler_bindings.zig` | 737 | `let`/`let*`/`letrec`/`letrec*`, `let-values`, named `let`. |
| `compiler_conditionals.zig` | 338 | `cond`, `case`, `when`/`unless`, boolean forms. |
| `compiler_lambda.zig` | 1108 | Lambda/closure emission, `case-lambda`, `define-values`, body-def scanning. |
| `compiler_advanced.zig` | 1024 | `do`, `guard`, `parameterize`, `delay`/`delay-force`, `quasiquote`. |
| `compiler_macro.zig` / `compiler_define_syntax.zig` | 789 / 885 | Macro-use expansion and `define-syntax` family (KEP-0018 — reference only). |
| `compiler_passthrough.zig` | 439 | Passthrough / legacy special-form emit paths. |

- **Register allocation**: a `next_register: u16` bump allocator
  (`compiler.zig:138`); `allocReg`/`freeReg`; cap
  `MAX_COMPILER_REGISTERS = 65535`, overflow → `TooManyLocals`. Virtual =
  physical (frame-relative slots); the high-water mark becomes
  `func.locals_count`, which sizes continuation-capture register windows.
- **Constant pool**: `addConstant` (`compiler.zig:284`), cap 65536 →
  `TooManyConstants`.
- **Jump patching**: `patchJump` (`compiler.zig:323`), `JumpOutOfRange` on
  i16 overflow; offsets are relative to the instruction after the jump.
- **Closures**: a `closure dst, func_idx` opcode followed by
  `upvalue_count × 3` capture descriptors (`is_local:u8, index:u16`),
  tracked in `Compiler.upvalues`.
- **Tail calls**: `compileCallFromIR` emits `tail_call`/`call`, fuses
  `tail_call_global`/`call_global` when the operator is an unshadowed
  global, and rewrites direct self-recursion / `__nlet_` loops to
  `self_tail_call`.

### Register model and calling convention

The VM is register-based with up to 65535 registers per frame. The
convention (`compiler_ir.zig:143`): the operator is emitted into a `base`
register and arguments into consecutive `base+1, base+2, …`; the instruction
is `call base, nargs` or `tail_call base, nargs`. When the destination is
not already at the top of the register window, a fresh contiguous window is
allocated (`needs_rebase`) and the result is `move`d back to `dst`. The
return value lands in `dst`; a top-level form ends with `return dst`. A call
takes at most 255 arguments (`nargs:u8`); more is `InternalLimit`. Function
metadata (`arity:u8`, `is_variadic`, `locals_count:u16`, `upvalue_count:u16`,
constants, line table, debug locals) travels with the emitted `Function`.

### Compile entry points

`Compiler.compile(expr, is_tail)` (`compiler.zig:526`) compiles one
top-level form: it roots the datum, runs a `collectSetTargets` `set!`-prescan
(budgeted, degrading to the conservative `set_targets_all` on truncation),
builds the IR, runs `lowerAndOptimize`, emits via `compileFromNode`, and
appends `return`. Public entry points include `compileExpression`,
`compileExpressionWithMacros(At)` (which set `source_line`/`source_name`),
`compileExpressionInEnv` (restricted/library environments), and
`compileProgram`. A `body_macro_depth` counter plus a `body_macros` list
implement R7RS 5.3 body-scoped `define-syntax`. Top-level *form
classification* (define/import/define-syntax handling) is done by
`vm.topLevelHead`/`runTopLevelHead` — a VM/driver concept shared with
`check` and the LSP, referenced here but owned outside these files.

### Line and debug info

Each `Node` carries `ann.span: types.Span` (`ir.zig:233`), set by the
lowerer from the reader's `gc.source_spans` (KEP-0019). The emitter writes
`{offset, line, col}` entries into `func.line_table` on each line/col change,
from two sites (IR emission and the legacy path), enabling runtime
`file:line:col`. `debug_locals` maps register slots to variable names.

### Native-backend interaction (shared IR, split emission)

The LLVM native backend (KEP-0010) consumes the **same IR after the same
lower/analyze/optimize**; the fork is only at emission —
`compileFromNode` (bytecode) versus the `llvm_emit*.zig` family (native).
Because binding tags and `sexpr_form` carry raw S-expr tails, every
lambda/let body is **re-lowered during native emission**, and only the
scope-preserving `LLVMEmitter.lowerScoped` is safe there (it preserves
`bound_names`/`set_targets`); the scope-less lowerers were *deleted* because
a bare re-lower reopened the #2117/#2118 scope bugs. This is a real
invariant new emitter code must respect.

### Error conditions (diagnostic shape deferred to KEP-0005)

The `CompileError` set (`compiler.zig:54`, shared with the IR):
`OutOfMemory`, `InvalidSyntax`, `UndefinedVariable`, `TooManyConstants`,
`TooManyLocals`, `InternalLimit`, `MacroExpansionLimit`, `JumpOutOfRange`.
`InvalidSyntax` covers malformed forms; the `TooMany*`/`JumpOutOfRange`/
`InternalLimit` set covers the pool/register/arg/jump caps;
`MacroExpansionLimit` is the expansion depth/step guard (KEP-0018). Error
spans are threaded via `noteCompileErrorSpan`/`getCompileErrorSpan` (#1506);
the `KP2xxx` code/JSON shape is KEP-0005's.

### Tests

`src/tests_ir.zig` (~94 tests) in four groups: behavioral, lowering (tree
shape), analysis (`markTailPositions`), and optimization (the five passes).
The old bytecode-parity group is gone — it tested a removed standalone
emitter, leaving `compileFromNode` as the single IR→bytecode path.
Optimization and shadowing regressions also live under `tests/` and the
root regression logs (e.g. `constant-fold-shadowing`,
`tail-call-stale-regs-1256`).

## Drawbacks

The middle-end changes more than most subsystems (the v0.13.0 unification,
the native re-lowering fixes #2117/#2118), so an as-built KEP risks drift.
Mitigation: the KEP records the *architecture and invariants* — the node
set, the one-analysis/five-optimization shape, the shadowing gate, the
calling convention, the shared-IR-split-emission rule — which are stable,
and pins line references to a commit; the exhaustive opcode/operand table
stays in `bytecode.md`.

Documenting the optimizer's deliberate minimalism (no inlining, no
beta-reduction) could read as a permanent ceiling. It is not meant to — the
Unresolved questions treat the pass set as extensible. The record's purpose
is to state what exists so that *adding* an optimization is a visible,
reviewable change measured against KEP-0008's shared-contract obligations.

## Alternatives considered

- **Leave it to `ir.md` + `bytecode.md`.** Those docs are good and current,
  but they are not numbered contracts, and the pass-count lore ("3 analysis
  passes") drifted even so. A KEP fixes the record and ties the middle-end to
  its neighbours (KEP-0008 IR contract, KEP-0010 native emission, KEP-0014
  serialization) in the index.
- **Fold this into KEP-0008 (shared IR contract).** Rejected: KEP-0008 is
  explicitly the *cross-implementation agreement* among kaappi, paal, and
  chaaya — the canonical form set and the shared peephole optimizations *as a
  contract*. This KEP is kaappi's concrete engineering (its actual `NodeTag`
  union, its emitter file split, its register convention), which is not
  shared and would bloat KEP-0008. They reference each other.
- **Fold emission into KEP-0014 (.sbc format) or the VM.** Rejected: KEP-0014
  owns the *serialized* format and KEP-0014's `compilerHash` gate; the VM
  owns *execution*. Emission — turning IR into in-memory instructions and the
  calling convention — is a distinct concern that both depend on.
- **Split IR (data model + passes) from the emitter.** Rejected as
  over-fragmentation: the analysis annotations (`is_tail`) exist *for* the
  emitter, the shadowing gate protects *emitted* code, and the shared-IR
  split-emission rule only makes sense with both halves in view.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- The IR pipeline and emitter are platform-independent; the same IR and the
  same five optimizations run on every target, and the interpreter and LLVM
  backends (KEP-0010) share them, forking only at emission.
- The calling convention (operator + consecutive-arg registers, `call base,
  nargs`, result in `dst`, ≤255 args, ≤65535 registers) is a fixed contract
  between the emitter and the VM on all platforms.
- The shadowing safety gate (`isRedefined`) makes optimization
  semantics-preserving uniformly — a program that rebinds a primitive
  compiles the same everywhere.
- Emitted in-memory bytecode is serialized by KEP-0014 (whose `compilerHash`
  binds a `.sbc` to the exact compiler/target); this KEP produces the
  bytecode, KEP-0014 persists it.
- `--no-ir-opt` disables the optimizer (and, per KEP-0014, the `.sbc` cache)
  identically across platforms.

## Unresolved questions

1. **Is the optimizer's pass set open to growth**, and if so, must each new
   optimization (inlining, beta-reduction, let-folding) satisfy KEP-0008's
   shared-contract obligations and carry an `isRedefined`-style gate as an
   invariant?
2. **Should the calling convention be a frozen contract** documented jointly
   with the VM, so a change to register semantics is a coordinated amendment
   rather than a two-file edit?
3. **The re-lowering hazard** (native emission re-lowers raw S-expr tails;
   only `lowerScoped` is safe): should the IR eventually carry fully-lowered
   binding bodies so the raw-tail re-lower is impossible, and is that a
   KEP-0008-level change?
4. **The 65535-register / 65536-constant / 255-arg limits**: fixed contracts
   or tunables, and are the resulting `TooMany*`/`InternalLimit` errors part
   of the compatibility surface?
5. **The single analysis pass**: is tail-position marking the only analysis
   the two backends will ever need, or is the removal of the old passes a
   baseline a future analysis (escape, type) would extend?
6. **`sexpr_form`/`passthrough` as an IR escape hatch**: is boxing raw tails
   for late re-parse the intended long-term design, or debt to retire by
   lowering more forms structurally?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Correct the stale record**: fix any remaining "3 analysis passes"
   references (it is one) in docs and comments, and point `ir.md` /
   `bytecode.md` at this KEP as the numbered middle-end reference.
3. **Decide the pass-set-growth and calling-convention questions**
   (Unresolved 1–2), and if the convention is deemed a frozen contract,
   record the coordination expectation with the VM.
4. **Cross-link KEP-0008** (shared IR contract), **KEP-0010** (native
   emission fork), and **KEP-0014** (serialization) from `ir.zig` /
   `compiler.zig` and this KEP so the middle-end's boundaries are
   discoverable from code.
5. **Record the re-lowering invariant** (Unresolved 3) prominently for
   native-backend contributors, since it is a live regression source.
6. **On acceptance**, triage the limits, analysis-extension, and
   escape-hatch questions (Unresolved 4–6) into tracked issues so future
   middle-end work amends this KEP rather than the scattered docs.
