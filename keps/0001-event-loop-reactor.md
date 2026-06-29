# KEP-0001: Event-Loop Reactor for Fiber I/O

| Field | Value |
|-------|-------|
| **KEP** | 0001 |
| **Title** | Event-Loop Reactor for Fiber I/O |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (VM/scheduler/I/O), with downstream effects on `kaappi-net`, `kaappi-http`, `kaappi-pg` |
| **Created** | 2026-06-29 |
| **Requires** | — |
| **Supersedes** | — |

## Summary

Kaappi already ships cooperative green threads — *fibers* — in the `(kaappi
fibers)` library, scheduled by a `FiberScheduler` that switches fibers on
explicit `yield`, channel operations, and timed waits. What it does **not**
have is any connection between that scheduler and the operating system's I/O
readiness machinery. A fiber that performs a socket or pipe read issues a
blocking `read(2)` syscall, which parks the entire OS thread and therefore
*every* fiber on it.

This KEP proposes an **event-loop reactor**: a small, per-OS-thread abstraction
over `kqueue` (macOS/BSD), `epoll` (Linux), and `poll_oneoff` (WASI). When a
fiber would block on I/O, it registers its file descriptor with the reactor and
suspends; when no fiber is runnable, the scheduler blocks *once* in the reactor
until a descriptor is ready or the nearest timer deadline expires, then wakes
the affected fibers. The result is that blocking-looking Scheme code
(`(read-line port)`) transparently yields, and a single OS thread can
multiplex thousands of connections on one GC heap.

## Motivation

### The current gap, precisely

The scheduler is purely cooperative. `FiberScheduler.schedule()`
([`fiber.zig:168`](https://github.com/kaappi/kaappi/blob/main/src/fiber.zig))
round-robins over fibers that are `created` or `suspended` and sweeps
`deadline_ns` for timed waits, but there is **no `poll`/`epoll`/`kqueue`
anywhere in `fiber.zig`**. The byte-read choke point `readOneByte`
([`primitives_io.zig:385`](https://github.com/kaappi/kaappi/blob/main/src/primitives_io.zig),
syscall at line 423) calls `std.posix.system.read(port.fd, &buf, 1)`
unconditionally. So inside a fiber:

```scheme
(import (kaappi fibers))
(spawn (lambda () (read-line socket-a)))   ; blocks the OS thread...
(spawn (lambda () (read-line socket-b)))   ; ...so this fiber never runs
```

The first `read-line` blocks in the kernel; the scheduler never regains
control; `socket-b`'s fiber starves. Fibers today interleave *CPU* work at
`yield` points — they do **not** overlap *I/O* waits. The book's guidance
("Use fibers for I/O-bound concurrency", "Multiple HTTP connections → Fibers")
describes the intended end-state, not the current runtime.

### Evidence from the ecosystem

- **Every TCP library** (`kaappi-net`, `kaappi-http`, `kaappi-redis`,
  `kaappi-email`) routes its socket I/O through a single `tcp-recv`/`tcp-send`
  choke point backed by a blocking `recv(2)` (`kaappi-net/csrc/kaappi_net.c`,
  `knet_tcp_recv` → bare `recv`).
- **`kaappi-http`'s server** has no fiber path. Its three models are
  `http-listen` (one connection at a time), `http-listen-threaded` (one SRFI-18
  OS thread — a *full child VM + GC heap* — per connection, ceiling ≈ hundreds),
  and `http-listen-prefork` (N processes, ceiling = N). None reaches the
  "thousands of cheap connections" regime that fibers promise.
- **A non-blocking API already exists but is dead scaffolding.**
  `kaappi-net` exports `set-nonblocking`, `poll-read`, and `nb-accept`
  (`net.sld:63-77`), implemented with single-fd `poll(2)`
  (`knet_poll_read`). Nothing in the ecosystem calls them except
  `kaappi-net`'s own unit test. They prove the concept but do not scale (one
  syscall per fd per check) and should be superseded by a real multiplexer.

### A latent bug this also fixes

Because `schedule()` busy-polls deadlines and the scheduler loops bail out with
`const idx = sched.schedule() orelse break;`, a `thread-sleep!` (or any timed
wait) with **no other runnable fiber deadlocks rather than sleeping** — the loop
breaks instead of waiting out the timer. The reactor replaces that
`orelse break` with a real blocking wait bounded by the nearest deadline,
turning the current busy-spin/deadlock into a correct OS-level sleep.

## Guide-level explanation

The headline user-visible change is that **fiber I/O becomes transparently
asynchronous**. Existing code does not change; it simply stops blocking the
whole scheduler:

```scheme
(import (kaappi fibers) (kaappi net))

;; Each fiber's (read-line) now yields to the scheduler on EAGAIN instead
;; of freezing every other fiber. 10,000 of these coexist on one OS thread.
(define (handle conn)
  (spawn (lambda ()
           (let loop ()
             (let ((line (read-line conn)))   ; suspends fiber, not the thread
               (unless (eof-object? line)
                 (channel-send out (process line))
                 (loop)))))))
```

It also unlocks a new, scalable HTTP server entry point in `kaappi-http`:

```scheme
(import (kaappi http))

;; Set the listen socket non-blocking, accept in a loop, and spawn one
;; cheap fiber per connection. Scales to thousands of connections on a
;; single OS thread and a single GC heap.
(http-listen-fiber 8080
  (lambda (req) (make-response 200 '() "hello")))
```

`handle-client` in `kaappi-http`'s server already isolates per-connection
logic, so `http-listen-fiber` is an additive driver, not a rewrite.

`thread-sleep!` and timed mutex/join waits also start behaving correctly: a
program whose fibers are all sleeping now actually sleeps the thread (low CPU)
instead of spinning or deadlocking.

## Reference-level design

### Overview

```
   Scheme I/O primitive (read-line, read-u8, write-string, tcp-recv …)
        │  EWOULDBLOCK
        ▼
   set fiber.status = io_waiting, fiber.io_fd = fd, fiber.io_interest = read
   return PrimitiveError.Yielded   ──►  VMError.Yielded  ──►  runUntil returns
        │
        ▼
   runSchedulerUntil*  loop:  schedule() → null?  ──►  reactor.poll(timeout)
        │                                                     │
        │   ready fds + expired timers  ◄─────────────────────┘
        ▼
   flip those fibers io_waiting → suspended, resume them (retry the read)
```

The yield-and-resume substrate **already exists**: a primitive returning
`PrimitiveError.Yielded` is mapped to `VMError.Yielded` in `callNative`
([`vm_calls.zig:447`](https://github.com/kaappi/kaappi/blob/main/src/vm_calls.zig)),
`runUntil` returns on it
([`vm_dispatch.zig:21`](https://github.com/kaappi/kaappi/blob/main/src/vm_dispatch.zig)),
and `runSchedulerUntil`
([`primitives_fiber.zig:127`](https://github.com/kaappi/kaappi/blob/main/src/primitives_fiber.zig))
catches it. The reactor adds the *missing readiness wait*; it does not invent a
new suspension mechanism.

### 1. The `Reactor` abstraction (new `src/reactor.zig`)

One reactor instance per OS thread, matching the share-nothing model (each
SRFI-18 OS thread has its own VM + GC + scheduler). Created lazily via the
existing `ensureScheduler` pattern
([`primitives_srfi18.zig:72`](https://github.com/kaappi/kaappi/blob/main/src/primitives_srfi18.zig)).

```zig
const builtin = @import("builtin");

const Backend = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => KqueueBackend,
    .linux                                    => EpollBackend,
    .wasi                                     => WasiPollBackend,
    else => @compileError("reactor: unsupported OS"),
};

pub const Interest = enum { read, write };

pub const Reactor = struct {
    backend: Backend,                    // owns the kqueue/epoll fd (nothing on wasi)
    regs: std.AutoHashMap(i32, Reg),     // fd -> registration
    timers: TimerHeap,                   // min-heap of (deadline_ns, *Fiber)

    pub fn init(alloc: std.mem.Allocator) !Reactor;
    pub fn deinit(self: *Reactor) void;  // closes the backend fd

    pub fn register(self: *Reactor, fd: i32, interest: Interest, fiber: *Fiber) !void;
    pub fn unregister(self: *Reactor, fd: i32) void;
    pub fn addTimer(self: *Reactor, deadline_ns: u64, fiber: *Fiber) !void;

    /// Block up to timeout_ns (min of nearest timer and any cap).
    /// Appends every fiber made runnable (readiness + expired timers) to `ready`.
    pub fn poll(self: *Reactor, timeout_ns: ?u64, ready: *std.ArrayList(*Fiber)) !void;

    pub fn isEmpty(self: *Reactor) bool; // no fds and no timers
};

const Reg = struct {
    fd: i32,
    read_waiter:  ?*Fiber = null,        // at most one per direction (Go netpoller model)
    write_waiter: ?*Fiber = null,
};
```

The fd→fiber indirection lives in `regs`; the OS is handed the **fd** (kqueue
`udata`, epoll `data.fd`, wasi `userdata`) rather than a raw pointer, so a
collected/moved fiber can never be dereferenced from a stale kernel event.

### 2. Backends

Kaappi's established platform-gating idiom is a module-level `const is_*` flag
plus `comptime` `os.tag` branches (e.g. `primitives.zig:2`
`is_wasm`, `primitives_filesystem.zig:64` `if (is_linux) … std.os.linux.statx`,
`main.zig:1254/1263`). `reactor.zig` follows it with the `switch` above. **Note:
`std.posix` does not wrap these syscalls** — only the `Kevent` struct type is
re-exported. The backends call the raw syscalls directly:

- **kqueue (macOS):** `std.c.kqueue()`, `std.c.kevent(...)`. Changelist entries
  use `filter = EVFILT.READ (-1) / EVFILT.WRITE (-2)`, `flags = EV.ADD |
  EV.ONESHOT` (auto-disarm; re-arm when the fiber blocks again), `udata = fd`.
  The wait `timespec` is computed from the nearest timer.
- **epoll (Linux):** `std.os.linux.epoll_create1`, `epoll_ctl`, `epoll_wait`.
  `events = EPOLL.IN (0x1) / EPOLL.OUT (0x4) | EPOLL.ONESHOT (1<<30)`,
  `data.fd = fd`. `epoll_wait`'s timeout is `i32` **milliseconds**; for
  sub-millisecond timer precision, arm a `timerfd_create`/`timerfd_settime` fd
  to the nearest deadline and register it like any other fd (v1 may accept ms
  granularity).
- **WASI (`poll_oneoff`):** build a `subscription_t[]` — one `fd_read`/`fd_write`
  per registration plus one `CLOCK` subscription (ABSTIME) at the nearest
  deadline — call `std.os.wasi.poll_oneoff`, and match returned
  `event_t.userdata` back to registrations. This maps one-to-one onto the
  reactor interface (`mio` uses the same approach for its wasi backend).

Timers are kept in a **userspace min-heap** in all three backends (rather than
`EVFILT.TIMER`/`timerfd` exclusively) so the deadline logic is identical across
platforms; the heap's root sets each backend's wait timeout — the libuv model.

We do **not** adopt Zig 0.16's new `std.Io`: it is API-unstable, uses GCD
(Dispatch) on macOS rather than raw kqueue, has no WASI backend
(`Io.Evented = void` there), and imposes its own fiber/Operation model that
collides with Kaappi's `Fiber`/`FiberScheduler`. We may, however, use
`std/Io/Kqueue.zig` as a reference for the wakeup-pipe (`EVFILT.USER`) pattern
if cross-thread wakeup is added later.

### 3. Scheduler integration

**New fiber state.** Add `io_waiting` to `FiberStatus`
([`fiber.zig:18`](https://github.com/kaappi/kaappi/blob/main/src/fiber.zig)),
distinct from the existing `waiting` (channels/mutex/condvar/join). Add to the
`Fiber` struct:

```zig
io_fd: ?std.posix.fd_t = null,
io_interest: Reactor.Interest = .read,
io_buffer: Value = types.VOID,   // pins an in-flight buffer across GC; see §5
```

- `schedule()` must treat `io_waiting` as non-runnable (it already only picks
  `created`/`suspended`).
- `hasRunnableFibers()` ([`fiber.zig:194`](https://github.com/kaappi/kaappi/blob/main/src/fiber.zig))
  gains an `io_waiting` branch so a thread with only I/O-blocked fibers is
  "alive, waiting" rather than "done".

**The park-on-reactor point.** Today every scheduler loop bails with
`const idx = sched.schedule() orelse break;`. There are five such sites:

| Site | Function |
|------|----------|
| `primitives_fiber.zig:143` | `runSchedulerUntil` (channels) |
| `primitives_srfi18.zig:451` | `runSchedulerUntilDone` (thread-join) |
| `primitives_srfi18.zig:608` | `runSchedulerUntilMutex` |
| `primitives_srfi18.zig:682` | `runSchedulerUntilCondVar` |
| (the cooperative `fiber-join` path through `runSchedulerUntil`) | — |

All five are structurally identical and should be collapsed into one helper,
`runSchedulerStep`, with a single reactor hook:

```zig
const idx = sched.schedule() orelse {
    if (!hasRunnableFibers(sched) and reactor.isEmpty()) break; // genuine deadlock/done
    var ready = std.ArrayList(*Fiber).init(alloc);
    defer ready.deinit();
    try reactor.poll(nearestDeadline(sched), &ready);
    for (ready.items) |f| { if (f.status == .io_waiting) f.status = .suspended; }
    continue;
};
```

The existing `deadline_ns` sweep in `schedule()` (`fiber.zig:170-183`) folds
into the timer heap: when a fiber does a timed wait, push `(deadline_ns, fiber)`
onto `reactor.timers` instead of relying on the busy-poll.

### 4. I/O primitive changes

**Reads — one choke point.** `readOneByte` (`primitives_io.zig:385`) already
drains the peek buffer (`peek_byte`/`peek_extra`, lines 387-398) and string-port
data *before* touching the fd, so the non-blocking path is inserted only at the
syscall (line 422-423), after all software buffers are exhausted:

```zig
// fd is non-blocking (set lazily on first registration; never on fd 0 in REPL mode)
const n = std.posix.system.read(port.fd, &buf, 1);
if (n < 0 and errno == .AGAIN) {
    const fiber = vm.current_fiber.?;
    fiber.io_fd = port.fd;
    fiber.io_interest = .read;
    fiber.status = .io_waiting;
    try reactor.register(port.fd, .read, fiber);
    vm.yielded = true;
    return PrimitiveError.Yielded;   // propagates; fiber resumes and retries
}
```

Because `readOneByte` is the single byte source for `read-char`, `peek-char`,
`read-line`, `read-u8`, `peek-u8`, `read-string`, and `read-bytevector`, the
hook covers all of them at once.

**Writes.** `writeToFd` (`primitives_io.zig:124`, syscall line 127) loops on
partial writes but has no `EAGAIN` path and carries no resumable state. It is
refactored to track progress (`total`) in the port so a write that blocks
mid-buffer can suspend on `write` interest and resume with the remaining slice.

**The `(read)` datum reader must change semantics for sockets.** `readDatumFn`
(`primitives_io.zig:571`) drains the fd to EOF in 4 KB chunks (line 642) before
parsing — correct for regular files, but on a socket it blocks until the peer
closes. For non-blocking ports it must read until `EAGAIN`, parse what it has,
and stash leftovers. Its accumulation buffer currently lives on the Zig stack
and so cannot survive a suspend; it must move into the `Port` struct
(alongside the existing `read_buf`) to be resumable.

**Buffering (optimization, recommended).** There is no write buffer today, so
every `write-char`/`write-u8` is its own syscall — and would be its own reactor
registration. A per-port `write_buf` flushed on `flush-output-port` (currently a
no-op at `primitives_io.zig:758`) or when full makes async writes efficient.

**Supersede the dead helpers.** The reactor obsoletes `set-nonblocking` /
`poll-read` / `nb-accept` in `kaappi-net`; they remain for compatibility but are
no longer the recommended path. A non-blocking `accept` loop becomes the basis
of `http-listen-fiber`.

### 5. GC rooting

`FiberScheduler.markRoots` (`fiber.zig:251`) marks every fiber in `fibers[]`
and, for non-running fibers, traces saved registers/frames/handlers/winds via
`markFiberState` (`fiber.zig:262`). An `io_waiting` fiber stays in `fibers[]`
(the reactor only *references* fibers, it does not own them), so its execution
state is already rooted. Two additions:

1. `markFiberState` must trace the new `io_buffer` field — an in-flight read/write
   buffer reachable only through the C-level operation would otherwise be
   collectible. `referencesYoung` (`gc_collect.zig:177-201`) needs the matching
   check for the generational write barrier.
2. As a belt-and-braces measure, add `Reactor.markRoots(gc)` (iterating
   `regs` and `timers`) called alongside `FiberScheduler.markRoots`, so a fiber
   that is *only* reachable via the reactor can never be collected even if the
   "always in `fibers[]`" invariant is later weakened.

### 6. TLS and libpq (downstream, separate work)

- **TLS** (`kaappi-net`, OpenSSL). `knet_tls_recv` (`kaappi_net.c:229`) treats
  any `SSL_read` return `<= 0` (except `ZERO_RETURN`) as a hard error. For a
  reactor it must instead surface `SSL_ERROR_WANT_READ` / `SSL_ERROR_WANT_WRITE`
  (set fd non-blocking, return a "would-block, want read/want write" sentinel so
  the scheduler registers the correct direction and retries). Until this lands,
  HTTPS/SMTPS in a fiber still blocks the thread.
- **`kaappi-pg`** uses synchronous libpq `PQexec`/`PQexecParams`
  (`kaappi_pg.c:83`); libpq owns the socket, so the reactor cannot see the fd.
  Participation requires rewriting onto libpq's async API
  (`PQconnectStart`, `PQsendQuery` + `PQconsumeInput`/`PQisBusy`, readiness off
  `PQsocket()`). This is the largest single downstream change and is **out of
  scope for the core reactor**; tracked separately.

Libraries that route purely through plain-TCP `tcp-recv`/`tcp-send`
(`kaappi-redis`, `kaappi-email` non-TLS, `kaappi-http` client and a new fiber
server) work **unchanged** once the port layer is reactor-aware.

## Drawbacks

- **Significant core surface area.** Touches the scheduler, the Fiber struct,
  the GC mark/barrier paths, and the entire I/O primitive layer — the
  highest-blast-radius subsystems in the VM.
- **Per-character syscalls/registrations** without the optional buffering work
  make naive async I/O slow; buffering is really a prerequisite, not an option.
- **Edge-trigger footguns.** If a future move to `EPOLLET`/`EV_CLEAR` is made
  without strict drain-to-`EAGAIN` discipline in every primitive, fibers hang.
  Mitigated by shipping level-triggered/ONESHOT first.
- **TLS and pg lag.** The most-used secure paths (HTTPS, Postgres) do not
  benefit until their separate rework lands, so "fibers for I/O" is only fully
  true for plain TCP at first.
- **WASI is best-effort.** Socket readiness depends on host support.

## Alternatives considered

- **Adopt `std.Io` (Zig 0.16).** Rejected: API-unstable, GCD-on-macOS, no WASI
  backend, and a competing fiber model. Revisit if it stabilizes.
- **Generalize the existing single-fd `poll-read`.** Rejected: one syscall per
  fd per check is O(n) per scheduler turn and cannot scale to thousands of
  connections. The reactor is the multiplexed replacement.
- **Stay with `http-listen-threaded`/`prefork`.** Rejected as the *primary*
  story: heap-per-connection (threaded) and process-count (prefork) ceilings are
  exactly the limits this KEP removes. Both remain valid for CPU-bound work.
- **Edge-triggered from day one.** Deferred: level-triggered/ONESHOT is far less
  error-prone for a first cut; migrate once primitives drain correctly.
- **A truly shared-heap multithreaded VM.** Out of scope and orthogonal: that
  addresses CPU parallelism (already served by SRFI-18 OS threads), not I/O
  concurrency.

## Cross-platform / compatibility impact

- **Platforms.** kqueue (macOS/BSD, primary dev target), epoll (Linux x86_64 /
  ARM / RISC-V). Both first-class.
- **WASM/WASI.** No kqueue/epoll. Use `poll_oneoff` where the host supports
  socket subscriptions; otherwise degrade to single-fiber blocking I/O. Timers
  and `thread-sleep!` always work via the `CLOCK` subscription (and stop
  busy-spinning). Kaappi-level fibers already work on WASM because they
  save/restore VM register arrays, not CPU stacks. Gate with the existing
  `is_wasm` flag.
- **Sandbox mode.** Unchanged: SRFI-18 OS threads stay blocked in the sandbox;
  fibers + reactor are single-OS-thread and sandbox-safe.
- **REPL / stdin.** The REPL reads fd 0 via linenoise in C, bypassing the Scheme
  port layer. The reactor must **never** set `O_NONBLOCK` on fd 0 in REPL mode;
  non-blocking is applied per-port only when a port registers with the reactor.
- **Backward compatibility.** Fully source-compatible. Existing fiber and
  SRFI-18 programs behave identically except that I/O no longer starves peers
  and timed waits no longer deadlock/spin. No API removals (`poll-read` et al.
  retained).

## Unresolved questions

1. **Two fibers blocked on one fd.** `Reg` holds one waiter per direction (Go
   model). Do we error, or serialize the second reader behind the first?
   (Recommendation: serialize or raise a clear error — never silently overwrite
   a waiter, which would lose a wakeup.)
2. **Timer precision on Linux v1.** Accept `epoll_wait` millisecond granularity,
   or add `timerfd` immediately for nanosecond deadlines?
3. **Level-triggered vs ONESHOT for v1.** ONESHOT matches one-waiter-per-direction
   naturally but re-arms on every block; plain level-triggered is simplest.
   Benchmark both.
4. **Exact Zig 0.16 errno helper** for raw `usize` syscall returns (flagged by
   analysis as "verify against 0.16").
5. **Fd-reuse hardening.** Is fd-keyed `regs` plus delete-before-close
   sufficient, or do we need tokio/mio-style token+generation indirection from
   the start?
6. **`(read)` on sockets.** Confirm the read-until-`EAGAIN` + port-resident
   accumulation buffer redesign does not change datum semantics on regular files.

## Implementation plan

**Phase 1 — Reactor core (no behavior change).** Add `src/reactor.zig` with the
`Reactor` interface, level-triggered kqueue and epoll backends, and the
userspace timer min-heap. Unit-test registration/readiness/timeout in isolation.

**Phase 2 — Scheduler integration.** Add `FiberStatus.io_waiting` and the
`io_fd`/`io_interest`/`io_buffer` fields; collapse the five `orelse break`
scheduler loops into `runSchedulerStep`; park on `reactor.poll`. Fold the
`deadline_ns` busy-poll into the timer heap (fixes the `thread-sleep!`
deadlock). Extend `markFiberState`/`referencesYoung`; add `Reactor.markRoots`.

**Phase 3 — Port layer.** Lazy `O_NONBLOCK` on registered ports (never fd 0 in
REPL); reactor hook in `readOneByte`; resumable `writeToFd`; per-port write
buffer with a real `flush-output-port`; rework `readDatumFn` for sockets.

**Phase 4 — WASI backend.** `poll_oneoff` backend behind `is_wasm`, with the
single-fiber blocking fallback.

**Phase 5 — Ecosystem.** Add `http-listen-fiber` to `kaappi-http`; validate
`kaappi-redis`/`kaappi-email` run unchanged; document the model in the guide and
correct the concurrency chapter of *The Kaappi Book*.

**Phase 6 — Secure/DB paths (separate KEPs/issues).** Reactor-aware TLS in
`kaappi-net` (surface `WANT_READ`/`WANT_WRITE`); `kaappi-pg` on libpq's async
API.

**Phase 7 — Performance.** Once primitives drain correctly, evaluate migrating
to edge-triggered (`EPOLLET`/`EV_CLEAR`) and benchmark against the
threaded/prefork servers.
