# KEP-0010: The LLVM Native Backend

| Field | Value |
|-------|-------|
| **KEP** | 0010 |
| **Title** | The LLVM Native Backend |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/llvm_emit*.zig`, `src/native_compiler.zig`, `src/runtime_exports.zig`, `src/native_decls.zig`), `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against that source — not just
`docs/dev/llvm-backend.md` and the two decision records under
`docs/dev/decisions/` — as of 2026-08-08.*

## Summary

Kaappi has a second execution tier. Alongside the register-based bytecode
VM, `kaappi compile foo.scm -o foo` lowers Scheme through the *same* IR the
interpreter uses, emits LLVM IR text, and links it against a prebuilt
runtime library (`libkaappi_rt.a`) into a standalone native executable.
This tier shipped incrementally across v0.7.0 and v0.8.0 (2026-06-28),
replacing an earlier hand-written 5,215-line AArch64/x86_64 JIT, and has
been extended and hardened in every release since. It has ~5,850 lines of
implementation, its own architecture document, and **two standalone
decision records** — but no KEP.

This is a retroactive, *as-built* KEP. It does not propose changing the
backend. It writes down what the backend already is: its pipeline, its
C-ABI contract with the runtime, its fallback-to-interpreter semantics, the
set of forms it cannot lower natively, and — most consequentially for
users — the deliberate decision that `compile` targets **aarch64 and
x86_64 only**. The goal is to make those design commitments reviewable and
citable as a numbered contract, so future changes to the codegen/runtime
boundary or the supported-architecture set are measured against a written
baseline rather than rediscovered from source.

## Motivation

The native backend is the single largest architectural subsystem in kaappi
that was never captured in a KEP, and it is precisely the kind of
subsystem the KEP process exists for: a new runtime tier with a
compatibility surface (native vs. interpreter behaviour) and a
user-visible portability boundary (which architectures can `compile`).

The clearest evidence that this deserved a KEP is that the design
deliberation *already happened* — just not as a numbered, reviewable
document. Two standalone decision records live under `docs/dev/decisions/`:

- `native-backend-architecture-scope.md` (2026-07-19) decides that
  `compile` is restricted to aarch64/x86_64, and documents a concrete
  failure it prevents: on riscv64, `emitPreamble` emitted
  `target triple = "unknown-unknown-unknown"` with no `target datalayout`,
  the `-w` flag let `zig cc` silently substitute the host default, the
  link *succeeded*, and the resulting binary segfaulted. Verified
  2026-07-19 on Alpine/QEMU riscv64: `kaappi compile hello.scm -o hello`
  printed `Compiled hello`, then `./hello` printed `Segmentation fault`.
  The record's conclusion — "compile-and-link success on an unsupported
  architecture is worse than failure" — is a design position that should
  be citable by number.
- `continuation-strategy.md` (2026-06-27) decides that native code uses the
  C stack directly and *side-exits to the bytecode VM* for `call/cc`,
  rejecting both a CPS IR and segmented stacks.

These are load-bearing, user-affecting decisions recorded outside the one
process meant to host exactly that kind of discussion. A reader auditing
"what does `kaappi compile` guarantee, and where does it stop?" today has
to reconstruct the answer from ten source files and two dev-docs. This KEP
consolidates it.

## Guide-level explanation

There are two ways to run a Kaappi program, and they share almost the whole
compiler:

```
Source → Reader → Expander → IR → Analysis → Optimization → ┬─ Bytecode → VM        (interpreter)
                                                            └─ LLVM IR → zig cc → Native Binary
```

Both backends consume the same IR after the same analysis and optimization
passes. The split is only at emission. That is the central invariant: the
native tier is not a reimplementation of the language, it is a second
*emitter* hung off the shared front end, plus a runtime library that native
code calls into.

From a user's terminal:

```bash
kaappi foo.scm                 # interpret (bytecode VM)
kaappi compile foo.scm -o foo  # emit LLVM IR, link → ./foo native binary
kaappi --emit-llvm foo.scm     # write foo.ll and stop (inspect the IR)
```

`kaappi compile` with no `-o` derives the output name from the source:
`foo.scm` → `foo` (POSIX) or `foo.exe` (Windows).

The native binary is not self-contained Scheme — it is native code linked
against `libkaappi_rt.a`, which carries the garbage collector, the 692
built-in procedures, the value representation, and — importantly — an
embedded copy of the interpreter. Native code re-enters that interpreter
whenever it meets a form the backend chooses not to lower (see below). So
"compiled" means "the hot, lowerable core runs as native code; everything
else calls back into the VM," not "the interpreter is gone."

Two consequences a user will actually hit:

1. **`compile` is aarch64/x86_64 only.** On riscv64, s390x, ppc64le — and
   on any supported arch running an unsupported OS — `kaappi compile`
   refuses loudly with a message naming the architecture and pointing at
   the interpreter. `kaappi doctor` reports the same as a single WARN
   rather than a misleading PASS. This is deliberate (see the scope
   decision record), not an unfinished port.
2. **`import` in a compiled program only resolves libraries built into the
   runtime binary.** A native binary boots a fresh VM with no library
   search path and no bundled `.sld` sources, so if any import would
   resolve from a `.sld` file on disk, `kaappi compile` refuses at
   compile time (`error.UnresolvableLibraryImport`) rather than producing a
   binary that fails at startup. The alternatives are the interpreter, or a
   whole-program bundle via `zig build -Dbundle-src=<file>`.

## Reference-level design

### Component map

| File | ~Lines | Role |
|---|---:|---|
| `src/llvm_emit.zig` | 1303 | Core emitter (`LLVMEmitter`, `emitProgram`); walks all IR node types → LLVM IR text. Home of `targetTriple`, `native_backend_supported`, `fast_tailcalls_supported`, cached-eval / quoted-constant emission. |
| `src/llvm_emit_forms.zig` | 1239 | Native lowering of `cond`/`case`/`do` block-chains; `exprNativeEmittable`, `isRejectedFormHead`, `emitDo`. |
| `src/llvm_emit_freevars.zig` | 843 | Free-variable analysis (`collectFreeVars`, `sexprNeedsEvalFallback`). |
| `src/llvm_emit_lambda.zig` | 891 | Tiered lambda compilation; parameter boxing; rest-list construction. |
| `src/llvm_emit_let.zig` | 379 | Native `let`/`let*` (alloca + shadow-stack rooting); internal-define slots. |
| `src/llvm_emit_inline.zig` | 268 | Inline IR fast paths for `+ - * < = null?`; comptime `nanbox` encoding pulled from `types.zig`. |
| `src/llvm_emit_tailcall.zig` | 190 | Forward-reference reservation + finalization for mutual tail calls. |
| `src/runtime_exports.zig` | 501 | 28 C-ABI `export fn` runtime bridge functions. |
| `src/native_decls.zig` | 104 | LLVM type mapping (`toLLVM`, `zigTypeToLLVM`), inline-decl lookup. |
| `src/native_compiler.zig` | 637 | Driver: `emitLlvmFile`, `compileNative`, library/compiler discovery, refusal diagnostics. |

### CLI surface

The `compile` subcommand is defined in `src/cli_spec.zig:335` with
`.positional = .scm_file` and compile-specific flags limited to `-o`
(`.output`, `cli_spec.zig:265`) and `--lib-path`. Related but distinct
flags: `--compile` (`.compile`) writes bytecode `.sbc` — a *different*
pathway — and `--emit-llvm` (`.emit_llvm`) writes `.ll` text. Parsing in
`src/cli.zig` sets `native_compile_mode` for the subcommand (`cli.zig:141`),
`emit_llvm_mode` for `--emit-llvm` (`cli.zig:201`), and accepts `-o` after
the filename in compile modes (`cli.zig:243`).

### Driver flow (`native_compiler.zig`)

Both `--emit-llvm` and `kaappi compile` funnel through `emitLlvmFile`
(`native_compiler.zig:118`):

1. **Refuse-loudly gate** (`:127`) before any file I/O — see arch gating.
2. Read the whole source; loop per top-level form. `import` /
   `define-library` are **executed at compile time** via
   `vm.handleTopLevelForm` (`:222`); `define-syntax` / `define-record-type`
   are compiled *and* executed (`:232`). Each is also serialized as a
   passthrough node so its runtime effect is reproduced in the emitted
   program.
3. `scanSetTargetsWithoutMacros` pre-scan (`:247`), then `lowerAndOptimize`
   per form (`:249`). GC is deferred across the whole batch (`no_collect`,
   `:201`).
4. `LLVMEmitter.emitProgram` (`:284`) walks the lowered IR to LLVM IR text.

`compileNative` (`:328`) writes the `.ll` to a temp file
(`/tmp/kaappi_native_<pid>.ll`, unlinked after), links, and removes the
temp. Discovery:

- **`libkaappi_rt.a`** (`findLibDir`, `:411`): `KAAPPI_LIB_DIR` →
  `<exe_dir>/../lib` → `zig-out/lib` → `/usr/local/lib`. `~/.kaappi/lib` is
  **deliberately excluded**. Missing → `error.RuntimeLibraryNotFound`
  ("Build it with: zig build lib").
- **C compiler** (`cc_search_order`, `:28`): `{zig, cc, clang, gcc}`
  (`{zig, clang, cc, gcc}` on NetBSD, whose base `cc` is a GCC that rejects
  `.ll`). None → `error.NoCCompilerFound`.
- **Link command** (`tryLink`, `:525`):
  `<cc> [cc] -w -O2 <ll> -o <out> -L<libdir> -lkaappi_rt -lc -lm -lpthread`.
  Windows swaps `-lpthread` → `-lws2_32`; OpenBSD adds `-z nobtcfi`. `-O2`
  is load-bearing: the emitted IR is naive and relies on LLVM's
  mem2reg/instcombine. Success prints `Compiled <out>`.

### The C-ABI runtime contract

LLVM IR text cannot call Zig functions directly (Zig error unions and name
mangling are not C-ABI). `src/runtime_exports.zig` therefore exposes 28
`export fn` wrappers, all `callconv(.c)`, all passing `Value` as a plain
`u64`. This *is* the native-tier ABI; any change to it is a change to the
contract between emitted code and every prebuilt runtime library:

`kaappi_runtime_init` / `_deinit` / `_set_command_line_args`;
`_global_lookup` / `_define_global` / `_set_global`; `_make_string` /
`_intern_symbol`; `_create_native_closure`; **`_eval` / `_eval_cached` /
`_quote_cached`** (the fallback bridge); `_fixnum_add/_sub/_mul/_lt/_eq`;
`_car` / `_cdr` / `_cons` / `_is_null`; `_make_box` / `_box_ref` /
`_box_set`; `_call_scheme` / `_apply`; `_gc_push_root` / `_gc_pop_roots`.

Every native lambda shares one uniform signature:
`define i64 @lambda_N(ptr %vm, ptr %args, i64 %nargs, ptr %upvalues)`.

### Fallback-to-interpreter semantics

Forms the backend does not lower are serialized back to Scheme source and
run by the embedded interpreter. Two caches keep this from re-parsing every
time:

- **Code fallbacks** → `kaappi_eval_cached`: compiled once per call site,
  cached in a per-site global slot (#1494).
- **Quoted heap constants** → `kaappi_quote_cached`: the built value is
  cached (#1495).

Only the main runtime thread touches cache slots; child SRFI-18 threads
always take the plain, uncached `kaappi_eval` to avoid a cross-heap hazard.

Forms that fall back include `letrec` / `letrec*`, `guard`, quasiquote,
named `let`, internal `define` in bodies the backend can't scope, and any
`cond`/`case`/`do` whose clauses reach an unlowerable sub-form (#1496).

### Closures, boxing, tail calls

**Closures** use three tiers: a capturing lambda becomes `@closure_N` with
free variables (from `collectFreeVars`) copied by value into an `%upvalues`
array or chained from the enclosing closure's upvalues (#1410); a
closed/named lambda becomes `@lambda_N` with null upvalues and, if
top-level, a `native_fns` registration enabling direct calls; anything else
is eval fallback.

**Mutable captured variables** (#1497): a binding that is both captured and
mutated is assignment-converted to a heap box (`kaappi_make_box`, internally
a `(value . ())` pair); reads become `kaappi_box_ref`, `set!` becomes
`kaappi_box_set`, and a nested closure captures the box *pointer* by value —
by-location semantics that fix the earlier by-copy bug (#1422).

**Tail calls**: self-tail-recursion compiles to a loop (argument overwrite +
`br` to the body label; variadic self-calls rebuild the rest list first,
#1498). Mutual tail calls use `tailcc` + `musttail` (#1499): a fixed-arity,
non-variadic, non-boxed *named* function of arity ≤ `max_fast_arity` (= 8,
`llvm_emit.zig:99`) emits a `@name.fast` (`tailcc`, register args) plus a
`@name` uniform-ABI trampoline. `mustTailSafe` gates it (caller is a fast
entry, tail position, balanced shadow stack, no locals). Both are gated on
`fast_tailcalls_supported` (aarch64/x86_64 only).

**Continuations** are the hybrid strategy of the second decision record:
native code uses the C stack; `call/cc`,
`call-with-current-continuation`, `call-with-values`, and `eval` reach the
interpreter as whole passthroughs (stack-copying via
`vm_continuations.zig`), and force the enclosing frame to decline native
compilation (#1799).

### Arch gating (single source of truth)

`src/llvm_emit.zig:67`:

```zig
pub const native_backend_supported = targetTriple(cpu.arch, os.tag) != null;
```

`targetTriple` returns a concrete triple only for **aarch64 / x86_64** ×
`{macos, linux, windows-gnu, freebsd, openbsd, netbsd}`; everything else —
including a supported arch on an unsupported OS — returns `null`. Enforced
at:

- `native_compiler.zig:127` — `emitLlvmFile` refuses before any file I/O
  (`error.NativeBackendUnsupported`), printing `nativeUnsupportedMessage`
  (names the arch, points at the interpreter, names aarch64/x86_64). Covers
  both `kaappi compile` and `--emit-llvm`.
- `doctor.zig:361` — `kaappi doctor` emits one `arch` WARN instead of a
  misleading PASS.
- `fast_tailcalls_supported` (`llvm_emit.zig:20`) is a *separate* comptime
  switch gating only `tailcc`/`musttail`.

### Documented native-tier gaps

Beyond the fallback forms above, the following are known and intentional:

- **`import` of a `.sld`-backed library** is refused at compile time
  (#1743): a native binary's fresh VM has no search path and no bundled
  `.sld` sources.
- **Tail `(apply f xs)`** is not a real tail call across the runtime
  boundary — it grows the native stack where the interpreter is
  constant-space.
- **> 255 fixed parameters or upvalues** falls back (u8 arity/index,
  #1498).
- Bare variadic anonymous `(lambda args …)` and some variadic `define`
  values keep the interpreter-closure value.

### Tests

- `tests/scheme/compile/*.sh` — 27 per-issue regression scripts, each
  diffing the compiled binary against the interpreter as oracle.
- `tests/e2e/` — `run-e2e.sh`/`.ps1` build the runtime, verify each emitted
  `.ll` (`opt -passes=verify` / `llvm-as` / `zig cc -c`), compile at `-O2`,
  and diff 37 `programs/*.scm` plus a `kaappi-bdd` spec against the
  interpreter.
- Zig unit tests: `src/tests_native.zig` (incl. the strict
  `derived_exclusions` gate test), `tests_native_gate.zig`,
  `tests_native_dispatch.zig`, `tests_gc_runtime_stress.zig`,
  `fuzz_gen_native.zig`.

## Drawbacks

Writing an as-built KEP for a subsystem this large risks the document
drifting from the code: the backend changes often (recent releases
re-lowered lexical scope, #2117/#2118/#2211; rejected-form-head handling,
#1896). A stale KEP is worse than none if readers trust it. Mitigation: the
KEP records *contracts and decisions* (the C-ABI export set, the
fallback-cache split, the arch-support boundary, the continuation
strategy), which change rarely, and pins line-level references to a commit;
it is not a mirror of the emitter's form-by-form lowering, which the
architecture doc already tracks.

There is also a scope question: this KEP deliberately treats the two
existing decision records as inputs rather than superseding them. That
keeps three documents in play. The alternative — folding them in and
retiring the `.md` files — is discussed below.

## Alternatives considered

- **Leave it at the dev-doc + decision records.** The status quo. Rejected
  because those documents are not part of a numbered, reviewable process:
  the arch-scope and continuation decisions are exactly the cross-cutting,
  user-affecting calls the KEP index is meant to make discoverable, and a
  future proposal to (say) add riscv64 support or change the fallback ABI
  has nothing to amend.
- **Fold the decision records into this KEP and delete them.** Rejected for
  now. The decision records are dense, self-contained, and linked from
  code comments; this KEP cites them as normative inputs and consolidates
  their *conclusions* into the index, without breaking those links. If the
  KEP is accepted, migrating them can be a follow-up.
- **Split into three KEPs** (backend architecture, arch-support policy,
  continuation strategy). Rejected as over-fragmentation: the arch boundary
  and the continuation fallback are only comprehensible in terms of the
  runtime tether they both serve. One KEP with three referenced decisions
  keeps the whole picture in one place.
- **Wait until the backend stabilizes.** Rejected: "stable enough to
  document" has no trigger, and the most valuable thing to record — why
  `compile` is arch-limited — is already settled and already causing user
  questions.

## Cross-platform / compatibility impact

This KEP documents; it changes no behaviour. The compatibility facts it
records:

- `kaappi compile` and `--emit-llvm` are supported on aarch64/x86_64 across
  macOS, Linux, Windows (gnu), FreeBSD, OpenBSD, NetBSD. All other
  arch/OS combinations refuse loudly and remain interpreter-tier.
- The WASM target (`wasm32-wasi`) is interpreter-only; it is out of scope
  here and a candidate for its own KEP.
- The native-tier ABI (`runtime_exports.zig`, 28 C-ABI functions, `Value`
  as `u64`) is a compatibility contract between an emitted binary and the
  `libkaappi_rt.a` it links against. Emitted `.ll` and the runtime library
  must come from the same version.
- Native and interpreter tiers are expected to be observationally
  equivalent for supported programs; the test suites enforce this by using
  the interpreter as the native tier's oracle.

## Unresolved questions

1. **Should the two decision records be superseded by this KEP, or remain
   standalone and merely referenced?** (Affects whether code comments that
   link them need updating.)
2. **Is "Informational" the right Type, or should an as-built KEP that
   freezes a compatibility contract (the C-ABI export set) be "Standards"?**
   KEP-0008 chose Standards for a shared contract; the parallel is close.
3. **What is the change-control expectation for the C-ABI export set?**
   Should adding/removing a `runtime_exports.zig` function require a KEP
   amendment, or only a CHANGELOG entry?
4. **Does the WASM target belong in a sibling KEP**, and if so should the
   two cross-reference each other as the two non-default execution targets?
5. **riscv64 as the designated pathfinder** (per the scope record): if/when
   a concrete user need arises, does adding an architecture become a KEP in
   its own right, or an amendment here?

## Implementation plan

This KEP is retroactive; there is no code to write. The "implementation" is
documentation and process alignment:

1. **Land this KEP as Draft** and open it for review against the pinned
   `395e9d6e` source.
2. **Reconcile the dev-doc.** Add a pointer from
   `docs/dev/llvm-backend.md` and both decision records to this KEP as the
   canonical, numbered summary of their conclusions.
3. **Resolve the Type and change-control questions** (Unresolved 2–3); if
   the C-ABI export set is deemed a frozen contract, record the expectation
   that changes to it are noted here.
4. **Publish a user-facing note** on `kaappi.github.io` (download /
   conformance pages) stating the aarch64/x86_64 boundary for `kaappi
   compile`, linking this KEP as the rationale.
5. **On acceptance**, decide the decision-record disposition (Unresolved 1)
   and, if superseding, migrate their content and update code links.
