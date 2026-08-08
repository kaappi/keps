# KEP-0013: The WebAssembly (wasm32-wasi) Target

| Field | Value |
|-------|-------|
| **KEP** | 0013 |
| **Title** | The WebAssembly (wasm32-wasi) Target |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`build.zig`, `src/platform.zig`, `src/main.zig`, `src/primitives*.zig`, `src/library.zig`, `src/cache.zig`, `src/reactor.zig`, `src/file_utils.zig`), `kaappi.github.io` (`docs/wasm/`, `docs/js/`, playground/tour) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source, not just
`docs/dev/porting.md`, as of 2026-08-08 (the brief notes where doc and
source diverge). Playground references are to the separate
`kaappi.github.io` repo.*

## Summary

Kaappi builds to WebAssembly: `zig build wasm` produces a single
`kaappi.wasm` module targeting `wasm32-wasi`, single-threaded, that runs a
Scheme file under any WASI host (wasmtime on the command line, an in-browser
WASI shim in the playground). It is the interpreter tier only — there is no
native backend, no FFI, no OS threads, no `--sandbox` flag (WASM is
sandboxed by construction), and no bytecode cache. It shipped in v0.4.0
(2026-06-24) as "the capability-degradation exemplar" for the porting model
that traces back to KEP-0001 Phase 4, and it is what powers the browser
playground and the guided tour on kaappi-lang.org.

This is a retroactive, *as-built* KEP. It proposes no behavioural change. It
writes down what the WASM target *is* and, more importantly, precisely what
it is *not*: the build invocation and its non-obvious settings (hardcoded
`ReleaseSmall`, a 64 MB linker stack), the `PrimSpec.wasm` opt-out mechanism
and the 109 primitives it excludes, the WASI syscall surface the runtime
relies on, the file-argument-only execution model (no REPL/stdin), the way
the NaN-boxed u64 value representation survives a 32-bit target, and the
JS/WASI-shim glue that connects `kaappi.wasm` to the playground. The goal is
to make the capability boundary a numbered, citable contract rather than a
set of behaviours rediscovered from `builtin.os.tag == .wasi` checks
scattered across the tree.

## Motivation

The WASM target is a distinct deployment surface with its own, sharply
reduced capability set — exactly the kind of compatibility boundary the KEP
process exists to record — yet it has no design document of its own. Its
behaviour is defined by:

- **A capability boundary spread across ~20 files.** The rule "what works
  under WASM" is encoded as `is_wasm` conditionals in `build.zig`,
  `platform.zig`, `main.zig`, `cache.zig`, `reactor.zig`, `file_utils.zig`,
  `library.zig`, `vm_library.zig`, and a `.wasm` boolean on 109 primitive
  specs across three `primitives_*.zig` files. There is no single statement
  of the contract; `docs/dev/porting.md` treats WASM as one example of a
  general porting discipline, not as a target with its own spec.
- **User-visible degradations that deserve to be citable.** A program that
  runs natively may, under WASM, hit `this WebAssembly build has no
  filesystem access`, find `ffi-open` and most of SRFI-18 simply absent,
  get no REPL, and silently write no `.sbc` cache. These are deliberate,
  but today a user discovers them only by tripping over them.
- **A second, non-obvious consumer: the playground.** `kaappi.wasm` is
  fetched into `kaappi.github.io`, run inside a browser WASI shim via a Web
  Worker, and is the execution engine behind the playground and tour. That
  cross-repo contract (which WASI preview1 imports the browser shim must
  provide, the single-CLOCK-subscription limit) is real and undocumented as
  a contract.

A written record turns "read the `is_wasm` branches and the shim bundle"
into "read KEP-0013," and gives future work — a WASI preview2 port, a
threaded WASM build, richer in-browser filesystem — a baseline to amend.

## Guide-level explanation

Build it:

```bash
zig build wasm        # → zig-out/bin/kaappi.wasm  (wasm32-wasi, single-threaded)
```

Run a Scheme file under any WASI host:

```bash
wasmtime run --dir=. kaappi.wasm program.scm
```

The mental model: **WASM is the interpreter with the OS taken away.** Pure
Scheme — the reader, macro expander, VM, GC, the numeric tower, most SRFIs,
the fiber scheduler for cooperative concurrency — all work. What is gone is
everything that reaches outside the sandbox:

- **No FFI** — `(kaappi ffi)` and every `ffi-*` procedure is absent.
- **No OS threads** — SRFI-18 is reduced to a stub (`thread-sleep!` and
  little else); concurrency is fiber-based and single-threaded. The
  `kaappi-threads` platform feature is not advertised.
- **No general filesystem** — `open-input-file` / `open-output-file` and
  raw file descriptors raise explicit "no filesystem access" errors; only
  reads through a host-preopened directory work.
- **No `--sandbox` flag** — WASM is already sandboxed by the host; the
  entry point never even parses CLI flags.
- **No bytecode cache** — there is no home directory, so `.sbc` writes are
  no-ops.
- **No REPL, no stdin eval** — the WASM binary takes exactly one file
  argument and runs it. There is no interactive mode.

In the browser, `kaappi.wasm` runs inside a JavaScript WASI shim in a Web
Worker: the playground writes your editor buffer to a virtual
`program.scm`, boots the module with WASI args `["kaappi", "program.scm"]`,
and streams stdout/stderr back to the page. That is how the playground and
the 12-lesson tour execute real Kaappi in the browser with no server.

## Reference-level design

### Build invocation (`build.zig`)

- `build.zig:277` — `b.step("wasm", "Build kaappi.wasm (wasm32-wasi)")`.
- `build.zig:278` — target
  `.{ .cpu_arch = .wasm32, .os_tag = .wasi }`.
- `build.zig:279` — module built with **`.optimize = .ReleaseSmall`**
  (hardcoded, independent of `-Doptimize`), `.single_threaded = true`,
  `.embed = null_embed` (no embedded bytecode).
- `build.zig:285` — `addExecutable(.{ .name = "kaappi", … })` → artifact
  **`kaappi.wasm`**, installed to `zig-out/bin/kaappi.wasm`
  (`build.zig:296`).
- `build.zig:295` — `wasm_exe.stack_size = 64 * 1024 * 1024` (64 MB). The
  comment cites #2107: the default 16 MiB linker stack let deep non-tail
  recursion (reader nesting, the pretty-printer) run the wasm32 shadow
  stack off the bottom of linear memory — an **uncatchable module trap** —
  before the interpreter's own depth guard could fire. Matching the native
  64 MB stack fixed it.
- Global gates: `is_wasm_target = target.result.os.tag == .wasi`
  (`build.zig:88`); `use_isocline = !is_wasm_target` (`:93`, disables the
  line-editor REPL library); main module forced `.single_threaded`
  (`:121`).

### Platform gating idiom

Throughout the source: `const is_wasm = builtin.os.tag == .wasi;`. Notable
sites:

| File | What differs under WASM |
|---|---|
| `platform.zig:115`, `:813` | `lseek` via `std.os.wasi.fd_seek`; randomness via `std.os.wasi.random_get`. |
| `file_utils.zig:8` | File open via `std.os.wasi.path_open` against fd 3 (the first preopened directory). |
| `cache.zig:24`, `:56`, `:105` | Bytecode cache is a no-op: `cachePath`/`cacheDir` return null, writes return early. |
| `library.zig:184`, `vm_library.zig:344` | Library registration gated on `!is_wasm or lib.wasmAvailable()`; disk library search prefers the embedded copy since the host may not mount `lib/`. |
| `reactor.zig:34`, `:770` | Selects `WasiPollBackend` (see WASI interface). |
| `fmt.zig:683` | A formatting path returns `error.Unsupported`. |
| `features.zig:50` | `sandbox_available = builtin.os.tag != .wasi`. |
| `types.zig:1497` | `platform_features` omits `kaappi-threads` on WASM. |

### The `PrimSpec.wasm` opt-out

`PrimSpec` (`primitives.zig:233`) carries `wasm: bool = true`, exactly
paralleling the `.sandbox` flag (see KEP-0011). Enforcement is at
registration and by comptime slice selection:

- `registerAll` (`primitives.zig:388`): registers a primitive only if
  `!is_wasm or spec.wasm`.
- Whole spec groups are excluded under WASM: FFI
  (`primitives.zig:332` → `no_specs`), filesystem (`:345` → `no_specs`),
  and SRFI-18 uses a comptime-filtered `wasm_specs`
  (`primitives_srfi18.zig:63`) instead of the full table.
- `Lib.wasmAvailable` (`primitives.zig:217`) gates whole libraries at
  `library.zig:184`.

**109 specs are `.wasm = false`**: 68 in `primitives_filesystem.zig`
(all SRFI-170 directory/file-info/process), 34 in `primitives_srfi18.zig`
(OS threads — only `thread-sleep!` and one other stay `.wasm = true`), and
7 in `primitives_ffi.zig` (the entire FFI surface). The SRFI-18 exclusion is
not merely policy: a thread function pointer in the runtime spec table would
force codegen of its body, and `std.Thread.spawn` is a compile error in a
single-threaded build, so the WASM spec table must *never reference* the
thread functions (`primitives_srfi18.zig:58`). Relatedly, wasm32 has no
64-bit atomics, so the u64 `signal_generation` counter is gated out.

### Capability restrictions (the boundary, precisely)

- **FFI: entirely absent.** `(kaappi ffi)` is unavailable; all seven
  `ffi-*` procedures are `.wasm = false`.
- **OS threads: gone.** Only `thread-sleep!` survives; `platform_features`
  drops `kaappi-threads`. Concurrency remains available via fibers,
  single-threaded.
- **Filesystem: read-only, host-mediated.** The SRFI-170 and file-I/O
  primitives are dropped; `open-input-file` / `open-output-file` raise
  `this WebAssembly build has no filesystem access`, and raw-fd operations
  raise `raw file descriptors are unavailable in this WebAssembly build`.
  What works: reads through a host-preopened directory via `path_open`.
- **Process spawning / networking: none.** Covered by the native-only
  primitive drop; the browser WASI shim throws on `sock_*`.
- **Bytecode cache: no-op.** No home directory ⇒ no `.sbc` written.
- **Sandbox: not applicable.** `sandbox_available = os.tag != .wasi`; the
  WASM entry point calls `registerAll`, never `registerSandboxed`, and
  never parses CLI flags. "WASM is sandboxed by construction." This is the
  clean complement to KEP-0011: on native, `--sandbox` welds the OS hatches
  shut; on WASM they were never opened.

### Execution model and WASI interface

The WASM entry point (`main.zig:254`, the `if (comptime is_wasm)` block)
registers primitives and libraries, reads argv, skips argv[0], takes **one
positional file path**, and calls `runFile`. With no file it writes
`kaappi-wasm: no file specified` and returns. There is **no REPL and no
stdin eval** — `use_isocline` is off and the code never reaches the REPL
loop (the WASI line-reader exists only so the REPL module keeps compiling).
The allocator is `std.heap.wasm_allocator` (`main.zig:185`).

WASI syscalls relied upon: `args_sizes_get`/`args_get` (arguments),
`clock_time_get` (timers), `random_get` (randomness), `fd_write` (stdout),
`fd_seek` + `path_open` (files). The reactor uses `WasiPollBackend`
(`reactor.zig:770`) built on `poll_oneoff` / `subscription_t` / `event_t`;
its comment notes the browser shim "supports only a single CLOCK
subscription per call," which is satisfied because no file descriptor is
ever registered there, while "wasmtime implements the full API." With no OS
threads, `notify()` has nothing to wake. The host interface is WASI
**preview1**.

### Value and memory model on a 32-bit target

The NaN-boxed u64 `Value` representation is unchanged on wasm32. Per
`porting.md`, the heap tag stores the raw pointer in a 48-bit payload and
`types.makePointer` does no masking — it ORs the address with the tag — so a
32-bit `usize` pointer fits trivially. The one genuine 32-bit hazard was
#1912: several index accessors narrowed to `usize` *before* the
out-of-range check, so on wasm32 (`usize = u32`) an out-of-range index
wrapped instead of erroring; the fix compares in u64 before narrowing
(`primitives.zig:568`, `primitives_bytevector.zig:128`, several
`primitives_vector.zig` sites, `primitives_srfi160.zig:248`). GC is
single-threaded and scans VM registers and rooted slots (never the machine
stack), so it is architecture-independent.

### Playground integration (`kaappi.github.io`)

`docs/wasm/kaappi.wasm` (gitignored) is fetched by `scripts/fetch-wasm.sh`
from the core repo's GitHub release
(`…/releases/download/<tag>/kaappi.wasm`), checksum-verified against the
release `SHA256SUMS`, with the tag derived from `kaappi_version` in
`mkdocs.yml`. The site repo's `.github/workflows/update-wasm.yml` is a
`workflow_dispatch` job — run manually after a core release — that fetches,
bumps the version, validates, and commits. (Note: the core repo's
`post-release.yml` only *tests* the released wasm; `release.yml` *builds and
publishes* it. There is no automatic post-release hook in the core repo that
updates the site — the sync is the site-repo dispatch job.)

In the browser, `docs/js/kp-runner.mjs` posts `{ code, wasmUrl }` to a Web
Worker (`docs/js/playground-worker.js`), which imports a
browser-wasi-shim-style preview1 implementation
(`docs/js/wasi-shim-bundle.mjs`), compiles the module once, sets up fds
(stdin empty, stdout/stderr line-buffered to the page, and a
`PreopenDirectory(".", { "program.scm": code })`), constructs
`new WASI(["kaappi", "program.scm"], [], fds)`, instantiates, and runs —
returning `{ stdout, stderr, elapsed }` and catching
`WebAssembly.RuntimeError`. The shim's `poll_oneoff` is restricted to a
single CLOCK subscription (matching the reactor's assumption), `sock_*`
throw "sockets not supported," and `random_get` uses
`crypto.getRandomValues`.

### Tests and CI

- WASM test programs: `tests/wasm/{smoke,timers,parallel,platform-gates}.scm`.
- Acceptance harness `tests/acceptance/test-wasm.sh` runs expressions via
  `wasmtime run --dir=. kaappi.wasm <file>` ("No JIT, no FFI, no
  filesystem").
- CI `wasm` job (`ci.yml:1196`): `zig build wasm`, pinned wasmtime, runs the
  smoke and timer programs.
- Release `build-wasm` (`release.yml:246`) builds and uploads
  `kaappi-wasm32-wasi`; `kaappi.wasm` is copied into `release/` and included
  in `SHA256SUMS`. `post-release.yml` `test-wasm` re-runs the acceptance
  harness against the released binary.
- Known gap (`porting.md:219`): `zig build test -Dtarget=wasm32-wasi` does
  **not** run the Zig unit-test suite under WASM; the target is exercised
  only via the `.scm` programs under wasmtime.

## Drawbacks

An as-built KEP for a target still evolving (the #2107 stack fix and #1912
narrowing fix are recent) risks drift. Mitigation: the KEP records the
*capability contract and the cross-repo playground interface* — which change
rarely — rather than mirroring every `is_wasm` branch, and pins line
references to a commit.

Stating the current exclusions (no threads, no general filesystem, no
sockets) in a numbered document could read as freezing them. It is not
meant to: several are flagged in Unresolved questions as candidates to
revisit under WASI preview2 or a threaded build. The record exists so that
*lifting* a restriction is a visible amendment rather than a silent
behavioural change that breaks a program author's assumptions in the other
direction.

## Alternatives considered

- **Leave it to `docs/dev/porting.md`.** Rejected: porting.md frames WASM as
  one example of a general porting discipline, not as a target with its own
  capability contract, and it omits concrete facts (the hardcoded
  `ReleaseSmall`, the exact error strings, the playground shim contract). A
  numbered KEP gives the boundary a citable home.
- **Fold WASM into KEP-0010 (native backend) as "the other non-default
  target."** Rejected: the two are opposites — the native backend adds a
  compilation tier for two architectures; WASM *removes* capabilities from
  the interpreter tier. Their design concerns barely overlap. KEP-0010 and
  this KEP cross-reference each other instead.
- **Fold the capability boundary into KEP-0011 (sandbox).** Tempting, since
  "WASM is sandboxed by construction" is the clean complement to
  `--sandbox`. Rejected because WASM is a whole build/deployment target with
  a value-model dimension and a browser-integration dimension that have
  nothing to do with the sandbox capability model; this KEP references
  KEP-0011 for the sandbox relationship rather than absorbing it.
- **Split the playground integration into a `kaappi.github.io` KEP.**
  Rejected for now: the shim's WASI-preview1 import set and the
  single-CLOCK-subscription assumption are properties of `kaappi.wasm`'s
  runtime, so they belong with the target that imposes them. A site-focused
  KEP could still follow.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- `kaappi.wasm` targets `wasm32-wasi`, single-threaded, WASI preview1, and
  runs under any conformant host (wasmtime; the browser shim).
- The capability boundary (no FFI, no OS threads, read-only host-mediated
  filesystem, no sockets, no bytecode cache, no REPL, no `--sandbox`) is
  identical across hosts, except where a host's WASI completeness differs
  (wasmtime implements the full `poll_oneoff`; the browser shim allows a
  single CLOCK subscription). Runtime capability probes degrade objects
  accordingly rather than failing at compile time.
- The NaN-boxed u64 value representation and the register/root-scanning GC
  are unchanged on the 32-bit target.
- WASM is interpreter-tier only: it is deliberately outside the
  `kaappi compile` native backend (KEP-0010) and does not participate in
  the `--sandbox` model (KEP-0011), which it renders moot.
- Cross-repo: the playground in `kaappi.github.io` depends on the released
  `kaappi.wasm` and on the module importing only WASI-preview1 functions the
  browser shim provides.

## Unresolved questions

1. **Should the WASM capability boundary be a frozen contract?** If a
   program can query "is FFI available," is the *absence* of FFI/threads on
   WASM a guarantee, or an implementation state that a future threaded /
   preview2 build may change?
2. **WASI preview2 / the Component Model**: is a port in scope for a future
   KEP, and would it change the syscall surface this KEP documents?
3. **A threaded WASM build** (wasm threads + shared memory) would restore
   SRFI-18 and 64-bit-atomic-dependent code. Is that a goal, and does it
   supersede the single-threaded assumptions recorded here?
4. **Richer in-browser filesystem**: should the playground shim expose a
   writable virtual FS so `open-output-file` works in the browser, and if
   so is the "no filesystem access" error string a contract test would
   depend on?
5. **Should the playground/WASI-shim contract move to a `kaappi.github.io`
   KEP**, cross-referenced from here, once the site's own design surface
   grows?
6. **The unit-test gap** (`zig build test -Dtarget=wasm32-wasi` not running
   the suite): is closing it in scope, or is the wasmtime `.scm` harness the
   intended coverage model?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Reconcile `docs/dev/porting.md`** to point at this KEP as the canonical
   WASM capability contract, and correct the divergences the brief found
   (the hardcoded `ReleaseSmall`; the update-wasm workflow being a
   site-repo dispatch job, not an automatic core-repo post-release hook).
3. **Decide the capability-freeze question** (Unresolved 1) and annotate the
   restrictions section accordingly.
4. **Coordinate with KEP-0010 and KEP-0011** on cross-references so the
   three non-default-execution concerns (native compile, sandbox, WASM) form
   a coherent set in the index.
5. **Publish user-facing guidance** on `kaappi.github.io` (a WASM/embedding
   section): the capability list, the exact error strings, and the
   file-argument-only execution model, linking this KEP.
6. **On acceptance**, triage the preview2 / threaded-build / in-browser-FS
   questions (Unresolved 2–4) into tracked issues so any future WASM
   evolution amends this KEP rather than starting from source.
