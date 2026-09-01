# KEP-0022: Native Subprocess Support — `(kaappi process)`

| Field | Value |
|-------|-------|
| **KEP** | 0022 |
| **Title** | Native Subprocess Support — `(kaappi process)` |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Accepted (amended 2026-09-01: [As implemented](#as-implemented-phases-14--amended-2026-09-01); all four phases landed on `main`, unreleased at time of writing) |
| **Type** | Standards |
| **Target** | `kaappi` core (`src/`, reactor, new `(kaappi process)` library) |
| **Created** | 2026-08-29 |
| **Requires** | KEP-0001 (event-loop reactor) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `f0937b21` (main,
2026-08-28) and were verified directly against that source as of
2026-08-29.*

*Amended 2026-09-01: all four phases have landed on `main` (unreleased).
The design below is the proposal as written; the
[As implemented](#as-implemented-phases-14--amended-2026-09-01) section
records what shipped, where it differs, and how the four unresolved
questions were settled. Read them together.*

## Summary

Kaappi programs cannot start a subprocess. This KEP proposes `(kaappi
process)`: a spawn-based (never fork-based) subprocess API built into the
core, with child stdin/stdout/stderr exposed as ordinary Kaappi ports on the
existing reactor path — so pipe reads park the calling fiber instead of
blocking a scheduler thread — and child termination wired into the reactor
(`EVFILT_PROC` on kqueue platforms, `pidfd` on Linux, handle polling on
Windows) so `process-wait` parks a fiber too, with no `SIGCHLD` handler
anywhere.

The design is deliberately unoriginal. It is the convergent result of a
survey of eight Scheme implementations (Guile, Racket, Chez, Gambit, Gauche,
CHICKEN, Chibi, scsh) and five mainstream language runtimes (Python, Node.js,
Go, Rust, Java), all of which arrived at the same handful of decisions after
years of production scar tissue. Where they disagree, this KEP says which
side Kaappi takes and why.

## Motivation

### There is no way to run a program from Kaappi

Nothing at the Scheme level can start a child process. The built-in SRFI 170
surface is filesystem/stat only (`src/primitives_filesystem.zig:208`);
`(scheme process-context)` is command-line/exit/environment
(`src/primitives_r7rs.zig:87`); no ecosystem library fills the gap. The one
subprocess user in the tree is the package manager, which shells out to `git`
on the Zig side (`src/thottam_proc.zig`) — capability the runtime has and
does not expose.

This is not an oversight unique to Kaappi: SRFI 170 *deliberately* omits
subprocesses ("the low-level POSIX operations are tricky to use, and a
future SRFI will provide a higher-level interface" — that SRFI never
materialized), so every implementation designs its own. Kaappi currently has
none, which closes off an entire class of programs:

- **Tool orchestration.** The concrete driving workload: a long-running
  Kaappi service that supervises external CLI tools speaking JSON over
  stdio (e.g. driving a headless coding agent such as `pi --rpc` in an
  autonomous-development pipeline), plus `git`/`gh` invocations around it.
  This needs streaming bidirectional pipes, timeouts, and kill-the-tree —
  the full surface, not a `system` one-liner.
- **Shell scripting.** The historical Scheme niche (scsh) and an explicit
  strength of the ecosystem story: build scripts, test harnesses, CI glue
  written in Kaappi instead of bash.
- **Self-hosting the workflow.** `infra/` scripts and the release tooling
  currently assume bash; a subprocess API lets them be Kaappi programs.

### The port and reactor halves already exist

Two of the three pieces this feature needs are already shipped:

1. **`fd->port`** (`src/primitives_io.zig:868`, in `(kaappi ffi)`) wraps a
   raw descriptor as a bidirectional port on the same reactor-integrated
   path as file ports — `readOneByte`/`portWriteBytes` are the single byte
   source/sink, `O_NONBLOCK` is set lazily when a fiber scheduler exists,
   and a read that would block parks the fiber (`src/types_port.zig:57`).
   Pipe ends returned by spawn are exactly this shape.
2. **The reactor** (KEP-0001) already multiplexes kqueue/epoll/Windows fd
   readiness plus a timer heap per scheduler thread, and its epoll fd is
   already opened `CLOEXEC` with the comment "without it the epoll fd leaks
   into every child" (`src/reactor.zig:626`) — the code anticipates
   children; nothing can create one.

The genuinely new pieces are: the spawn syscall surface, a process heap
type, and a reactor extension for child-*exit* readiness (a process is not a
readable fd on every platform). That last piece is why this is a core KEP
and not an ecosystem C-FFI library — see Alternatives.

## How other Scheme implementations handle this

| Implementation | Spawn mechanism | Result shape | Notable |
|---|---|---|---|
| **Guile 3.0.9+** `spawn` | posix_spawn-style | pid; streams redirected to existing ports via keywords | Added because `primitive-fork` + threads is unsafe; closes every fd except 0/1/2 |
| **Racket** `subprocess` | internal (no fork exposed) | 4 values: subprocess value + 3 ports (`#f` where caller supplied one) | Process groups (`'new`); a subprocess is a synchronizable event |
| **Chez** `open-process-ports` | internal | 4 values: 3 ports + pid | Shell-string command (injection-prone); buffer mode + transcoder args |
| **Gambit** `open-process` | internal | one bidirectional port that *is* the process | Settings list; `process-status`/`process-pid` on the port; parks green threads |
| **Gauche** `run-process` | fork/exec inside | process object with accessor ports | Rich `:input`/`:output`/`:error` redirection specs; `run-pipeline` |
| **CHICKEN** `process`/`process*` | fork/exec; raw `process-fork` also exposed | 3–4 values: ports + pid | argv form "vastly preferred" over shell string; `process-fork` absent on Windows |
| **Chibi** `(chibi process)` | raw fork/exec | `call-with-process-io` callback: pid + 3 ports | Minimal; `(chibi shell)` layers combinators above |
| **scsh** | fork/exec | `run/string`, `run/sexps`, … | The classic high-level pipeline notation (EPF), since ported to CHICKEN and Gauche *as a library* |

## How mainstream languages handle this

| Runtime | Spawn mechanism | API shape | Notable |
|---|---|---|---|
| **Python** `subprocess` | posix_spawn → vfork → fork fallback chain; CreateProcess on Windows | two layers: `run()` one-shot + `Popen` object | `preexec_fn` (run code between fork and exec) is documented "not thread-safe", banned in subinterpreters — every use case got a named parameter instead. asyncio deprecated its whole signal-based child-watcher system in 3.12 in favor of `pidfd` |
| **Node.js** `child_process` | libuv `uv_spawn` | `spawn` (streams) + `exec` (buffered) | All I/O event-loop-native; no blocking anywhere |
| **Go** `os/exec` | internal fork/exec behind a lock; never user-visible | `Cmd` struct; `Run`/`Output` high level | nil = devnull, file = fd, else pipe + copier goroutine |
| **Rust** `std::process` / tokio | posix_spawn fast path, else fork/exec | `Command` builder → `Child` | tokio reaps via pidfd/SIGCHLD integrated with the runtime |
| **Java** `ProcessBuilder` | **posix_spawn default since JDK 13** (after years of vfork) | builder → `Process` | The end state of a long migration away from fork |

### The convergent lessons

Five independent ecosystems, one design:

1. **Never expose fork; spawn atomically.** Guile added `spawn` for this;
   CHICKEN's fork doesn't exist on Windows; Python/Java/Rust all migrated
   to posix_spawn. Kaappi has SRFI-18 OS threads, a reactor holding live
   kernel objects, and a Windows tier — each independently rules fork out.
2. **No pre-exec hook.** Python kept `preexec_fn` for compatibility and has
   spent a decade regretting it. Enumerate the knobs (`directory:`, `env:`,
   process group) as named options instead.
3. **Close fds by default, explicit allowlist to pass any.** Guile inherits
   nothing but stdio; Python defaults `close_fds=True` with `pass_fds`.
   Load-bearing here: a child inheriting the reactor's kqueue/epoll fd or a
   listening socket is a bug factory.
4. **argv is the API; the shell is a separately-named opt-in.** Guile's
   `system` vs `system*`, CHICKEN's "vastly preferred", Python's
   `shell=False` default. Chez's shell-string-only API is the outlier and
   the worst injection surface. An orchestrator whose inputs include
   untrusted issue text makes this non-negotiable.
5. **Reap via the event loop, not SIGCHLD.** asyncio shipped signal-based
   child watchers, hit every failure mode (thread restrictions,
   interference with children spawned elsewhere), deprecated the whole
   subsystem, and kept `pidfd` + a thread fallback. kqueue's `EVFILT_PROC`
   and Linux's `pidfd` are the loop-native primitives.
6. **Process object + separate ports beats a merged port.** Gambit's
   port-is-the-process is elegant but conflates stdout with stderr;
   Racket/Gauche's distinct process value aged best. Racket's convention of
   returning `#f` for streams the caller redirected avoids dangling pipes.
7. **Timeouts don't kill; the high level kills and drains.** Python's
   `TimeoutExpired` leaves the child alive for the caller to `kill()` then
   drain; its `run()` layer does that dance for you. Process groups exist
   so the kill takes the child's own children with it.
8. **The pipeline DSL is a library.** scsh's notation, Gauche's
   `run-pipeline`, `(chibi shell)` — all pure-Scheme layers over a small
   spawn+ports core. None of it belongs in the primitive.

One place Kaappi can be *simpler* than the precedents: Python needs
`communicate()` as a dedicated API because reading one live pipe to EOF
while the child blocks writing the other is a deadlock. With fibers, "one
drain fiber per pipe" *is* `communicate()`, for free, inside the high-level
procedure.

## Guide-level explanation

`(import (kaappi process))` — available on every non-WASI platform.

### One-shot: run a program, get its output

```scheme
(define-values (status out err)
  (run-process '("git" "log" "--oneline" "-5") 'directory: "/path/to/repo"))
;; status: exit code (integer), or (signaled . signo) on abnormal death
;; out, err: strings (drained concurrently by internal fibers — no deadlock)
```

`run-process` spawns, feeds optional `'input:`, drains both pipes to
strings, waits, and returns. `'timeout:` (seconds) kills the process group
and drains what was produced before raising a `process-timeout` condition
carrying the partial output.

### Streaming: a long-lived child under a fiber

```scheme
(define p (spawn-process '("pi" "--rpc")
                         'stdin: 'pipe 'stdout: 'pipe 'stderr: 'null
                         'new-group: #t))

(spawn (lambda ()                          ; (kaappi fibers)
         (let loop ()
           (let ((line (read-line (process-stdout p))))
             (unless (eof-object? line)
               (handle-event (json->scheme line))   ; kaappi-json
               (loop))))))

(write-string (scheme->json req) (process-stdin p))
(flush-output-port (process-stdin p))

(process-wait p 'timeout: 300)   ; parks the fiber; #f on timeout, child lives
(process-kill p 'group: #t)      ; SIGTERM to the whole process group
(process-wait p)                 ; reap; returns exit status
```

`process-stdout`/`process-stdin`/`process-stderr` are ordinary ports: every
port primitive works on them, and a read that would block parks only the
calling fiber — other fibers on the thread keep running, exactly as with
socket ports today.

### Redirection vocabulary

Each of `'stdin:`/`'stdout:`/`'stderr:` accepts:

| Spec | Meaning |
|---|---|
| `'inherit` (default) | child shares Kaappi's own stream |
| `'pipe` | create a pipe; the Kaappi end is a port on the process object |
| `'null` | `/dev/null` (`NUL` on Windows) |
| an fd-backed port | child gets *that* descriptor; no pipe created; the accessor returns `#f` |
| `'stdout` (stderr only) | merge stderr into stdout |

There is deliberately no shell interpretation anywhere in this API. A
convenience `(run-shell "ls *.scm | wc -l")` may be added to the ecosystem
library later; it will never be the primitive.

## Reference-level design

### New heap type: `Process`

A new `ObjectTag` in a new `src/types_process.zig` domain file (re-exported
from `types.zig`), following the five-switch checklist in
`kaappi/CLAUDE.md` (mark/size/free/typeName/printer):

```zig
pub const Process = struct {
    header: Object,
    pid: i32,
    /// Linux: pidfd from pidfd_open(); Windows: process HANDLE (as fd_t);
    /// kqueue platforms: -1 (EVFILT_PROC is registered by pid, not fd).
    wait_handle: platform.fd_t,
    /// Exit status once reaped, encoded; null while running.
    status: ?u32,
    /// Kaappi-side pipe ports (nil where the caller redirected).
    stdin_port: Value,
    stdout_port: Value,
    stderr_port: Value,
    /// Process-group id when spawned with new-group:, else 0.
    pgid: i32,
    /// Fibers parked in process-wait, woken on exit.
    waiters: WaiterList,
};
```

Cross-heap defense uses the header-level `Object.owner: u32` field
(`src/types.zig:225`) that every heap object already carries — no per-type
field. The `(kaappi process)` primitives check `owner` against the current
heap the way `channel-send` does (`src/primitives_fiber.zig`); channels and
SRFI-18 thread handles are the two existing precedents for this
globals-route check (ports deliberately are *not* owner-checked — #1937
made that a per-type decision, and Process takes the channel side).

The three port fields are Values and must be traversed by
`markObjectContents`/`markValueInner`/`referencesYoung`; storing a port into
a promoted Process needs the write barrier (they are stored once, at
spawn, while the Process is young — the promotion scan covers it, but the
barrier is added anyway per the gc-safety rule "when in doubt").

`gc_deep_copy.zig`'s refusal list grows from 11 to 12 tags: a Process is
thread-affine (its waiters and wait registration belong to one scheduler)
and must not cross a channel.

### Spawning

`%process-spawn` in a new `src/primitives_process.zig`, registered with
`.sandbox = false, .wasm = false` (same gating as the SRFI 170 filesystem
specs, `src/primitives_filesystem.zig:208`).

- **POSIX platforms:** `posix_spawnp(3)` via libc (Kaappi already links
  libc for isocline). Redirections are `posix_spawn_file_actions_t`
  entries; `new-group:` uses `POSIX_SPAWN_SETPGROUP`. No code ever runs
  between "spawn" and "exec" — there is no hook to run it.
  - fd hygiene: every fd Kaappi creates is opened `O_CLOEXEC` (the reactor
    already does; an audit of `platform.zig` open sites is Phase 1 work),
    so the child inherits only the three stdio slots the file actions
    install. On macOS `POSIX_SPAWN_CLOEXEC_DEFAULT` is set as a belt —
    it closes everything not explicitly duplicated regardless of audit
    gaps. Linux relies on the CLOEXEC audit (glibc's `addclosefrom_np`
    needs 2.34+ and musl lacks it; the audit is the portable answer).
- **Windows:** `CreateProcess` with explicit `STARTUPINFO` handle lists.
  The argv list is joined with the documented `CommandLineToArgvW`
  quoting rules (the same problem `src/thottam_proc.zig` already handles
  for git on Windows). `new-group:` assigns the child to a fresh **Job
  Object** at spawn (`CreateJobObject` + `AssignProcessToJobObject`,
  before the primary thread is resumed) — `TerminateProcess` kills
  exactly one process and `CREATE_NEW_PROCESS_GROUP` only affects
  console Ctrl+C routing, so the Job Object is the only mechanism that
  makes `group:` kill actually reach grandchildren (Node's
  `child_process` ships without one and its single-process tree-kill is
  a famous footgun; runtimes that get this right use
  `TerminateJobObject`).
- **WASI:** not registered; `(kaappi process)` is absent, so the
  `(cond-expand ((library (kaappi process)) …))` gate (below) takes the
  `else` branch — mirroring how `.wasm = false` primitives disappear
  today (`src/primitives.zig:217`).

Pipe creation: `pipe2(O_CLOEXEC)` / `CreatePipe`; the child's ends are made
inheritable only inside the file-actions/handle-list, the parent's ends are
wrapped via the existing fd→port path (the internals of `fdToPort`,
`src/primitives_io.zig:868`, refactored so the primitive and spawn share
one constructor). Parent pipe ends get `O_NONBLOCK` lazily exactly as fd
ports do today (`src/types_port.zig:57`); the child's ends stay blocking.

**SIGPIPE / EPIPE contract.** The canonical subprocess failure is writing
to the stdin of a child that has already exited. The user-visible contract:
such a write raises the same I/O-error condition family as any failed port
write (KEP-0005 taxonomy), carrying `EPIPE` — it is an ordinary catchable
error, never process death. That requires `SIGPIPE` to be ignored
process-wide. Today nothing in `src/` touches `SIGPIPE`; Kaappi survives
pipe writes only because Zig's `std.start` sets it to `SIG_IGN` by default
(`std.options.keep_sigpipe == false`) — an implicit invariant that does not
hold for an embedder linking the runtime as a library, where the host's
first write to a dead child would kill the host. Phase 1 therefore sets
`SIGPIPE` to `SIG_IGN` explicitly during runtime init (idempotent alongside
the start-code default) and documents the invariant.

### Reaping: reactor child-exit readiness

New reactor surface (KEP-0001 extension), one arm per backend:

| Backend | Mechanism |
|---|---|
| kqueue (macOS, FreeBSD, OpenBSD, NetBSD) | `EVFILT_PROC` + `NOTE_EXIT`, registered by pid alongside the existing fd knotes |
| epoll (Linux) | `pidfd_open(2)` (kernel ≥ 5.3, within the supported floor); the pidfd is registered for read-readiness like any fd — it becomes readable on exit |
| Windows | the process HANDLE joins the polled handle set of the WSAEventSelect loop (#1608 structure) |
| WASI | n/a (no spawn) |

```zig
pub fn registerProcess(self: *Reactor, proc: *types.Process, fiber: *Fiber) !void;
pub fn unregisterProcess(self: *Reactor, proc: *types.Process) void;
```

On exit-readiness the reactor arm reaps (`waitpid(pid, WNOHANG)` /
`GetExitCodeProcess`), stores the encoded status into `proc.status`, and
wakes all waiters. Reaping happens exactly once, at the reactor, so there
is no SIGCHLD handler, no race with children spawned by C FFI libraries,
and no interference between threads: the Process is watched by the
scheduler of the thread that spawned it (thread-affinity enforced by the
header `Object.owner` check, matching the channel precedent from the
KEP-0002 work).

`process-wait` with no scheduler present (plain `main`, no fibers) falls
back to a blocking `waitpid`/`WaitForSingleObject` — the same degradation
port reads already implement when no scheduler exists.

### Scheme surface

Library `.kaappi_process` in the `Lib` enum; exports derived from the specs
table as usual (no second list):

| Procedure | Notes |
|---|---|
| `(spawn-process argv opt...)` | options: `stdin:`/`stdout:`/`stderr:` specs, `directory:`, `env:` (alist of `(name . value)` string pairs; **replaces** the environment wholesale — Guile/Python semantics; `(process-environment)` returns the current environment as such an alist for the copy-and-extend idiom), `new-group:`, `pass-fds:` (list of fd-backed ports) |
| `(process? x)` `(process-pid p)` `(process-group p)` | |
| `(process-stdin p)` `(process-stdout p)` `(process-stderr p)` | the pipe port for a `'pipe` spec; `#f` for every other spec (`'inherit`, `'null`, a caller-supplied port, and stderr under the `'stdout` merge) |
| `(process-status p)` | `#f` while running; exit code; `(signaled . n)` |
| `(process-wait p ['timeout: s])` | parks fiber; `#f` on timeout (child lives — Python's contract); on an already-reaped process returns the stored status immediately |
| `(process-kill p ['signal: n] ['group: bool])` | SIGTERM default; a no-op on an already-reaped process (Python's `Popen.kill` contract — the pid must never be re-signaled after reaping, it may be reused). Windows: `TerminateProcess` (or `TerminateJobObject` with `group: #t`); `signal:` values have no Windows analogue and are folded into the child's exit code as `TerminateProcess`'s argument |
| `(run-process argv opt...)` | one-shot: spawn → drain via internal fibers → wait → `(values status out err)`; `input:`, `timeout:` (kill group + drain + raise `process-timeout` with partial output) |

Error taxonomy per KEP-0005: spawn failure raises a file-error-family
condition carrying errno detail (program not found vs. permission); type
errors go through `primitives.typeError` as everywhere.

Portable code gates on the library's presence with the `(library …)`
requirement form, which `cond-expand` already supports with zero new
machinery (`src/vm_library.zig:411`):

```scheme
(cond-expand ((library (kaappi process)) ...) (else ...))
```

No `kaappi-process` feature identifier is added: the #1649 derivation
yields only `srfi-<n>` identifiers and `types.platform_features` is a
hand-kept constant — extending either buys nothing over the `(library …)`
form.

### Tests

- Zig unit tests (`src/tests_process.zig`): spawn/wait/status encoding,
  redirection matrix, fd-hygiene assertion (child sees only 0/1/2 —
  spawn `sh -c 'ls /dev/fd'` on POSIX), timeout-leaves-child-running,
  group kill, gc-stress rooting of the Process and its ports.
- Scheme tests (`tests/scheme/process/`): end-to-end against portable
  helpers (`echo`, `cat`, a Kaappi child script for bidirectional JSON
  round-trips), fiber-parking behavior (a slow child must not starve a
  sibling fiber — the KEP-0001 test pattern).
- The suites must pass under `-Dgc-stress=true`, and native-tier coverage
  (`tests/scheme/compile/*.sh`) is required since `spawn-process` will be
  reachable from compiled programs.

## Drawbacks

- **Platform surface.** Four reaping backends and two spawn backends touch
  every supported OS; each BSD historically has its own particulars
  (`docs/dev/porting.md`). Mitigated by the reactor already maintaining
  exactly this per-backend split.
- **A new heap type is real GC work.** Five switches, deep-copy refusal,
  owner checks, printer — all easy to get subtly wrong (kaappi#1954).
- **Scope temptation.** A subprocess API attracts feature requests (ptys,
  scsh notation, signal delivery to self). This KEP draws the line at the
  table above; everything else is the ecosystem library's problem.
- **Security surface.** Any spawn API is an injection risk in the large.
  argv-only and no-shell-by-default is the mitigation; `--sandbox` mode
  excludes the library entirely via the existing `.sandbox = false` gate.

## Alternatives considered

- **Ecosystem C-FFI library only (no core change).** A `kaappi-process`
  repo could posix_spawn via FFI and wrap pipe fds with the existing
  `fd->port` — reads would even park fibers. Rejected as the *primary*
  design because child-*exit* cannot park a fiber from library land: there
  is no fd to hand to `fd->port` on kqueue platforms (EVFILT_PROC is not
  an fd), so `process-wait` degrades to a sleep-loop poll or a blocked OS
  thread. Reaping is precisely the piece asyncio's history says must be
  loop-native. The FFI route also cannot enforce fd hygiene for fds other
  libraries hold.
- **Expose `fork`/`exec` primitives (Chibi/CHICKEN style) and build spawn
  in Scheme.** Rejected: unsafe with SRFI-18 threads (only the forking
  thread survives; the GC/reactor state of other threads is garbage in the
  child), impossible on Windows, and it reintroduces the pre-exec-hook
  hazard as a feature.
- **Gambit's bidirectional process port.** Rejected: conflates stdout and
  stderr, and status queries on a port are odd. The separate process
  object matches Kaappi's existing pattern of distinct heap types with
  owner defense.
- **A `system`-style shell-string API as the primitive.** Rejected on
  injection grounds (Chez is the cautionary precedent); a shell helper can
  live in the ecosystem library under a name that says shell.
- **SIGCHLD-based reaping.** Rejected on asyncio's documented experience;
  also races with children spawned by C FFI libraries (kaappi-pg et al.
  may legitimately spawn) — kernel-object watching observes only *our*
  children.
- **Wait for a subprocess SRFI.** None is in progress; SRFI 170 punted in
  2020 and nothing followed. Kaappi designing its own is the norm (every
  surveyed implementation did).

## Cross-platform / compatibility impact

| Platform | Spawn | Reap | Status |
|---|---|---|---|
| macOS aarch64 | posix_spawn (+`CLOEXEC_DEFAULT`) | kqueue `EVFILT_PROC` | full |
| Linux (all arches) | posix_spawn | `pidfd_open` + epoll | full |
| FreeBSD / OpenBSD / NetBSD | posix_spawn | kqueue `EVFILT_PROC` | full |
| Windows x86_64/ARM64 | CreateProcess | handle in polled set | full |
| WASI | — | — | library absent; `(library (kaappi process))` cond-expand gate is false |

Backward compatibility: purely additive — a new library, a new heap type,
no changes to existing exports. `--sandbox` excludes it (`.sandbox =
false`). The native (LLVM) tier needs no emitter work: the new procedures
are ordinary primitives, but compile-tier regression tests are still
mandatory per the `.scm`-tests-are-not-native-evidence rule.

## Unresolved questions

All four are settled; see
[As implemented](#as-implemented-phases-14--amended-2026-09-01) for the
as-built detail.

1. **Pseudo-terminal support.** Gambit offers `pseudo-terminal:`; agent
   tools sometimes behave differently without a tty. Deferred — `'pipe`
   covers the driving workload (`pi --rpc` is designed for pipes). Revisit
   if a concrete consumer needs it. **Resolved (2026-09-01): still
   deferred, now with four phases of evidence behind it.** Nothing built on
   the library has wanted a tty, and no shipped procedure would have to
   change to add one later — `pseudo-terminal:` would be another
   redirection spec in `parseRedir`, alongside `'pipe` and `'null`. It is
   deliberately *not* an open follow-up: a KEP that keeps a
   speculative feature open forever is how a subsystem grows a surface
   nobody asked for.
2. **Cross-thread `process-wait`.** A Process is owned by its spawning
   thread's scheduler. Should a wait from another SRFI-18 thread raise (as
   cross-heap port use does) or be supported via the notifier? Proposed:
   raise, matching the port precedent; a wrapper can bridge via a channel.
   **Resolved (2026-09-01): raise, as proposed** — and not only for
   `process-wait`. Every entry point except the `process?` predicate
   checks `Object.owner`
   (`primitives_process.expectProcess`), the same total treatment channels
   and thread handles get, so the whole class is unreachable rather than
   patched procedure by procedure. The condition's irritant is `#f`, never
   the foreign process: storing a foreign-heap object in a condition the
   owner's GC may free would reopen exactly the hazard the check closes.
3. **Zombie discipline for never-waited processes.** The reactor reaps on
   exit regardless of waiters, so no zombies accumulate while the
   scheduler runs. A parent that *exits* is no hazard either — its
   zombies are reparented to init and reaped there. The real window is a
   long-running parent whose owning thread never runs a scheduler tick
   (nor the blocking no-scheduler fallback) yet keeps spawning: those
   zombies accumulate for the program's lifetime. Proposed: a bounded
   `waitpid(WNOHANG)` sweep of that thread's unreaped processes on the
   blocking spawn/wait paths (cheap, covers the scheduler-less loop),
   with reap-on-GC-finalize considered only if a concrete program
   escapes the sweep. Needs a decision in Phase 1. **Resolved (2026-09-01):
   the sweep *and* the finalizer.** `sweepUnreaped` runs at the top of the
   blocking spawn and wait paths as proposed, and
   `gc_sweep.freeObject` reaps as a last resort — the "considered only
   if" clause was settled in Phase 1 rather than deferred, because a
   Process collected while its child still runs is not a hypothetical: it
   is what a program that spawns and drops the handle does every time.
4. **Exact status encoding.** Flat integer plus `(signaled . n)` pair vs.
   SRFI 170-style decoder procedures. Bikeshed to settle on the PR.
   **Resolved (2026-09-01): the flat integer plus the pair.** No decoder
   procedures, and room left for some later. Windows has neither a wait
   status word nor signal delivery, so a status there is always the
   integer `GetExitCodeProcess` reports (see Divergence 5).

## As implemented (Phases 1–4) — amended 2026-09-01

Core landed all four phases on `main` between 2026-08-31 and 2026-09-01,
ahead of this KEP's ratification:
[#2442](https://github.com/kaappi/kaappi/pull/2442) (Phase 1, issue
[#2414](https://github.com/kaappi/kaappi/issues/2414)),
[#2445](https://github.com/kaappi/kaappi/pull/2445) (Phase 2, issue
[#2415](https://github.com/kaappi/kaappi/issues/2415)),
[#2450](https://github.com/kaappi/kaappi/pull/2450) (Phase 3, issue
[#2416](https://github.com/kaappi/kaappi/issues/2416)), and
[#2455](https://github.com/kaappi/kaappi/pull/2455) (Phase 4, issue
[#2417](https://github.com/kaappi/kaappi/issues/2417)). This amendment
accepts them retroactively and records the deltas.

**Status is `Accepted`, not `Final`:** nothing here has shipped in a
release — v0.25.0 (2026-08-27) predates Phase 1 — and the process reserves
`Final` for a released, reconciled design. The remaining step is the next
release, plus the two follow-ups flagged below.

As-built citations are pinned to commit
[`3fce40d2`](https://github.com/kaappi/kaappi/commit/3fce40d2) (main,
2026-09-01) plus Phase 4 in #2455.
[`docs/dev/subprocess.md`](https://github.com/kaappi/kaappi/blob/main/docs/dev/subprocess.md)
is the as-built maintenance record and owns the internal detail; this
section records only what differs from, or was added to, the design above.

### What shipped as designed

- **No fork anywhere, and no pre-exec hook.** `posix_spawnp` with file
  actions (`process_posix.zig`), `CreateProcessW` (`process_win.zig`);
  every knob between spawn and exec is a named option, as the survey's
  lesson 2 demanded.
- **Close-by-default, no allowlist.** The child gets slots 0, 1 and 2 and
  nothing else, asserted end to end by spawning `sh -c 'ls /dev/fd'`
  (`tests_process.zig`). macOS uses `POSIX_SPAWN_CLOEXEC_DEFAULT`; Linux
  and the BSDs scan and close.
- **Reap at the reactor, never SIGCHLD.** kqueue `EVFILT_PROC`, Linux
  `pidfd_open` + epoll, a Windows process HANDLE in the polled set. Exactly
  one reap, at one place, so there is no race with children a C FFI library
  spawned.
- **`process-wait` parks the calling fiber**, with `timeout:` returning
  `#f` and leaving the child alive (Python's contract), and the blocking
  `waitpid` surviving only as the no-scheduler fallback.
- **Ports are ordinary ports.** The pipe parent-ends go through
  `primitives_io.makeFdPort`, the same constructor `fd->port` uses, so
  every port primitive works and a blocking read parks one fiber.
- **A `Process` heap type with the channel-style owner check**, the five
  GC switches, and deep-copy refusal.
- **`(library (kaappi process))` as the only gate**, with no
  `kaappi-process` feature identifier — false on wasm32-wasi and under
  `--sandbox`, and true everywhere else.
- **The redirection vocabulary** — `'inherit`, `'pipe`, `'null`,
  `'stdout` (stderr only), and a port — verbatim from the table above.
- **`run-process` with drain fibers and a `process-timeout` condition
  carrying the partial output**, exactly as Phase 4 promised.

### Divergences and additions

1. **`pass-fds:` was never implemented, and is withdrawn.** The API table
   lists it on `spawn-process`; shipped `spawn-process` accepts
   `stdin:`/`stdout:`/`stderr:`, `directory:`, `env:` and `new-group:`,
   and nothing else. What replaced it is narrower and sufficient: a
   redirection spec may *be* an fd-backed port, which covers "hand the
   child this file/socket" for the three slots that have names. A general
   allowlist for arbitrary extra descriptors has no consumer, and every
   one it would serve needs the child to know the number — a convention
   the child's own command line has to carry anyway. Reintroduce it if a
   concrete program needs it; the option name is reserved.

2. **`run-process` is Scheme, not a primitive.** Its body is
   `primitives_process.run_process_src`, installed over a
   `bootstrapStub` by `vm_bootstrap.install`. Spawning and joining fibers
   is dispatch-loop work a native frame cannot do, so the same route `map`
   and `for-each` take was the only one available — which is why Phase 1
   added `%process-spawn`, a positional, option-free internal entry point,
   for this layer to build on. Two consequences the KEP did not anticipate:
   the install has to be gated on that primitive being *registered* (it is
   absent under `--sandbox` as well as on WASM), and the definition cannot
   use `guard`, whose desugaring reaches a helper `install` purges from
   globals immediately afterwards.

3. **`run-process` gained `output:`, and three unstated defaults became
   decisions.** `output:` takes `'string` (the default) or `'bytevector`;
   without it a child emitting non-UTF-8 bytes would fail inside
   `utf8->string` with a type error naming a procedure the caller never
   called. The three defaults: stdin is `'null` unless `input:` is given
   (Go's `exec.Cmd` rule — a one-shot capture must never block on the
   terminal); `timeout:` implies `new-group: #t`, because `process-kill`
   refuses `'group:` on a child sharing the parent's own group *and*
   because the group kill is what lets the drains reach EOF when a
   grandchild inherited the pipe; and the timeout kill is SIGKILL, since a
   timeout is a bound and a child ignoring SIGTERM would make it a
   suggestion (Python's `run()` kills for the same reason).

4. **A third `process-wait` tier: the polled park.** The KEP has two —
   registered, and blocking with no scheduler. Phase 2 found a kernel that
   accepts neither: `pidfd_open` is `ENOSYS` before Linux 5.3 *and* under
   Rosetta's x86_64 syscall translation, which CI actually runs. Falling
   back to the blocking wait there would deadlock any program whose child
   exits only after a sibling fiber acts — the KEP's own starvation test.
   So a failed registration degrades to a `WNOHANG` reap at a 20 ms cadence
   with the fiber parked on the timer heap between probes, and siblings
   keep running.

5. **Windows `signal:` folds to `128 + n`, the shell convention.** The KEP
   said only "folded into the child's exit code as `TerminateProcess`'s
   argument". `process_win.terminateExitCode` makes that `128 + n`, so
   `'signal: 9` reports `137` rather than losing the distinction
   altogether. The residual ambiguity — a child that *chose* to exit 137 —
   is inherent to a platform with no signals.

6. **Two redirection-port rejections the KEP did not foresee.** A port the
   fiber scheduler has already flipped non-blocking is refused (the
   child's slot would share the open file description, `O_NONBLOCK`
   included, and the parent's next I/O would re-flip it), and a port with
   buffered read-ahead on an unseekable descriptor is refused rather than
   silently skipping the child past those bytes. Seekable ones are
   rewound, and that rewind must happen *before* the output drain on a
   bidirectional port.

7. **`SIGPIPE` is handled explicitly on both sides.** The parent sets
   `SIG_IGN` process-wide at `VM.init` — otherwise writing to a child that
   exited kills the runtime instead of raising — and the child's
   disposition is reset to default before exec, since an ignored
   disposition survives `exec` and a spawned program would otherwise
   inherit Kaappi's policy rather than the shell's.

8. **`process-environment` is a procedure in its own right.** The KEP
   mentions it only inside the `env:` row. It ships as an exported
   zero-argument procedure returning the `(name . value)` alist `env:`
   accepts, because `env:` replaces the environment wholesale and
   copy-and-extend is the common case — and on Windows a wholesale
   replacement that dropped the platform's own variables leaves many
   children unable to start at all.

9. **The `process-timeout` condition takes no new `KP` code.** It is an
   error object with `error_type = .process_timeout`, following the
   `channel_timeout` precedent, and stays `uncategorized` under KEP-0005.
   Its irritants are `(argv seconds)`; the partial output rides
   `uncaught_reason` as a `(stdout . stderr)` pair instead, so an uncaught
   timeout does not print however many megabytes the child wrote.

10. **The implementation plan's Phase 4 line says "cond-expand feature".**
    That contradicts the Scheme-surface section above it, which explains
    why no `kaappi-process` identifier is added. The section is right and
    the plan line was stale; nothing shipped a feature identifier.

### Open follow-ups

- **Release.** Nothing here is in a released binary. `Final` waits on the
  first release that contains all four phases.
- **Two fd-inheritance leaks predating this KEP**, found by its own
  CLOEXEC audit and tracked separately:
  [#2422](https://github.com/kaappi/kaappi/issues/2422) (test/dev fd pairs
  stay inheritable) and
  [#2424](https://github.com/kaappi/kaappi/issues/2424) (`fd->port` leaves
  foreign FFI descriptors inheritable, so a Linux child can inherit a
  kaappi-net socket). Neither is reachable through `(kaappi process)`'s own
  spawn path, which closes by default; both weaken the guarantee for
  descriptors created elsewhere.

## Implementation plan

*All four phases landed between 2026-08-31 and 2026-09-01; see
[As implemented](#as-implemented-phases-14--amended-2026-09-01). Phase 4's
"cond-expand feature" line was stale when written — see Divergence 10.*

1. **Phase 1 — spawn + ports (POSIX).** `types_process.zig`,
   `primitives_process.zig` with `%process-spawn`, file-actions
   redirection, shared fd→port constructor, CLOEXEC audit of
   `platform.zig` open sites. Blocking `process-wait` only. Unit tests +
   gc-stress.
2. **Phase 2 — reactor reaping.** `registerProcess` across kqueue/epoll
   backends; fiber-parking `process-wait` with timeout; group kill.
   Fiber-starvation and timeout-contract tests.
3. **Phase 3 — Windows.** CreateProcess spawn, Job-Object-based
   `new-group:`/tree-kill, handle-based reaping in the #1608 loop,
   quoting rules shared with `thottam_proc.zig`.
4. **Phase 4 — high level + release.** `run-process` with drain fibers,
   `process-timeout` condition, docs (`docs/dev/` + a kaappi-lang.org
   guide page + cookbook recipe), cond-expand feature, native-tier
   `tests/scheme/compile/` coverage.
5. **Ecosystem (out of scope here).** A `kaappi-process` library for
   scsh-style pipeline notation and `run-shell`, once the core surface is
   stable.
