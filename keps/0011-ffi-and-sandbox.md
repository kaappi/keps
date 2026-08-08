# KEP-0011: The FFI Subsystem and the Sandbox Boundary

| Field | Value |
|-------|-------|
| **KEP** | 0011 |
| **Title** | The FFI Subsystem and the Sandbox Boundary |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/ffi.zig`, `src/ffi_callback.zig`, `src/primitives_ffi.zig`, `src/types_ffi.zig`, `src/cli_spec.zig`, `src/cli.zig`, `src/primitives.zig`, `src/library.zig`, `src/vm_library.zig`), `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against that source as of
2026-08-08. Unlike most kaappi subsystems, the FFI layer has **no
dedicated `docs/dev/` design document**; this KEP is its first written
design record.*

## Summary

Kaappi has a C foreign-function interface — `(kaappi ffi)`, providing
`ffi-open`, `ffi-fn`, `ffi-callback`, and friends — that loads shared
libraries with `dlopen`, marshals 18 C types across the Scheme/C boundary,
and can hand a Scheme closure to C as a raw function pointer. It also has a
`--sandbox` flag that restricts filesystem, process, thread, and FFI
access. The two are inseparable by design: FFI is the widest hole in the
runtime's safety model — it puts raw, un-GC'd pointers into Scheme values
and executes arbitrary native code — and sandbox mode is the mechanism that
closes that hole. Both shipped in the **initial 0.1.0 release**
(2026-06-23) and have been hardened repeatedly since. Neither has a KEP,
and FFI has no design doc at all.

This is a retroactive, *as-built* KEP covering both together. It documents
the FFI API surface and type system, the `dlopen` search path, the
callback trampoline model and its hard limits, the exact ways FFI
intersects the GC and the per-thread heap model, and the two-layer
mechanism by which `--sandbox` disables FFI and the other capabilities. It
proposes no behavioural change. Its purpose is to turn a security boundary
that is currently *enforced by scattered code and an escape-test script*
into a written, reviewable contract.

## Motivation

Two facts make this the most under-documented KEP-worthy subsystem in the
tree:

1. **FFI breaches the memory model and the security model, and has zero
   written design.** Every other large subsystem — the IR, the bytecode
   format, the native backend, the diagnostic contract — has a
   `docs/dev/*.md`. FFI has none. Yet it is the one place where a Scheme
   value is a raw `*anyopaque`, where a bad argument is undefined
   behaviour rather than a Scheme error, and where the runtime executes
   code it did not compile. A subsystem whose *whole job* is to leave the
   safe subset deserves an explicit statement of what it does and does not
   guarantee.

2. **The sandbox is a capability model whose enforcement is spread across
   at least eight files, with two different mechanisms.** `--sandbox` is
   asserted by a pre-scan in `cli.zig`, then enforced partly by *excluding
   primitives at registration time* (`primitives.zig`, `library.zig`,
   `primitives_filesystem.zig`, `primitives_io.zig`, `primitives_srfi18.zig`),
   partly by a *runtime file-load block* (`vm_library.zig`), and partly by
   *runtime guards* inside the FFI primitives themselves
   (`primitives_ffi.zig`). The only place the whole policy is written down
   as a single intent is a shell escape-test
   (`tests/scheme/sandbox/sandbox-escape.sh`). A security boundary defined
   by "read these eight files and one test script" is exactly what a KEP
   should consolidate.

The two belong in one document because the sandbox's most security-relevant
job is disabling FFI, and FFI's safety story is incomplete without stating
that sandbox mode is how an operator opts out of it. Splitting them would
document the hole and the plug separately.

## Guide-level explanation

### Calling C from Scheme

```scheme
(import (kaappi ffi))

(define libm (ffi-open "m"))                    ; dlopen, with suffix search
(define c-sqrt (ffi-fn libm "sqrt" '(double) 'double))
(c-sqrt 2.0)                                     ; => 1.4142135623730951
(ffi-close libm)
```

`(ffi-open #f)` opens the default process handle — every already-linked
symbol, including libc. An `ffi-fn` value is *applied like a procedure*; the
actual C call happens inside the runtime, not through a separate "call"
primitive.

Passing Scheme to C as a callback:

```scheme
(define cb (ffi-callback (lambda (a b) (+ a b)) '(int int) 'int))
;; hand `cb` to C code expecting an `int(*)(int,int)`
(ffi-callback-release cb)                        ; free the trampoline slot
```

### The sandbox

```bash
kaappi --sandbox untrusted.scm
```

Under `--sandbox`, the program cannot open files, spawn processes, start OS
threads, load libraries from disk, or use FFI. It gets a reduced but useful
Scheme: pure computation, plus fiber-based concurrency that degrades
gracefully (`processor-count` reports `1`; the parallel pool falls back to
fiber workers). The restrictions are not opt-in per call — the dangerous
procedures are simply *not present*, so touching one is an ordinary
"undefined variable" error, and FFI additionally refuses at runtime even if
a binding is smuggled in.

The mental model: **FFI is the escape hatch from the safe language;
`--sandbox` welds it shut, along with the other OS-facing capabilities.**

## Reference-level design

### FFI: Scheme-level API

Registered in the `(kaappi ffi)` library (canonical tag `kaappi.ffi`).
Every spec is `.sandbox = false, .wasm = false` (`primitives_ffi.zig:13`).

| Procedure | Signature | Behaviour | Location |
|---|---|---|---|
| `ffi-open` | `(ffi-open path-or-#f)` | `dlopen`; `#f` = default process handle. Returns an `ffi-library`. | `primitives_ffi.zig:102` |
| `ffi-fn` | `(ffi-fn lib "name" '(param-types) 'ret-type)` | `dlsym` + build an `FfiFunction`. Max 16 params declared, **5 callable** (see below). | `:220` |
| `ffi-close` | `(ffi-close lib)` | `dlclose`, null the handle. | `:282` |
| `ffi-callback` | `(ffi-callback proc '(params) 'ret)` | Wrap a closure as a C function pointer via a fixed trampoline slot. | `:294` |
| `ffi-callback-release` | `(ffi-callback-release cb)` | Free the slot, mark inactive. | `:333` |
| `ffi-callback?` | predicate | | `:345` |
| `ffi-bytevector-ptr` | `(ffi-bytevector-ptr bv)` | Bytevector data pointer as an integer (0 if empty). | `:350` |

The C invocation itself is `callFfi` (`ffi.zig:452`).

### FFI: type system

`FfiType` (`types_ffi.zig:9`) is an 18-variant enum: `int` (c_int/i32),
`long` (c_long/i64), `double` (f64), `float` (f32), `string`
(`[*:0]const u8`), `pointer` (`*anyopaque`), `void`, `bool` (c_int 0/1),
`char` (u8), `size_t` (usize), and the fixed-width `int8/16/32/64` and
`uint8/16/32/64`. Symbol→enum parsing is `parseType`
(`primitives_ffi.zig:384`).

Marshaling lives in `ffi.zig`:

- **Argument validation**: `validateArgsDetailed` (`:269`) produces
  `'{name}': argument {d} must be {type}, got {type}`; strings are capped at
  4095 bytes (`:301`) and embedded NUL is rejected (`:307`); narrow ints are
  range-checked (`checkNarrowIntRange`, `:240`).
- **Type collapsing**: `normalizeType` (`:212`) folds the 18 types onto 7
  canonical classes (`int/long/double/float/string/pointer/void`). On
  LLP64/Windows, C `long` routes through the 32-bit `.int` class.
- **Scheme→C**: `toCString` (4096-byte stack buffer, `:121`),
  `marshalToPointer` (accepts fixnum, bignum, ffi-callback, bytevector,
  `:183`), `normalizeBoolArgs` (coerces bool args to exactly `#t`/`#f`
  before the C `_Bool` trampoline, avoiding a UBSan trap, `:324`).
- **C→Scheme returns**: `marshalReturn` (`:156`). The fixnum ceiling is
  2^47 − 1 (`MAX_FIXNUM = 0x7FFF_FFFF_FFFF`); larger integer/pointer
  returns promote to bignum. `bool` return normalizes nonzero → `#t`;
  `char` return 0–255 → Scheme char; a null `string` return → `#f`.
- **Dispatch and the 5-param cap**: `callFfiGeneric` (`:392`) is
  comptime-generated for arities 0–3; arities 4 and 5 are hand-curated
  signature tables (`callFfi4` `:523`, `callFfi5` `:581`) because comptime
  expansion would exceed Zig's eval-branch quota. **Parameter count is
  capped at 5** (`:479`); an unmatched signature shape raises
  `error.TypeError` "unsupported FFI signature".

### FFI: `dlopen` search path

`ffiOpen` (`primitives_ffi.zig:102`), via platform wrappers
`platform.dlOpen/dlSym/dlClose/dlError` (Windows uses `LoadLibrary`):

1. Name as-is.
2. Append each `platform.dl_suffixes` (`.dylib` / `.so` / `.so.6` — the
   last handles glibc linker-script `.so` files).
3. **`$KAAPPI_HOME/lib/` (default `~/.kaappi/lib/`) fallback** — only for
   bare names with no path separator (`hasPathSeparator`, `:35`).

A name containing `/` is treated as a pathname (dlopen(3) semantics) and is
*not* re-searched. `DlOpenDiag` (`:59`) preserves both the as-is error and
the first on-disk-but-unloadable candidate's error, so a code-signing /
arch / format rejection is not buried under "not found". macOS release
binaries ship `com.apple.security.cs.disable-library-validation` so
user-compiled libraries load.

### FFI: callbacks

`ffi_callback.zig`: a fixed pool of **32 slots** (`NUM_SLOTS`, `:7`) and
only **7 pre-generated C signatures** (`CallbackSig`, `:16`): `pp_int`,
`p_void`, `v_void`, `p_int`, `ip_int`, `i_void`, `pp_void`. One
comptime-generated trampoline exists per (signature × slot). GC roots the
live closures via `markCallbackRoots` (`:299`).

Error/control-flow handling is the subtle part. A Scheme error escaping a
callback invoked from C cannot unwind the intervening C frames, so it is
stashed on the VM (`noteCallbackError`, `:43`) and re-raised by `callFfi`
after C returns (`ffi.zig:490`). Control-flow signals —
`ContinuationInvoked`, `Yielded`, `Terminated`, `ExecutionTimeout` — are
**not** treated as callback errors: resuming a continuation or parking a
fiber across live C frames is unsupported. First error wins; later
C-driven callback runs operate on poisoned state.

### FFI: memory-model intersection

This is the crux of why FFI needs the sandbox:

- **Pointers are not GC-managed.** They surface as plain Scheme integers
  (fixnum ≤ 2^47, else bignum): `marshalPointerReturn` (`ffi.zig:174`),
  `ffi-bytevector-ptr` (`primitives_ffi.zig:350`). `marshalToPointer`
  (`ffi.zig:183`) turns an integer/bytevector back into a raw
  `*anyopaque`. A bytevector argument passes `bv.data.ptr` directly
  (`:204`); its validity depends on the bytevector outliving the call and
  not being moved — no pinning is documented.
- **GC during a (possibly blocking) FFI call**: `callFfi` marks the VM "in
  native" (`setCollectionInNative`, `ffi.zig:452`) so a collecting parent
  thread can mark the quiescent registers/frames; a callback re-entering
  Scheme flips back to `.running` for its extent (#1933).
- **Cross-thread handles**: `ffi-library` / `ffi-function` are deep-copied
  (not aliased) across per-thread heaps so a child-thread handle is not
  double-freed (#2027). `ffi-callback` is **refused** across a thread
  boundary because it wraps a live closure, not a process-global address.
  Use-after-close is guarded: `callFfi` checks `lib.handle == null` → "FFI
  library is closed" (`ffi.zig:463`).

### Sandbox: definition and pre-scan

`--sandbox` is defined at `cli_spec.zig:270` (`id = .sandbox`, "Restrict
filesystem and process access", no value). It must be detected *before*
primitives are registered, so `preScanSandbox` (`cli.zig:111`) walks argv,
correctly skipping value-taking flags and **stopping at the first
filename** — a `--sandbox` placed after the script name is deliberately not
honoured (#783/#1007). `main.zig` (`:271`) then calls
`primitives.registerSandboxed`, `library.registerSandboxedLibraries`, and
sets `vm.sandbox_mode = true`.

### Sandbox: enforcement (exclusion at registration)

The primary mechanism is **not** per-call checks — it is refusing to
register the dangerous primitives at all. Each `PrimSpec` carries
`sandbox: bool = true` (`primitives.zig:238`); `registerSandboxed`
(`:401`) registers a primitive only if `spec.sandbox`. Each `Lib` has
`sandboxAllowed()` (`:187`); disallowed libraries are skipped and exports
are filtered (`library.zig:139`).

| Surface | Restricted capability | Reported as |
|---|---|---|
| `primitives.zig:187` | Whole-library gate. Blocked: `scheme.file`, `scheme.load`, `scheme.eval`, `scheme.repl`, `scheme.process-context`, `scheme.r5rs`, **`kaappi.ffi`**, `srfi.18`, `srfi.170`, `srfi.192`, `internal`. | undefined variable |
| `primitives_filesystem.zig:162` | SRFI-170 filesystem/process primitives (`.sandbox = false`). | undefined variable |
| `primitives_io.zig:29` | File I/O (`open-input-file`, `delete-file`, `fd->port`, …). | undefined variable |
| `primitives_srfi18.zig:17` | OS threads (`make-thread`, …). | undefined variable |
| `vm_library.zig:323` | File-backed library loads: `libraryIsAvailable` returns only embedded libs; `tryLoadLibraryFromFile` refuses with `"sandbox: cannot load library from file"`. | explicit sandbox error |
| `primitives_parallel.zig:110` | Does **not** block — *degrades*: `processor-count` → 1; pool → fiber workers. | no error; reduced capability |
| `main.zig:707` | `.sbc` bytecode cache skipped (no FS side effects). | cache silently off |

(`features.zig` and `diagnostics.zig` only *describe* sandbox availability;
they are not enforcement points.)

### Sandbox ↔ FFI: two layers

`--sandbox` blocks FFI twice over:

1. **Registration exclusion** (primary): `kaappi.ffi` is
   `sandboxAllowed() == false` (`primitives.zig:195`) and every FFI spec is
   `.sandbox = false`, so `(import (kaappi ffi))` is unavailable and the
   procedures are never bound.
2. **Runtime guard** (defence in depth): `checkSandbox`
   (`primitives_ffi.zig:23`) runs at the top of `ffiOpen`, `ffiFn`,
   `ffiClose`, `ffiCallbackFn`, and `ffiBytevectorPtr`:

   ```zig
   fn checkSandbox(comptime name: []const u8) PrimitiveError!void {
       const vm = vm_mod.vm_instance orelse return;
       if (vm.sandbox_mode) {
           vm.setErrorDetail(name ++ ": not allowed in sandbox mode", .{});
           return PrimitiveError.TypeError; // bare-ok: sandbox guard with detail
       }
   }
   ```

   So even a smuggled binding yields `"ffi-open: not allowed in sandbox
   mode"`. Exercised by `tests/scheme/sandbox/sandbox-escape.sh` (each of
   `ffi-open`, `ffi-fn`, `ffi-callback`, and `(import (kaappi ffi))`
   asserted to error).

### Tests

- FFI Zig units: `tests_ffi.zig` (bool coercion incl. bignum; callback
  error re-raise; `ffi-open` diagnostics; `mapFfiError` behaviour), plus
  extensive inline `test` blocks in `ffi.zig` (`:676`) and
  `ffi_callback.zig`.
- FFI Scheme integration: `tests/scheme/ffi/` (~18 files — `basic`,
  `callback`, `callback-error`, `bytevector-ptr`, `int-range`,
  `use-after-close`, `thread-boundary-2027`, …), with a cross-compiled
  fixture DLL for Windows CI.
- Sandbox: `tests/scheme/sandbox/sandbox-escape.sh` (assert_blocked /
  assert_works harness), `srfi181-sandbox.sh`,
  `smoke/sandbox-script-arg-783.sh`; CLI pre-scan units at `cli.zig:517`.

## Drawbacks

Documenting FFI risks implying more of a stable *contract* than the code
intends: the 5-parameter cap, the 32 callback slots, and the 7 callback
signatures are implementation limits that have already moved once (params
went 4 → 5) and may move again. If the KEP reads as a spec, a future
loosening of those limits looks like a breaking change when it is not.
Mitigation: this KEP labels those numbers explicitly as current
implementation limits, not guarantees.

Coupling FFI and sandbox in one KEP also means a future change to *only*
the sandbox (e.g. adding a network capability gate) has to touch a document
titled partly about FFI. That is an acceptable cost given how tightly the
sandbox's security value is bound to disabling FFI.

## Alternatives considered

- **Two separate KEPs (FFI, and sandbox).** Rejected: the sandbox's most
  security-critical behaviour is disabling FFI, and FFI's safety story is
  incomplete without naming the sandbox as the opt-out. Documented apart,
  each would have a dangling reference to the other.
- **A sandbox-only KEP, treating FFI as one of several blocked
  capabilities.** Rejected because it would leave the largest unsafe
  subsystem in the tree — the one with no design doc — still undocumented,
  and would under-explain *why* FFI is blocked (the raw-pointer / arbitrary
  native-code hazard).
- **Write a `docs/dev/ffi.md` instead of a KEP.** Reasonable, and arguably
  should also happen — but a dev-doc is not a reviewable decision record
  and would not sit in the index next to the other subsystem contracts. A
  KEP can spawn the dev-doc as a follow-up.
- **Do nothing (status quo).** Rejected: a security boundary whose single
  authoritative statement is a shell escape-test is fragile; a new
  capability or a new FFI entry point can widen the boundary with nothing
  forcing a matching sandbox update.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Facts recorded:

- FFI is available on all native platforms; the `dlopen` layer abstracts
  macOS / Linux / the BSDs / Windows (`LoadLibrary`). It is **absent on
  WASM** (`wasm32-wasi`): every FFI spec is `.wasm = false`, and WASM is
  sandboxed by construction (`features.zig` reports
  `sandbox_available = os.tag != .wasi`).
- Under `--sandbox`, FFI, file I/O, process access, OS threads, and
  disk-backed library loads are unavailable on every platform; only
  runtime-embedded libraries load.
- The FFI/GC interaction (raw pointers as integers, "in native" collection
  state, deep-copied cross-thread handles) is a runtime-internal contract
  that the per-thread heap model (see KEP-0002) depends on for FFI handles
  crossing threads safely.

## Unresolved questions

1. **Should the current numeric limits (5 params, 32 callback slots, 7
   callback signatures) be stated as guarantees or explicitly as movable
   implementation details?** This determines whether raising them later is
   a KEP amendment.
2. **Should a companion `docs/dev/ffi.md` be written** as the living
   reference, with this KEP as the frozen decision record — mirroring how
   other subsystems pair a dev-doc with their design?
3. **Is the sandbox policy list closed?** Should adding a new blocked (or
   newly-degrading) capability require updating this KEP, or only the
   escape-test?
4. **Should the sandbox grow a network gate?** Today network access rides
   on library-level exclusion; there is no first-class "no sockets"
   capability distinct from blocking the libraries that provide them.
5. **Callback safety across continuations/fibers** is currently "refused"
   rather than "supported." Is that the permanent contract, or a documented
   TODO?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Decide the limits-as-contract question** (Unresolved 1) and annotate
   the numbers accordingly.
3. **Write `docs/dev/ffi.md`** (Unresolved 2) — FFI has none today — using
   this KEP's reference section as the seed, and link it back here.
4. **Add a one-line pointer** from `tests/scheme/sandbox/sandbox-escape.sh`
   and the FFI primitives to this KEP as the policy's written source.
5. **Publish user-facing guidance** on `kaappi.github.io` for `--sandbox`
   (what is and isn't available) and for FFI (the pointer-safety and
   sandbox-interaction caveats), linking this KEP.
6. **On acceptance**, settle the sandbox-policy change-control expectation
   (Unresolved 3) so future capability changes update the boundary in one
   place.
