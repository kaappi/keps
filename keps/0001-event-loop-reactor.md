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

*All code references are pinned to kaappi commit
[`488eaed2`](https://github.com/kaappi/kaappi/commit/488eaed2) (v0.14.1,
2026-07-11) and were verified against that source. Zig standard-library claims
were verified against Zig 0.16.0.*

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
([`fiber.zig:238`](https://github.com/kaappi/kaappi/blob/488eaed2/src/fiber.zig#L238))
round-robins over fibers that are `created` or `suspended` and sweeps
`deadline_ns` for timed waits (lines 240-253), but there is **no
`poll`/`epoll`/`kqueue` anywhere in `fiber.zig`**. The byte-read choke point
`readOneByte`
([`primitives_io.zig:325`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_io.zig#L325),
syscall at line 364) calls `std.posix.system.read(port.fd, &buf, 1)`
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
  choke point backed by a blocking `recv(2)`
  (`kaappi-net/csrc/kaappi_net.c:127`, `knet_tcp_recv` → bare `recv`).
- **`kaappi-http`'s server** has no fiber path. Its three models are
  `http-listen` (one connection at a time), `http-listen-threaded` (one SRFI-18
  OS thread — a *full child VM + GC heap* — per connection, ceiling ≈ hundreds),
  and `http-listen-prefork` (N processes, ceiling = N)
  (`kaappi-http/lib/kaappi/http/server.sld:22,34,65`). None reaches the
  "thousands of cheap connections" regime that fibers promise.
- **A non-blocking API already exists but is dead scaffolding.**
  `kaappi-net` exports `set-nonblocking`, `poll-read`, and `nb-accept`
  (`net.sld:65-77`), implemented with single-fd `poll(2)`
  (`knet_poll_read`, `kaappi_net.c:162`). Nothing in the ecosystem calls them
  except `kaappi-net`'s own unit test. They prove the concept but do not scale
  (one syscall per fd per check) and should be superseded by a real
  multiplexer.

### Timer gaps this also closes

Two sleep/timeout behaviors in the current scheduler are artifacts of having
no OS-level wait primitive, and the reactor subsumes both:

- **`thread-sleep!` parks the whole OS thread.** It is a bare `nanosleep(2)`
  loop
  ([`primitives_srfi18.zig:346`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L346)),
  so every sibling fiber stalls for the duration — the timer analogue of the
  blocking-`read` problem above.
- **Timed waits only honor the *current* fiber's deadline.** The
  join/mutex/condvar scheduler loops used to deadlock outright when no other
  fiber was runnable; commit `337fb517` (#1153) fixed that with
  `scheduleOrTimeout`
  ([`primitives_srfi18.zig:577`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L577)),
  which `nanosleep`s until the calling fiber's own deadline. But the sleep
  still blocks the whole thread, and *other* fibers' deadlines are invisible
  to it: the channel loop
  ([`primitives_fiber.zig:177`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_fiber.zig#L177))
  breaks immediately when nothing is runnable, so a `channel-receive` whose
  only potential senders are fibers parked in timed waits raises a false
  "deadlock" error even though a peer's timeout would expire and make it
  runnable.

The reactor replaces both ad-hoc `nanosleep` paths with a single blocking wait
bounded by the *minimum deadline across all parked fibers* (the timer heap,
§2), composable with fd readiness.

## Guide-level explanation

The headline user-visible change is that **fiber I/O becomes transparently
asynchronous**. Existing code does not change; it simply stops blocking the
whole scheduler:

```scheme
(import (kaappi fibers) (kaappi net))

;; Each fiber's (read-line) now yields to the scheduler on EAGAIN instead
;; of freezing every other fiber. Thousands of these coexist on one OS thread.
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

`handle-client` in `kaappi-http`'s server (`server.sld:7`) already isolates
per-connection logic, so `http-listen-fiber` is an additive driver, not a
rewrite.

Timers get the same upgrade as I/O: a fiber that calls `thread-sleep!` parks
*itself* instead of the whole OS thread, so sleeps overlap other fibers' work
and each other; and timed mutex/join waits become visible to every scheduler
loop, eliminating the false `channel-receive` deadlocks described in the
Motivation. A program whose fibers are all sleeping waits in the reactor at
low CPU.

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
   runSchedulerStep  loop:  schedule() → null?  ──►  reactor.poll(timeout)
        │                                                     │
        │   ready fds + expired timers  ◄─────────────────────┘
        ▼
   flip those fibers io_waiting → suspended, resume them (retry the read)
```

The park-and-retry substrate **already exists**: a primitive returning
`PrimitiveError.Yielded` is mapped to `VMError.Yielded` in `callNative`
([`vm_calls.zig:317`](https://github.com/kaappi/kaappi/blob/488eaed2/src/vm_calls.zig#L317)),
`runUntil` returns on it
([`vm_dispatch.zig:91`](https://github.com/kaappi/kaappi/blob/488eaed2/src/vm_dispatch.zig#L91)),
the scheduler loops catch it, and the `vm.yield_retry` protocol
(`maybeRewindRetry`,
[`vm_dispatch.zig:413`](https://github.com/kaappi/kaappi/blob/488eaed2/src/vm_dispatch.zig#L413))
rewinds the call instruction so the blocking primitive re-executes when its
fiber is resumed — exactly how `blockOrDeadlock`
([`primitives_fiber.zig:233`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_fiber.zig#L233))
parks a fiber on an empty channel today. The reactor adds the *missing
readiness wait*; it does not invent a new suspension mechanism.

### 1. The `Reactor` abstraction (new `src/reactor.zig`)

One reactor instance per OS thread, matching the share-nothing model (each
SRFI-18 OS thread has its own VM + GC + scheduler). Created lazily via the
existing `ensureScheduler` pattern
([`primitives_srfi18.zig:98`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L98)).

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
plus `comptime` `os.tag` branches (e.g. `primitives.zig:2` `is_wasm`,
`primitives_filesystem.zig:23` `is_linux` with the `std.os.linux.statx` branch
at line 71, `main.zig:3-4`). `reactor.zig` follows it with the `switch` above.
**Note: `std.posix` does not wrap these syscalls** — only the `Kevent` struct
type is re-exported (`posix.zig`: `pub const Kevent = system.Kevent`). The
backends call the raw APIs directly:

- **kqueue (macOS):** `std.c.kqueue()`, `std.c.kevent(...)` (extern
  declarations in `std/c.zig`). Changelist entries use
  `filter = std.c.EVFILT.READ (-1) / EVFILT.WRITE (-2)`, `flags = EV.ADD |
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

**Errno handling** (verified against Zig 0.16.0, resolving an open question
from earlier drafts): for libc-routed calls, `std.posix.errno` — a re-export
of the active `system.errno` — is already the codebase idiom at the read and
write choke points (`primitives_io.zig:366`, `reporting.zig:13`). For raw
`std.os.linux.*` syscalls, which return errno-encoded `usize`,
`std.os.linux.errno(r: usize) E` (`linux.zig:592`) decodes the result. The
kqueue backend uses the former; the epoll backend uses the latter.

Timers are kept in a **userspace min-heap** in all three backends (rather than
`EVFILT.TIMER`/`timerfd` exclusively) so the deadline logic is identical across
platforms; the heap's root sets each backend's wait timeout — the libuv model.

We do **not** adopt Zig 0.16's new `std.Io`: it is API-unstable, its evented
backends are GCD (`Dispatch`) on macOS and io_uring (`Uring`) on Linux rather
than kqueue/epoll, it has no WASI backend (`Io.Evented = void` there —
verified in `std/Io.zig`), and it imposes its own fiber/Operation model that
collides with Kaappi's `Fiber`/`FiberScheduler`. We may, however, use
`std/Io/Kqueue.zig` (the BSD backend) as a reference for the wakeup-pipe
(`EVFILT.USER`) pattern if cross-thread wakeup is added later.

### 3. Scheduler integration

**New fiber state.** Add `io_waiting` to `FiberStatus`
([`fiber.zig:18`](https://github.com/kaappi/kaappi/blob/488eaed2/src/fiber.zig#L18)),
distinct from the existing `waiting` (channels/mutex/condvar/join). Add to the
`Fiber` struct:

```zig
io_fd: ?std.posix.fd_t = null,
io_interest: Reactor.Interest = .read,
io_buffer: Value = types.VOID,   // pins an in-flight buffer across GC; see §5
```

- `schedule()` must treat `io_waiting` as non-runnable (it already only picks
  `created`/`suspended`).
- `hasRunnableFibers()` ([`fiber.zig:264`](https://github.com/kaappi/kaappi/blob/488eaed2/src/fiber.zig#L264))
  gains an `io_waiting` branch so a thread with only I/O-blocked fibers is
  "alive, waiting" rather than "done".

**The park-on-reactor point.** Four structurally identical scheduler loops
dispatch fibers today, differing only in their idle behavior when
`schedule()` returns null:

| Site | Loop | Idle behavior today |
|------|------|---------------------|
| [`primitives_fiber.zig:177`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_fiber.zig#L177) | `runSchedulerUntil` (channels, `fiber-join`) | breaks immediately → park via `blockOrDeadlock` or a deadlock error |
| [`primitives_srfi18.zig:597`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L597) | `runSchedulerUntilDone` (`thread-join!`) | `scheduleOrTimeout`: whole-thread `nanosleep` to own deadline |
| [`primitives_srfi18.zig:773`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L773) | `runSchedulerUntilMutex` | same |
| [`primitives_srfi18.zig:861`](https://github.com/kaappi/kaappi/blob/488eaed2/src/primitives_srfi18.zig#L861) | `runSchedulerUntilCondVar` | same |

All four should be collapsed into one helper, `runSchedulerStep`, with a
single reactor hook replacing both the bare `break` and `scheduleOrTimeout`'s
whole-thread `nanosleep`:

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

The existing `deadline_ns` sweep in `schedule()` (`fiber.zig:240-253`) folds
into the timer heap: when a fiber does a timed wait, push `(deadline_ns, fiber)`
onto `reactor.timers` instead of relying on the per-turn sweep. `thread-sleep!`
(`primitives_srfi18.zig:346`) is reimplemented as a timed park on the same
heap instead of a whole-thread `nanosleep`.

**Lifting the fiber-count ceiling.** `MAX_FIBERS` is **64**
([`fiber.zig:10`](https://github.com/kaappi/kaappi/blob/488eaed2/src/fiber.zig#L10)),
backed by a fixed `[MAX_FIBERS]?*Fiber` table; `spawn` past the cap (after
slot reuse) fails with "fiber limit exceeded". A fiber-per-connection server
needs the table to become a growable list — a mechanical change, but one this
KEP depends on and makes explicit. Per-fiber memory is the related, harder
constraint: `allocFiber` (`memory.zig:826`) preallocates the full register and
frame arrays (`INITIAL_REGISTER_CAPACITY` = 2048 registers × 8 B alone is
16 KiB, plus 480 frames), and `saveCurrentFiber` grows every fiber toward the
largest VM high-water mark. Thousands of fibers at tens of KiB each is
workable but not free; sizing policy is an unresolved question (§Unresolved,
Q5).

### 4. I/O primitive changes

**Reads — one choke point.** `readOneByte` (`primitives_io.zig:325`) already
drains three software buffers — `peek_byte` (line 327), `peek_extra` (332),
and the `(read)` leftover buffer `read_buf` (340) — plus string-port data
*before* touching the fd, so the non-blocking path is inserted only at the
syscall (line 364), after all software buffers are exhausted:

```zig
// fd is non-blocking (set lazily on first registration; never on fd 0 in REPL mode)
const raw = std.posix.system.read(port.fd, &buf, 1);
if (raw < 0 and std.posix.errno(raw) == .AGAIN) {
    const fiber = vm.current_fiber.?;
    fiber.io_fd = port.fd;
    fiber.io_interest = .read;
    fiber.status = .io_waiting;
    try reactor.register(port.fd, .read, fiber);
    vm.yield_retry = true;             // rewind ip: re-execute this primitive on resume
    return PrimitiveError.Yielded;
}
```

This is the same park-and-retry protocol `blockOrDeadlock` uses for channels
today (§Overview). Because `readOneByte` is the single byte source for
`read-char`, `peek-char`, `read-line`, `read-u8`, `peek-u8`, `read-string`,
and `read-bytevector`, the hook covers all of them at once.

**Writes.** The port write path is `writeToPort` (`primitives_io.zig:115`) →
`writeToFd` — which lives in
[`reporting.zig:8`](https://github.com/kaappi/kaappi/blob/488eaed2/src/reporting.zig#L8)
and is shared with REPL/diagnostic output. It loops on partial writes but has
no `EAGAIN` path and carries no resumable state. The port layer gets its own
fd writer that tracks progress (`total`) in the `Port` so a write that blocks
mid-buffer can suspend on `write` interest and resume with the remaining
slice; `reporting.zig` keeps the blocking version for fd 1/2 diagnostics.

**The `(read)` datum reader is already halfway there.** Since commit
`47b8e748` (#847), `readDatumFn` (`primitives_io.zig:574`) no longer drains
the fd to EOF: it parses incrementally per 4 KiB chunk, returns as soon as a
complete datum is available, and stashes unconsumed bytes in the port-resident
`read_buf` (`types.zig:457`) — which it also drains on entry (lines 630-636).
This resolves the accumulation-buffer redesign an earlier draft called for.
The only remaining reactor work is the would-block path: when the chunk read
returns `EAGAIN` mid-datum, save the partial accumulation buffer back into
`port.read_buf` and suspend on read interest; the retry re-enters with the
buffered prefix. Regular-file semantics are unaffected (files never return
`EAGAIN`).

**Buffering (optimization, recommended).** There is no write buffer today, so
every `write-char`/`write-u8` is its own syscall — and would be its own reactor
registration. A per-port `write_buf` flushed on `flush-output-port` (currently a
no-op at `primitives_io.zig:792`) or when full makes async writes efficient.

**Supersede the dead helpers.** The reactor obsoletes `set-nonblocking` /
`poll-read` / `nb-accept` in `kaappi-net`; they remain for compatibility but are
no longer the recommended path. A non-blocking `accept` loop becomes the basis
of `http-listen-fiber`.

### 5. GC rooting

`FiberScheduler.markRoots` (`fiber.zig:335`) marks every fiber in `fibers[]`
and, for non-running fibers, traces saved registers/frames/handlers/winds via
`markFiberState` (`fiber.zig:346`). An `io_waiting` fiber stays in `fibers[]`
(the reactor only *references* fibers, it does not own them), so its execution
state is already rooted. Two additions:

1. `markFiberState` must trace the new `io_buffer` field — an in-flight read/write
   buffer reachable only through the C-level operation would otherwise be
   collectible. `referencesYoung` (`gc_collect.zig:88`) needs the matching
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
  (`kaappi_pg.c:84`); libpq owns the socket, so the reactor cannot see the fd.
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
- **Fiber footprint.** Lifting `MAX_FIBERS` exposes the per-fiber
  preallocation cost (§3); without a sizing-policy change, 10k fibers cost
  hundreds of MB of register/frame arrays.
- **WASI is best-effort.** Socket readiness depends on host support.

## Alternatives considered

- **Adopt `std.Io` (Zig 0.16).** Rejected: API-unstable, GCD-on-macOS /
  io_uring-on-Linux, no WASI backend, and a competing fiber model. Revisit if
  it stabilizes.
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
  and `thread-sleep!` always work via the `CLOCK` subscription. Kaappi-level
  fibers already work on WASM because they save/restore VM register arrays,
  not CPU stacks. Gate with the existing `is_wasm` flag.
- **Sandbox mode.** Unchanged: SRFI-18 OS threads stay blocked in the sandbox;
  fibers + reactor are single-OS-thread and sandbox-safe.
- **REPL / stdin.** The REPL reads fd 0 via linenoise (C, wrapped by
  `src/linenoise.zig`), bypassing the Scheme port layer. The reactor must
  **never** set `O_NONBLOCK` on fd 0 in REPL mode; non-blocking is applied
  per-port only when a port registers with the reactor.
- **Backward compatibility.** Fully source-compatible. Existing fiber and
  SRFI-18 programs behave identically except that I/O and `thread-sleep!` no
  longer starve sibling fibers, and timed waits interact correctly with
  channel operations (no more false `channel-receive` deadlocks). No API
  removals (`poll-read` et al. retained).

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
4. **Fd-reuse hardening.** Is fd-keyed `regs` plus delete-before-close
   sufficient, or do we need tokio/mio-style token+generation indirection from
   the start?
5. **Per-fiber memory sizing.** With `MAX_FIBERS` lifted (§3), each fiber still
   preallocates full register/frame arrays and grows to the VM's high-water
   mark. Options: much smaller initial capacities for spawned fibers (growth
   machinery already exists in `saveCurrentFiber`/`restoreFiber`), or saving
   only the live register window on suspend. Needs measurement; affects
   whether "thousands of connections" is tens of MB or hundreds.

Two questions from earlier drafts are now resolved and folded into the design:
the Zig 0.16 errno helpers (§2, verified: `std.posix.errno` /
`std.os.linux.errno`) and the `(read)`-on-sockets buffer redesign (§4,
superseded by the incremental parser shipped in `47b8e748`).

## Implementation plan

**Phase 1 — Reactor core (no behavior change).** Add `src/reactor.zig` with the
`Reactor` interface, level-triggered kqueue and epoll backends, and the
userspace timer min-heap. Unit-test registration/readiness/timeout in isolation.

**Phase 2 — Scheduler integration.** Add `FiberStatus.io_waiting` and the
`io_fd`/`io_interest`/`io_buffer` fields; collapse the four scheduler loops
into `runSchedulerStep`; park on `reactor.poll`, subsuming both
`scheduleOrTimeout`'s whole-thread `nanosleep` and the bare channel-loop
`break`. Fold the `deadline_ns` sweep into the timer heap; reimplement
`thread-sleep!` as a timed park. Replace the fixed `[MAX_FIBERS]?*Fiber`
table with a growable list. Extend `markFiberState`/`referencesYoung`; add
`Reactor.markRoots`.

**Phase 3 — Port layer.** Lazy `O_NONBLOCK` on registered ports (never fd 0 in
REPL); reactor hook in `readOneByte`; resumable port-layer writes (split from
`reporting.zig`'s `writeToFd`); per-port write buffer with a real
`flush-output-port`; the `EAGAIN` path in `readDatumFn` (§4 — the incremental
parser and port-resident buffer already exist).

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
threaded/prefork servers. Measure per-fiber memory (Unresolved Q5) at
realistic connection counts.
