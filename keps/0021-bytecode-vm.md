# KEP-0021: The Register-Based Bytecode VM

| Field | Value |
|-------|-------|
| **KEP** | 0021 |
| **Title** | The Register-Based Bytecode VM |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/vm.zig`, `src/vm_dispatch.zig`, `src/vm_dispatch_helpers.zig`, `src/vm_calls.zig`, `src/vm_continuations.zig`, `src/vm_eval.zig`, `src/fiber.zig`, `src/types.zig`, `src/types_continuation.zig`, `src/errors.zig`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. `docs/dev/bytecode.md`
is the ISA's single source of truth and matches source exactly; the two
continuation/self-tail-call decision records under `docs/dev/decisions/`
are cited as inputs.*

## Scope

This KEP specifies the **execution engine** — the register-based bytecode VM
that runs the instructions the compiler emits. It defers, by reference:

- **The bytecode emitter** that produces the instructions →
  [KEP-0020](0020-ir-and-bytecode-emission.md). This KEP is *execution*; the
  calling convention it and the emitter agree on is documented from the
  execution side here and the emission side there.
- **`.sbc` serialization** → [KEP-0014](0014-sbc-bytecode-format.md). The VM
  runs in-memory `Function`s; the on-disk format is KEP-0014's.
- **Value representation and the GC mechanism** →
  [KEP-0017](0017-gc-and-value-model.md). The VM's *contribution* to GC —
  marking its live registers and frames — is recorded here; the collector
  is not.
- **Cross-thread channels and multi-core scheduling** →
  [KEP-0002](0002-cross-thread-channels.md). The *single-threaded*
  fiber/continuation execution model is in scope; cross-thread coordination
  (`stopForCollection`, `initForThread` sharing, channels) is deferred.
- **The event-loop reactor** → [KEP-0001](0001-event-loop-reactor.md). The
  VM's I/O *parking* mechanism is noted; the reactor's design is not.
- **Diagnostic code shape** (`KP3xxx`) → [KEP-0005](0005-diagnostic-contract.md).
  Only the VM's runtime error *conditions* are recorded here.
- **FFI "in native" collection state** → [KEP-0011](0011-ffi-and-sandbox.md).

## Summary

Kaappi executes a **register-based bytecode** on a stop-and-go interpreter
loop. The ISA is exactly **31 opcodes** (values 0–30, comptime-asserted),
each a 1-byte opcode plus big-endian operands; instructions address a flat
register file windowed per call frame, not a value stack. The dispatch loop
(`runUntil`) is a classic `switch` over the opcode enum with a
per-1024-instruction safepoint for the watchdog, GC, and fiber termination.
Calls follow a base-register convention (operator in `base`, args in the
registers after it); three tail opcodes reuse the current frame in place so
proper tail recursion runs in constant space, and `self_tail_call` turns
direct self-recursion into a bare loop. First-class continuations are
**full, multi-shot, stack-copying**, with an O(1) escape-continuation
fast path and `dynamic-wind` transition handling. Cooperative fibers each
carry a full swappable execution state and park on I/O by rewinding the
instruction pointer. This register VM is kaappi's original and only
execution model — no stack VM preceded it, and it remained the primary
execution path when the JIT was replaced by the LLVM backend (KEP-0010).

This is a retroactive, *as-built* KEP and the closing piece of the
pipeline series: it documents the stage every other pipeline KEP feeds
into. Its value is to record the ISA as a numbered contract, the frame/
register execution model, the calling convention from the execution side,
the continuation and fiber mechanisms, the dynamic-state stacks, and the
catchable-vs-uncatchable runtime error taxonomy — pinning what the emitter
(KEP-0020) and the value/GC substrate (KEP-0017) build around.

## Motivation

The VM is where every earlier stage's output finally runs, and several of
its properties are contracts or subtle designs worth a written record:

- **The ISA is a contract, and the opcode count was even mis-stated.** The
  instruction set is exactly 31 opcodes — a `comptime` guard in
  `types.zig:1406` hard-asserts `fields.len == 31` and names every doc that
  quotes the count. (A naive enum count returns 30; that is the error.)
  Recording the ISA as a numbered contract, tied to that comptime assertion,
  fixes the record and pins what KEP-0020 emits and KEP-0014 serializes.
- **Proper tail calls and multi-shot continuations are correctness
  guarantees, not optimizations.** R7RS *requires* constant-space tail
  recursion, and Kaappi delivers it by reusing the frame in place (three
  tail opcodes, plus a `self_tail_call` loop). Continuations are full and
  re-entrant via stack copying, with a separate O(1) escape path and
  `dynamic-wind` transition handling. Both have standalone decision records
  already; a KEP consolidates them into the execution contract.
- **The runtime error taxonomy has a load-bearing distinction.** Some errors
  are *catchable* (the ones `guard` exists for — type errors, arity
  mismatches, undefined variables, division by zero) and some are
  deliberately *uncatchable* resource limits (stack overflow, execution
  timeout) that must reach the top level rather than be swallowed by a
  handler. That catchable/uncatchable line is a real semantic contract
  encoded in `errors.zig`, and it deserves to be stated.
- **The single-threaded fiber model is an execution feature in its own
  right.** Cooperative fibers, the run-queue scheduler, and I/O parking via
  instruction-pointer rewind are how Kaappi does concurrency before any
  cross-thread machinery (KEP-0002) enters. Recording the single-thread
  model cleanly separates it from the multi-core dimension.

## Guide-level explanation

The VM is the last stage: it runs the bytecode the compiler produced. It is
a **register machine**, not a stack machine — each function gets a window of
numbered registers, and instructions name their operands
(`load_const dst, idx`, `call base, nargs`, `return src`) rather than
pushing and popping. The main loop fetches one instruction, decodes it,
executes it, and repeats, checking a watchdog every 1024 instructions so a
runaway program can be stopped by a time or instruction budget.

What a Scheme programmer feels through it:

- **Tail calls don't grow the stack.** A function that calls itself (or
  another) in tail position reuses its frame, so loops written as recursion
  run forever in constant space — as R7RS requires.
- **`call/cc` really captures the whole computation.** Continuations are
  first-class and can be invoked any number of times; the VM snapshots and
  restores the register/frame state. `dynamic-wind` before/after thunks fire
  correctly when a continuation jumps in or out. A lighter `call/ec` escape
  form is used when a continuation only ever escapes outward.
- **Concurrency is cooperative fibers.** Thousands of lightweight fibers
  share one thread; a fiber that blocks on I/O parks and yields to others,
  resuming exactly where it left off.
- **Errors either can or cannot be caught.** Ordinary program faults (wrong
  type, wrong argument count, unbound variable, divide by zero) are
  catchable with `guard`. Resource limits — running out of stack, hitting a
  time limit — are *not* catchable; they stop the program at the top level
  so a handler can't accidentally hide them.

## Reference-level design

### The ISA (31 opcodes)

`OpCode` is an `enum(u8)` (`types.zig:1359`) with **31 variants, values
0–30**, and a `comptime` assertion (`types.zig:1406`) that hard-fails if the
count changes. The set:

```
0  load_const       dst, idx           16 jump_false       test, offset:i16
1  load_nil         dst                 17 jump_true        test, offset:i16
2  load_true        dst                 18 closure          dst, idx, {is_local:u8,index:u16}*
3  load_false       dst                 19 cons             dst, car, cdr
4  load_void        dst                 20 push_handler     handler_reg
5  move             dst, src            21 pop_handler
6  get_global       dst, sym_idx        22 halt
7  set_global       sym_idx, src        23 call_global      base, sym_idx, nargs:u8
8  define_global    sym_idx, src        24 tail_call_global base, sym_idx, nargs:u8
9  tail_apply       base, nargs:u8      25 box_local        reg
10 get_upvalue      dst, idx            26 get_box_local    dst, reg
11 set_upvalue      idx, src            27 set_box_local    reg, src
12 call             base, nargs:u8      28 self_tail_call   base, nargs:u8
13 tail_call        base, nargs:u8      29 tail_call_cc     base, dst
14 return           src                 30 tail_eval        base, nargs:u8
15 jump             offset:i16
```

**Encoding**: a 1-byte opcode, big-endian `u16` operands (registers,
constant indices, symbol indices), `i16` jump offsets (bitcast `u16`,
relative to the instruction *after* the jump), and `u8` only for `nargs` and
the `is_local` flag in `closure` capture descriptors. A `closure` opcode is
followed by `upvalue_count × 3` bytes of `{is_local:u8, index:u16}`
descriptors. The authoritative operand-width table is the inline
`fixed_operand_bytes` switch in `runUntil` (`vm_dispatch.zig:137`) —
validated by `ensureOperands`; `bytecode.md` mirrors it exactly (it is a
switch, not a named constant). Serialization of all this is KEP-0014's.

### The dispatch loop

`runUntil(target_frame_count, target_wind_count)` (`vm_dispatch.zig:74`) is
the interpreter. It loops `while frame_count > target_frame_count` —
executing until the frame stack unwinds to a caller-specified depth — with a
classic `switch (op)` dispatch (not computed-goto or tail-threading). Each
iteration: read the opcode at `frame.ip` (bounds- and range-checked →
`InvalidBytecode`), advance `ip`, compute the operand width, validate it,
and execute the case. The program counter is per-frame (`CallFrame.ip`, a
byte offset). Every 1024 instructions a **safepoint** runs
(`vm_dispatch.zig:100`): checks the thread-terminate flag (→ `Terminated`),
the GC safepoint (`stopForCollection`, cross-thread → KEP-0002), and the
wall-clock `timeout_deadline_ns` / `instruction_limit` (→ `ExecutionTimeout`).

Dispatch fast paths: fused `call_global`/`tail_call_global` (opcode + global
lookup in one instruction); a per-function inline **global cache**
(`func.global_cache`, validated against `vm.global_version`); and
`self_tail_call`, which skips global lookup, type check, and arity check.

### Frame and register model

The `VM` struct (`vm.zig:358`) holds four heap-allocated, geometrically
growing stacks (#1886): a flat `registers: []Value` file, `frames:
[]CallFrame`, a `handler_stack`, and a `wind_stack`. Hard caps:
`MAX_FRAME_LIMIT = 32768`, `MAX_REGISTER_LIMIT = 65536`,
handler/wind = 32768; exhausting any raises the uncatchable stack-overflow
condition.

A `CallFrame` (`types_continuation.zig:84`) carries `closure`, `code`, `ip`,
`base` (this frame's register-window start), `dst` (caller-relative register
to receive the return value), `saved_wind_count`, `returns_to_native`, and a
monotonic `seq` birth id. **Registers map to frame slots** as
`registers[frame.base + reg]`; a frame's window is `func.locals_count` (or
256 for native/top frames). There is **no separate value stack** — this is a
pure register machine; intermediate results live in named registers, which
is why the emitter can map IR results to register lifetimes (KEP-0020) and
the design supports register-lifetime-based TCO.

**GC-root contribution** (the collector itself is KEP-0017): `markVMRoots`
(`vm.zig`) marks, per live frame, `registers[base .. base+window]`, plus
each handler value, each wind record's thunks, the current exception, and
parameter overrides. The `CollectionState` enum (`running`, `parked`,
`stopped`, `in_native`) gates when a collector may safely read a VM's frames
— `.running` means registers may change, so they are never marked in that
state; the safepoint spins between instructions so marking races nothing.
(Cross-thread coordination is KEP-0002.)

### Calling convention (execution side)

At `call base, nargs`, `registers[base]` holds the callee and args occupy
`registers[base+1 …]`; the callee frame's `base` becomes `caller_base + 1`,
so the callee value is its own r0 and args are r1…. `callValue`
(`vm_calls.zig:452`) dispatches on callee type — closure (checked first),
`NativeFn`, `NativeClosure`, `FfiFunction` (KEP-0011), `ParameterObject`
(0 args read, 1 arg set), `Guardian`, `Continuation` — raising
`NotAProcedure` otherwise. `callClosure` does the arity check (exact, or
`nargs ≥ min` for variadic, building the rest list), scrubs unused window
slots to undefined, and pushes the frame with `dst = base − caller.base`.
`callNative` passes `registers[base+1 …]` as a slice straight to the Zig
function pointer and stores the result at `registers[base]`. A native
primitive that re-enters the VM (map/for-each/sort, exception handlers) goes
through `callReentrant`/`callWithArgs`/`callThunk`/`callHandler`, which pick
a fresh base above the current window and set `returns_to_native` so a bare
`return` into a native-owned frame is caught (`raiseDeadNativeReturn`).

### Tail calls (constant-space TCO)

Three tail opcodes reuse the current frame *in place* rather than pushing a
new one:

- **`tail_call`** copies the args down to `frame.base`, resizes the window
  for the new callee (`ensureTailWindow`, #2035), then overwrites
  `frame.closure`/`code`/`ip = 0` — same frame, new function.
- **`self_tail_call`** copies args down and sets `frame.ip = 0` — a pure loop
  back to the top of the *same* function, skipping global lookup, type, and
  arity checks (rationale in `docs/dev/decisions/self-tail-call-optimization.md`;
  used for direct self-recursion and named-`let` loops).
- **`tail_call_global`**, and the receivers of `tail_call_cc` and
  `tail_eval`, likewise replace the frame in place.

This is the mechanism behind R7RS proper tail recursion.

### Continuations

Continuations are **full, multi-shot, re-entrant, and stack-copying**
(`vm_continuations.zig`; rationale in
`docs/dev/decisions/continuation-strategy.md`). `captureContinuation`
snapshots `registers[0..max_reg]` (a tight bound over live frame windows,
with dead inter-window gaps scrubbed, #1464), all frames as `SavedFrame[]`,
and the handler and wind stacks, recording the destination register. Capture
is driven by the `tail_call_cc` opcode. `restoreContinuation` `@memcpy`s the
snapshot back, delivers the value, and bumps a generation counter — so a
continuation can be invoked any number of times, each restoring the snapshot
afresh. Invocation propagates `VMError.ContinuationInvoked` up the Zig stack;
each call site checks whether the restored state resumes in *this*
`runUntil`'s scope-root frame (by frame `seq`) and either continues the loop
or re-propagates.

A separate **escape continuation** (`call/ec`) records only stack depths
(O(1), no snapshot); invoking it unwinds the live stack to the capture
point, runs the intervening `dynamic-wind` after-thunks, and delivers the
value — erroring if invoked outside its dynamic extent. `dynamic-wind`
transitions across any continuation jump are handled by
`performWindTransition`, which runs after-thunks down to the common wind
prefix and before-thunks back up to the target. Multiple values flow through
a `MultipleValues` type. (The native backend side-exits to this VM for
`call/cc`; that fallback is KEP-0010's.)

### Fibers (single-threaded cooperative concurrency)

A `Fiber` (`fiber.zig:39`) carries a *full swappable execution state* — its
own registers, frames, handler/wind stacks, current exception, continuation
state, and fiber-local parameter overrides — plus status, thunk, result, and
I/O parking fields. Initial per-fiber capacities are deliberately tiny
(256 registers, 32 frames) since thousands may be live; they grow
geometrically. The single-threaded `FiberScheduler` (`fiber.zig:144`) runs a
run queue of fiber slots; `spawnFiber` adds one, and `saveCurrentFiber` /
`restoreFiber` swap the VM's live arrays into and out of the current fiber.
A blocking primitive parks by returning `error.Yielded`; the dispatch loop
rewinds `ip` to the start of the instruction so it re-executes on
reschedule. (Reactor-based I/O readiness is KEP-0001; cross-thread SRFI-18
is KEP-0002.)

### Dynamic state

- **`dynamic-wind`**: a `wind_stack` of `{before, after}` records; on normal
  return, winds above the frame's `saved_wind_count` are unwound
  (after-thunks run), and on uncaught error `execute` runs all pending
  after-thunks while preserving the error detail.
- **`parameterize`**: a `param_overrides` map on the VM (and per-fiber), with
  `ParameterObject`s carrying an optional converter, handled in `callValue`.
- **Exceptions**: a `handler_stack` of `{handler, frame_count, sticky}`,
  pushed/popped by `push_handler`/`pop_handler`; `raise` /
  `with-exception-handler` / `guard` drive through `callHandler`, with
  `current_exception` holding the in-flight condition and
  `VMError.ExceptionRaised` signalling it. Sticky handlers (SRFI-248) stay
  armed so a captured continuation can re-enter them.

### Globals and runtime environment

Globals are a shared `StringHashMap(Value)` (symbol name → value) guarded by
a read/write lock. `get_global`/`set_global`/`define_global` (and the fused
`call_global`/`tail_call_global`) resolve through a per-function
`global_cache` validated by `vm.global_version`; `define_global` bumps the
version to invalidate every cache. A miss falls to `lookupGlobalLocked`;
undefined raises the undefined-variable condition (with a nearest-name
suggestion). Library/restricted environments resolve through def-env
binding-prefix symbols and are deliberately *not* cached under
`global_version` (#1812).

### Runtime error conditions (diagnostic shape deferred to KEP-0005)

The `KaappiError` set (`errors.zig:1`): `StackOverflow`, `TypeError`,
`ArityMismatch`, `UndefinedVariable`, `NotAProcedure`, `OutOfMemory`,
`InvalidBytecode`, `DivisionByZero`, `CompileError`, `ExceptionRaised`,
`ContinuationInvoked`, `IndexOutOfBounds`, `InvalidArgument`, `Yielded`,
`ExecutionTimeout`, `Terminated`. The **catchable/uncatchable distinction**
(`isUncatchable`, `errors.zig:49`) is a real semantic contract:
`StackOverflow` and `ExecutionTimeout` are resource limits and are
*uncatchable* — reported at the top level, never delivered to a `guard`
clause — as are the `Terminated`/`Yielded` control signals; `OutOfMemory`
stays catchable by design; and the genuine program faults (`TypeError`,
`ArityMismatch`, `UndefinedVariable`, `DivisionByZero`, `NotAProcedure`,
`IndexOutOfBounds`, `InvalidArgument`) stay catchable — the whole point of
`guard`. Errors propagate as Zig error returns up `runUntil` → `run` →
`execute`, which truncates GC roots, captures a stack trace, runs pending
wind after-thunks, and records the diagnostic code; `setErrorDetail` fills
the message/line/col/source detail channel. The watchdog
(`timeout_deadline_ns` wall clock, the `--max-time` surface, and an
`instruction_limit` for stress/fuzzing) fires at the 1024-instruction
safepoint. The `KP3xxx` code/JSON shape is KEP-0005's.

### Native primitive dispatch

The 692 built-ins are `NativeFn`s (`*const fn([]const Value) anyerror!Value`
plus an `Arity`). `callNative` arity-checks, passes the arg slice to the Zig
function, and maps any returned error through `mapNativeError` into a
`KaappiError` plus a detail message. Higher-order primitives drive their
callbacks *back through the dispatch loop* (via the re-entrant call helpers),
not the Zig stack — and because a re-entrant call may grow `self.frames` and
invalidate a held `frame` pointer, the loop re-reads frame fields around
such calls.

### Entry points and lifecycle

`VM.init(gc)` sets up the stacks; `execute(vm, func)` (`vm_calls.zig:170`)
builds a top-level closure, pushes frame 0, and calls `run` → `runUntil(0,0)`;
`runWithScheduler` is the fiber-driven variant. The top-level eval loop
(`vm_eval.zig`) classifies each form via `topLevelHead` / `runTopLevelHead`
— the same compile-vs-run classification shared with `check` and the LSP —
and handles the `.sbc` cache path (KEP-0014). This register VM is kaappi's
original and only execution model; no stack VM preceded it, and it remained
the primary execution path when the JIT was replaced by the LLVM backend
(KEP-0010).

### Tests

Zig units: `tests_continuations.zig`, `tests_tail_calls.zig`,
`tests_fibers.zig`, `tests_exceptions.zig`, `tests_native_dispatch.zig`, and
the `vm_tests.zig` aggregator. Scheme suites under `tests/scheme/`:
`continuations/` (correctness, multishot, nested, re-entrant escape,
set!-store, `call/ec`), plus `errors/`, `r7rs/`, `compliance/`, `srfi/`,
`robustness/`, `differential/`, `smoke/`. The continuation decision record
pins the `continuations/` suite as the conformance gate.

## Drawbacks

The VM is the largest and most safety-critical subsystem, and it changes
(the growable stacks #1886, the in-place tail-frame reuse #2035, fiber
parking). An as-built KEP risks drift. Mitigation: it records the *contracts
and invariants* — the 31-opcode ISA (tied to the comptime assertion), the
calling convention, the TCO guarantee, the multi-shot continuation model,
the catchable/uncatchable taxonomy — which are stable, and pins line
references; the exhaustive opcode/operand table stays in `bytecode.md`.

Documenting the ISA in a numbered KEP could imply it is a stable public
interface. It is not — the opcode set is internal and versioned in lockstep
with the compiler (KEP-0014's `compilerHash` rejects cross-version
bytecode). The Unresolved questions ask whether any of it should stabilize;
the record's job is to state the current internal contract precisely.

## Alternatives considered

- **Leave it to `bytecode.md` + the decision records.** `bytecode.md` is
  excellent on the ISA but scoped to the instruction encoding; it says little
  about the frame model, the calling convention, continuations, fibers, or
  the error taxonomy, and the two decision records cover only continuations
  and self-tail-calls. A KEP consolidates the whole execution engine and ties
  it into the pipeline index.
- **Fold the VM into KEP-0020 (emitter).** Rejected: emission and execution
  are distinct concerns that merely share the calling convention and ISA.
  KEP-0020 owns turning IR into instructions; this owns running them. They
  cross-reference the shared convention from their two sides.
- **Fold continuations/fibers into KEP-0001/0002.** Rejected: KEP-0001 owns
  the reactor and KEP-0002 the cross-thread/channel dimension, but the
  *single-threaded* continuation and fiber execution mechanisms are core VM
  behaviour that those KEPs build on. This KEP references them for the I/O
  and multi-core dimensions and keeps the execution model here.
- **Split the ISA, the execution model, and continuations into three KEPs.**
  Rejected as over-fragmentation: the frame model, the calling convention,
  and continuation capture are one interlocking design (capture snapshots the
  frames the convention builds), and the ISA is only meaningful in terms of
  what the loop does with it.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- The 31-opcode ISA, the register/frame model, the calling convention, and
  the TCO and continuation semantics are identical on every platform; the VM
  is the one execution path shared by all targets (the native backend,
  KEP-0010, is a second *emission* target that falls back to this VM for
  `call/cc`).
- The bytecode ISA is an internal, same-version contract (KEP-0014's
  `compilerHash` rejects cross-version bytecode), not a public interface.
- The catchable/uncatchable error taxonomy and the watchdog limits behave
  identically across platforms.
- The single-threaded fiber/continuation model is platform-independent;
  reactor-backed I/O readiness (KEP-0001) and cross-thread scheduling
  (KEP-0002) layer on top without changing the execution contract.
- The VM's GC-root marking is its contribution to the collector (KEP-0017);
  it is uniform across platforms.

## Unresolved questions

1. **Should the ISA ever be a stable contract?** The comptime `== 31`
   assertion and `compilerHash` currently assume the opcode set can change
   freely between builds. Is "internal, same-version only" the permanent
   stance, or should the ISA gain a documented stability/versioning policy?
2. **The dispatch model** is a `switch`, not computed-goto or tail-threading.
   Is that the intended long-term design, or a performance avenue worth a
   future proposal (and would it change anything observable)?
3. **The stack caps** (32768 frames, 65536 registers, 32768 handlers/winds):
   fixed contracts or tunables, and is the uncatchable stack-overflow at
   those limits part of the compatibility surface?
4. **Stack-copying continuations** are O(stack) per capture/invoke. Is that
   the permanent strategy, or is a segmented/delimited approach ever in scope
   (the decision record rejected segmented stacks — should that be revisited
   as a numbered question)?
5. **The catchable/uncatchable taxonomy**: is the current partition
   (resource limits uncatchable, program faults catchable, `OutOfMemory`
   catchable-by-overload) the intended permanent contract, and should it be
   documented as a `guard` guarantee?
6. **Fiber-local vs VM-level dynamic state**: parameters exist at both fiber
   and VM scope. Is that layering the intended model, or worth consolidating?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Reconcile the docs**: point `bytecode.md` and the two decision records
   at this KEP as the consolidated execution reference, and write the first
   `docs/dev/vm.md` (frame model, calling convention, error taxonomy) seeded
   from this KEP's reference section.
3. **Decide the ISA-stability and dispatch-model questions**
   (Unresolved 1–2), and if the ISA is deemed a frozen internal contract,
   record the versioning expectation alongside KEP-0014's `compilerHash`.
4. **Document the catchable/uncatchable taxonomy as a `guard` guarantee**
   (Unresolved 5), since it is a user-visible semantic contract.
5. **Cross-link KEP-0020** (emitter / calling-convention counterpart),
   **KEP-0014** (serialization), **KEP-0017** (values/GC roots),
   **KEP-0001/0002** (reactor / cross-thread), and **KEP-0010** (native
   fallback) from the `vm*.zig` files and this KEP so the execution engine's
   boundaries are discoverable from code.
6. **On acceptance**, triage the stack-cap, continuation-strategy, and
   dynamic-state questions (Unresolved 3–4, 6) into tracked issues so future
   VM work amends this KEP rather than the scattered docs.
