# KEP-0002: Cross-Thread Channels and Multi-Core Fiber Scheduling

| Field | Value |
|-------|-------|
| **KEP** | 0002 |
| **Title** | Cross-Thread Channels and Multi-Core Fiber Scheduling |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Accepted |
| **Type** | Standards |
| **Target** | `kaappi` core (GC/scheduler/reactor/channels), new `(kaappi parallel)` library, with downstream effects on `kaappi-net`, `kaappi-http` |
| **Created** | 2026-07-12 |
| **Requires** | KEP-0001 (Phases 1–2, shipped; Phase 3 for the I/O examples) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit
[`54706a0c`](https://github.com/kaappi/kaappi/commit/54706a0c) (main,
2026-07-12, post KEP-0001 Phase 2) and were verified against that source.
Zig standard-library claims were verified against Zig 0.16.0. The two
behavior experiments in the Motivation were run on macOS aarch64,
ReleaseSafe, at that commit.*

## Summary

Kaappi has two concurrency mechanisms that do not compose. **Fibers**
(`(kaappi fibers)`) give cheap cooperative concurrency with channels — on one
OS thread and one GC heap. **SRFI-18 threads** give true multi-core
parallelism with fully isolated heaps — but the only communication is a
deep-copied thunk in at `thread-start!` and a deep-copied result out at
`thread-join!`. There is no way for two running threads to exchange values,
and therefore no way to build a worker pool, a pipeline, or a multi-core
server on top of the fiber API.

This KEP makes **channels work across OS threads** while keeping the
share-nothing heap invariant that the whole GC design rests on. A channel
that crosses a thread boundary is transparently *promoted*: its queue moves
into a heap-independent, mutex-protected `SharedChannel` whose messages are
self-contained *envelopes* (each a private mini-heap filled by the existing
`deepCopy` machinery). Sends from any thread deep-copy the value into an
envelope; receives deep-copy it out into the receiving thread's heap —
every message is copied **twice**, a deliberate trade of throughput for
isolation (see Drawbacks). No Scheme heap object is ever reachable from
two GCs. A cross-thread send wakes
remote parked fibers by ringing the target thread's reactor (`EVFILT.USER` on
kqueue, `eventfd` on epoll) — the cross-thread wakeup that KEP-0001
explicitly deferred.

On top of this single primitive, a new pure-Scheme `(kaappi parallel)`
library provides worker pools and `parallel-map`, and `kaappi-http` gains a
multi-core server mode: N OS threads, each running its own fiber scheduler
and reactor, load-balanced by the kernel via `SO_REUSEPORT` on Linux
(Darwin needs a userspace fallback — §9). Fibers do
**not** migrate between threads — multi-core fiber scheduling here means
*N independent schedulers connected by channels*, not a work-stealing runtime
(see Alternatives for why).

## Motivation

### The two halves that don't meet

The share-nothing thread model is deliberate and load-bearing: each SRFI-18
thread gets its own VM and GC
([`primitives_srfi18.zig:237`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L237),
`GC.initForThread` at
[`memory.zig:148`](https://github.com/kaappi/kaappi/blob/54706a0c/src/memory.zig#L148)),
collections never touch foreign-owned objects (`Object.owner` / `GC.id`,
[`memory.zig:97`](https://github.com/kaappi/kaappi/blob/54706a0c/src/memory.zig#L97),
#958), and none of the 601 primitives need locks. The price is that the
*only* data paths between threads are the thunk copy at start
([`primitives_srfi18.zig:277`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L277))
and the result copy at join. Between those two moments, a running thread is
an island.

Channels are the natural bridge — they already express exactly the
producer/consumer patterns threads need — but today they are a fiber-only,
single-heap structure: `Channel` is a bare `head`/`tail` pair queue
([`types.zig:645`](https://github.com/kaappi/kaappi/blob/54706a0c/src/types.zig#L645)),
`channel-send` allocates the queue pair on the **sender's** GC with no
locking
([`primitives_fiber.zig:101`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_fiber.zig#L101)),
and waking receivers goes through the **sender's** fiber scheduler
([`fiber.zig:347`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L347)).

### What actually happens today (verified at `54706a0c`)

**Path 1 — channel captured in the thread thunk.** `deepCopy` classifies
channels (and fibers, mutexes, condvars, ports, continuations) as
`UncopyableType`
([`gc_deep_copy.zig:331`](https://github.com/kaappi/kaappi/blob/54706a0c/src/gc_deep_copy.zig#L331)),
so the child thread dies before running:

```scheme
(import (scheme base) (srfi 18) (kaappi fibers))
(let ((ch (make-channel)))
  (thread-join! (thread-start! (make-thread (lambda () (channel-send ch 42))))))
;; child errors: "thread thunk contains uncopyable type (port, continuation, etc.)"
;; thread-join! reraises it as "uncaught exception in thread"
```

**Path 2 — channel reached through a shared global.** Child VMs share the
parent's globals map *by pointer*
([`vm.zig:333`](https://github.com/kaappi/kaappi/blob/54706a0c/src/vm.zig#L333)),
so a top-level channel bypasses the deep-copy guard entirely — and silently
corrupts memory:

```scheme
(import (scheme base) (scheme write) (srfi 18) (kaappi fibers))
(define ch (make-channel))
(thread-join! (thread-start! (make-thread (lambda () (channel-send ch 42)))))
(display (channel-receive ch))   ; prints 1.9767521866e-313, not 42
```

The child's `channel-send` splices a **child-heap** pair into the
**parent-heap** channel. The parent's GC refuses to mark foreign-owned
objects (#958), the child's heap is freed wholesale at `thread-join!`, and
the parent's `channel-receive` then reads a freed pair — here surfacing as a
garbage NaN-boxed flonum; under memory reuse it is arbitrary corruption.
Even without the use-after-free, the send's wakeup goes to the *child's*
scheduler, so a parent fiber parked on that channel would never wake. This
is not a hypothetical: it is the first thing anyone who has used Go or
Erlang writes when they discover `(srfi 18)` and `(kaappi fibers)` in the
same manual.

### What this blocks

- **Worker pools / parallel map.** `thread-start!`+`thread-join!` can fan
  out N one-shot computations, but cannot keep N warm workers fed with a
  stream of tasks — that needs a task queue two threads can see.
- **Multi-core servers.** KEP-0001's reactor multiplexes thousands of
  connections on *one* core. The obvious next step — N reactor threads —
  has no way to coordinate (distribute work, collect results, share a
  shutdown signal) beyond polling files or sockets.
- **Pipelines.** stage-per-thread designs (parse → transform → write) are
  the textbook channel use case and are simply not expressible.

Two adjacent gaps are explicitly *related but separate*: cross-thread
mutex/condvar correctness is being fixed in kaappi#1455 on the existing
globals-aliasing model, and KEP-0001's resolved question 4 deferred
cross-thread reactor wakeup with a named trigger ("`EVFILT.USER`") — this
KEP is that trigger.

### A latent race this KEP also closes

Today the *child* thread deep-copies the thunk out of the live parent heap
([`primitives_srfi18.zig:277`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L277))
**while the parent keeps running** — `thread-start!` returns before the copy
begins. The thunk itself is rooted
([`primitives_srfi18.zig:226`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L226)),
so nothing is freed under the copy, but nothing stops the parent from
*mutating* a captured vector or record mid-copy: the child can observe torn
structures. The envelope mechanism introduced below moves this copy to the
parent's own thread, making the thunk a consistent snapshot taken at the
`thread-start!` call (§3).

## Guide-level explanation

**Channels just start working across threads.** Hand a channel to a thread
through its thunk and both sides use the ordinary API; values are copied at
the boundary, exactly like the thunk and the join result today:

```scheme
(import (scheme base) (srfi 18) (kaappi fibers))

(let ((tasks   (make-channel))
      (results (make-channel)))
  ;; one warm worker on its own core, its own heap
  (thread-start!
    (make-thread
      (lambda ()
        (let loop ()
          (let ((task (channel-receive tasks)))     ; parks the worker's fiber,
            (unless (eq? task 'done)                ; not a spinning poll
              (channel-send results (expensive task))
              (loop)))))))
  (channel-send tasks 42)          ; value is deep-copied into the message
  (display (channel-receive results))
  (channel-send tasks 'done))
```

Sends carry anything `thread-start!` can carry today — numbers, strings,
pairs, vectors, records, hash tables, **and closures** (the existing
`deepCopy` already copies closures and their bytecode,
[`gc_deep_copy.zig:107`](https://github.com/kaappi/kaappi/blob/54706a0c/src/gc_deep_copy.zig#L107)).
Sending a channel over a channel also works, and preserves identity — the
receiver gets a handle to the *same* channel, which is what makes
reply-to patterns possible:

```scheme
(channel-send tasks (cons thunk reply-channel))   ; worker answers on reply-channel
```

Ports, continuations, and fibers remain unsendable and raise the same
`UncopyableType` error as thread thunks.

Two consequences worth knowing up front. First, sending a value shares
**every channel reachable from it** — including one captured in a
closure's environment. Sharing never changes behavior, only cost (the
channel permanently swaps its lock-free local queue for a mutex-protected
shared one), so don't close over channels you want to keep on the fast
path. Second, streams have a first-class ending:
`(channel-close! ch)` wakes all waiters, later receives drain what's
queued and then return `(eof-object)` — no sentinel-message protocols
(and, to keep that ending unambiguous, *sending* an eof-object is an
error — §6).

**Worker pools become a library, not a project.** The new pure-Scheme
`(kaappi parallel)` library packages the pattern:

```scheme
(import (scheme base) (kaappi parallel))

(define pool (make-pool (processor-count)))       ; N OS threads, N heaps

(define task (pool-submit pool (lambda () (fib 32))))
(display (task-wait task))

(display (parallel-map pool heavy-transform big-list))  ; list order preserved

(pool-shutdown! pool)
```

**Multi-core HTTP serving** composes this with KEP-0001's fiber server:
N threads each run `http-listen-fiber` on a `SO_REUSEPORT` socket, so
accepts are load-balanced (by the kernel on Linux; see §9 for the Darwin
caveat) and each core multiplexes thousands of
connections on its own reactor:

```scheme
(import (kaappi http))
(http-listen-parallel 8080 handler)               ; defaults to processor-count threads
```

**What does not change:** fibers on one thread still schedule cooperatively
and share their heap; a channel used within one thread keeps today's
zero-lock fast path; threads still cannot share mutable Scheme data — a
vector sent down a channel is a copy, and mutating the original is invisible
to the receiver. That is the model, not a bug: it is what keeps every
primitive lock-free.

## Reference-level design

### Overview

```
 thread A (own VM+GC+scheduler+reactor)          thread B (own VM+GC+scheduler+reactor)
 ┌───────────────────────────────┐               ┌───────────────────────────────┐
 │ (channel-send ch v)           │               │ (channel-receive ch)          │
 │   deepCopy v ──► envelope     │               │   pop envelope under lock     │
 │   push under lock ──────────┐ │               │   deepCopy out ──► B's heap ◄─┼──┐
 └─────────────────────────────┼─┘               │   envelope.deinit()           │  │
                               ▼                 └───────────────▲───────────────┘  │
                  ┌─ SharedChannel (no GC heap) ─┐               │                  │
                  │ refcount · mutex · FIFO of   │───────────────┘                  │
                  │ envelopes · waiter notifiers │            notify B's reactor    │
                  └──────────────────────────────┘            (EVFILT.USER/eventfd)─┘
```

Four invariants the whole design preserves:

1. **No Scheme heap object is ever reachable from two GCs.** `SharedChannel`
   and envelopes live outside every GC heap; messages are copied in and out.
2. **No thread ever mutates another thread's fiber or scheduler state.**
   Cross-thread wakeup only *rings a doorbell*; the woken thread flips its
   own fibers' statuses.
3. **The single-thread fast path stays lock-free and allocation-identical.**
   An unpromoted channel is today's `head`/`tail` pair queue plus one
   pointer null-check and the §6 capacity/closed tests — three predictable
   branches, no locks, no atomics. "Unmeasurable" is a Phase 1 benchmark
   gate, not an assumption.
4. **Promotion is one-way and atomic; no mixed-mode channel is ever
   observable.** `shared` is written exactly once, by the owning thread,
   *before* the local queue is drained — early publication is what makes
   promotion re-entrancy-safe (§2 step 2) — and a promoted channel never
   demotes. No interleaving can observe a half-promoted channel:
   local-channel operations on the owning thread are serialized by
   cooperative fiber scheduling (promotion runs inside a primitive, which
   has no fiber switch points), and no other thread can reach the channel
   until the stub escapes through the very `deepCopy` that triggered the
   promotion — a hand-off (envelope push under the channel mutex, or
   `Thread.spawn` for a thunk) that happens strictly after promotion
   completes and carries the release/acquire edge for every
   promotion-time write.

**The §§4–6 protocol is machine-checked.** `research/tla/shared_channel.tla`
(in this repository; P2 of
[`research/open-problems.md`](../research/open-problems.md)) models
promotion, send/receive, close, and the notifier protocol against six
pre-registered safety/liveness properties, and the suite
(`research/tla/run.sh`) is re-run whenever this KEP's pseudocode changes
— amendment first, code second. Three protocol bugs the model found on
2026-07-12 — a lost wakeup from filtering the sweep by readiness, an
admitted send abandoned across close, and receivers stranded by the
copy-failure path — are repaired in the current text (§5's unconditional
sweep; §4 receive step 6's `reserved == 0` guard; §4 step 9's
closed-channel ring), and the rejected variants are kept in the model as
regression witnesses.

### 1. The shared-object protocol; `SharedChannel` and envelopes (new `src/shared_object.zig`, `src/shared_channel.zig`)

**The shared-object protocol.** Channels are the first of (at least) two
runtime types that must outlive any single heap — KEP-0003's shared flat
numeric buffers are the declared second — so the lifetime rules are
specified once, generically, and instantiated per type; writing them
down generically here is KEP-0003's Phase 0. A **shared object** is a
refcounted structure allocated from the process-global allocator,
outside every GC heap. Five rules:

1. **Every reference is a counted stub.** The only way any thread — or
   any envelope — holds a shared object is through an ordinary
   GC-managed heap object (a *stub*) owning exactly one refcount.
   Uncounted references do not exist; this is what makes lifetime
   reasoning local (§2's foreign-owner rule) and per-object "another
   thread may act" tests sound (§5, Unresolved question 2).
2. **Stubs are created by `deepCopy`'s alias arm.** Meeting a stub (or
   an object being promoted into shared form) allocates a new stub on
   the target heap pointing at the same shared object, `refcount += 1`.
   Identity across heaps is pointer identity of the shared object (§2).
3. **Stubs are released by `freeObject`.** `refcount -= 1` from any path
   that frees the stub — a heap collection, a child heap torn down at
   `thread-join!`, an `envelope.deinit()`. No type carries separate
   bookkeeping.
4. **Zero destroys.** The final decrement runs the type's destroy hook;
   the hook may recursively release other shared objects' refcounts
   (a drained envelope releasing the stubs it contains).
5. **Reference counting does not collect cycles**, and every instance
   type must state its cycle exposure (channels: the known limitation
   below; KEP-0003 buffers: none — flat contents cannot hold stubs).
   Every instance participates in the unit suite's leak checking (an
   undestroyed shared object at process exit is a failure) and the §7
   gc-stress thread-churn tests.

The mechanics live once in `src/shared_object.zig` (the refcounted
header plus stub alloc/release helpers); everything type-specific below
— queue, waiter lists, promotion — sits behind `SharedChannel`'s own
mutex, invisible to the protocol. `ThreadNotifier` (§5) is refcounted
too but is **not** an instance: its references come from `SharedChannel`
waiter lists under §7's lifecycle, never from heap stubs.

```zig
pub const Envelope = struct {
    gc: *memory.GC,      // private mini-heap owning the message graph
    value: Value,        // root of the copied message, in envelope.gc
    next: ?*Envelope,    // intrusive FIFO link, owned by the queue below
};

pub const SharedChannel = struct {
    refcount: std.atomic.Value(u32),   // one per Channel stub object, across all heaps
    lock: std.Thread.Mutex,            // guards everything below
    queue_head: ?*Envelope,            // intrusive FIFO — O(1) push/pop, no backing
    queue_tail: ?*Envelope,            //   array to compact or shrink (envelopes are
    queue_len: u32,                    //   already individually allocated)
    reserved: u32,                     // slots claimed by in-flight sends (§4)
    capacity: ?u32,                    // null = unbounded (§6)
    closed: bool,                      // §6: close semantics
    recv_waiters: std.ArrayListUnmanaged(*ThreadNotifier),
    send_waiters: std.ArrayListUnmanaged(*ThreadNotifier),
};
```

`SharedChannel` and envelope GC structs are allocated from a process-global
allocator (`std.heap.c_allocator`), never from a per-thread GC — they must
outlive the thread that created them.

**An envelope is a message-sized heap.** `Envelope.init` creates a GC the
same way `GC.initForThread` does (sharing the process-wide symbol table,
which is already mutex-protected —
[`memory.zig:52`](https://github.com/kaappi/kaappi/blob/54706a0c/src/memory.zig#L52));
the sender runs `envelope.gc.deepCopy(value)`; the receiver runs
`receiver_gc.deepCopy(envelope.value)` and then `envelope.gc.deinit()`, which
frees the entire message graph in one sweep. This deliberately reuses the
**whole audited `deepCopy` domain** — pairs, vectors, strings, bytevectors,
all numeric types, records, hash tables, closures with their bytecode
`Function`s — plus its cycle handling (`visited` map) and its re-entrancy
guard (`no_collect`,
[`gc_deep_copy.zig:22`](https://github.com/kaappi/kaappi/blob/54706a0c/src/gc_deep_copy.zig#L22)),
instead of re-implementing a serializer that would have to duplicate all of
it. Symbols re-intern through the shared table
([`gc_deep_copy.zig:70`](https://github.com/kaappi/kaappi/blob/54706a0c/src/gc_deep_copy.zig#L70)),
so they cost one *mutex-guarded* lookup, not a copy — with many threads
exchanging symbol-heavy messages (every record carries its type-name
symbol) the table lock is a contention point Phase 7 measures. A GC struct per message is not free;
measuring it — and replacing it with a reusable arena if it shows up — is
Phase 7's job (Unresolved question 1).

**The refcount state machine (normative) — the protocol instantiated
for channels.** Every reference to a
`SharedChannel` is a counted `Channel` stub, with no exceptions:

- `promoteChannel` creates the `SharedChannel` with **`refcount = 1`** —
  the promoting object itself becomes the first counted stub.
- **`+1`** for every stub allocation: the `deepCopy` `.channel` arm (§2),
  *including* stubs allocated inside envelope heaps.
- **`−1`** in `freeObject` on any stub — a heap collection freeing a
  dead stub, a child heap torn down at `thread-join!`, or an
  `envelope.deinit()` sweeping the envelope's objects. No separate
  envelope bookkeeping exists; envelope stubs release through the same
  `freeObject` path as everything else.
- **`0` ⇒ destroy**: take the lock once, drain and `deinit` every queued
  envelope (which may recursively drop refcounts on channels *inside*
  those messages), release remaining notifier registrations (§7), free.

Worked example — thread A sends its local channel `reply` over an
already-shared `tasks` channel to thread B: promote `reply` (rc 1, A's
stub) → envelope stub allocated during the send copy (rc 2) → B receives
and copies out a stub of its own (rc 3) → `envelope.deinit()` frees the
envelope stub (rc 2). When A's and B's stubs are eventually collected,
rc 1 → 0 and the `SharedChannel` is destroyed. A message that is never
received dies with the channel: destroy-at-zero deinits the queued
envelope, releasing the rc it held.

**Known limitation — reference counting does not collect cycles**
(protocol rule 5; channels are the exposed instance, because only
channel messages can carry stubs). An
envelope stub holds a refcount, so a queued-but-never-received message
that (transitively) contains a stub of the very channel it is queued on
pins that channel forever: after `(channel-send ch ch)`, `ch`'s refcount
can never reach zero even once every thread-local stub is collected —
the last reference is the stub inside `ch`'s own queue. Two channels
queued in each other leak the same way. This is the classic
refcount-cycle leak, accepted rather than solved (Unresolved question 6
revisits with usage data), and bounded in practice by the drain
discipline: a cycle forms only through a message that is *never*
received, and the close-then-drain idiom (§6, §8) consumes queues before
handles are dropped. The unit suite's leak checking treats an
undestroyed `SharedChannel` at process exit as a failure, so accidental
cycles are loud in tests; the guide documents the rule ("don't abandon a
channel that has itself in flight").

### 2. Promotion: one channel type, two representations

`types.Channel` gains one field:

```zig
pub const Channel = struct {
    header: Object,
    head: Value,               // local representation (unchanged)
    tail: Value,
    shared: ?*SharedChannel = null,   // set exactly once, by the owning thread
};
```

`promoteChannel(gc, ch)` — callable **only by the thread that owns the
channel** (`ch.header.owner == gc.id`, which makes it race-free: no other
thread may legally touch an unpromoted channel) — does four things, in
order:

1. allocates the `SharedChannel` with `refcount = 1` (§1 state machine),
   carrying over `capacity`/`closed` (§6);
2. **publishes the pointer (release store) — before the drain.** Early
   publication is what makes promotion re-entrant-safe: a queued message
   may contain the channel itself (`(channel-send ch (list ch))` is legal
   today), so the drain's `deepCopy` in step 3 can meet the very channel
   being promoted. With `shared` already set, the `.channel` arm takes
   the ordinary alias path (stub + `refcount += 1`); were the pointer
   published last, that re-entry would start a *second* promotion of the
   same channel and split its queue between two `SharedChannel`s.
   Publishing early is safe because no other thread can reach the field
   until the triggering `deepCopy`'s result is handed off, strictly after
   promotion completes (invariant 4);
3. drains any queued local values into envelopes in FIFO order, clearing
   `head`/`tail` — recursively promoting (or, per step 2, aliasing) any
   channels inside them;
4. **migrates pre-existing local waiters**: a fiber that parked on the
   *local* representation (`waiting_on == ch` — a receiver on the empty
   queue, or a sender on a full bounded queue) parked under the local wake
   protocol, which no remote thread can see; for each such fiber,
   `promoteChannel` registers the owning thread's own `ThreadNotifier` in
   `recv_waiters`/`send_waiters` on its behalf and enrolls the fiber in
   the scheduler's shared-waiter registry (§5), so the first remote
   send/receive rings this thread and the §5 sweep wakes them. Promotion
   runs inside a primitive on the owning thread — the local scheduler is
   quiescent — so the scan over `sched.fibers` is race-free. Without this
   step, a fiber that parked before promotion could hang forever: remote
   sends ring only *registered* notifiers ("park locally → promote →
   remote send wakes" is a required Phase 3 regression test).

After promotion the heap object is a *stub*: an immutable handle whose only
live field is `shared`.

Promotion is triggered in exactly two places, both on the owning thread:

- **`deepCopy` meets a channel** (thread thunks, messages containing
  channels): the `.channel` arm changes from `UncopyableType` to — promote
  if not yet promoted, then allocate a stub on the target heap pointing to
  the same `SharedChannel`, `refcount += 1`. This is what makes channel
  *identity* survive the copy and reply-to patterns work.
- Nothing else. Channels never promote spontaneously; a program that never
  starts a thread never pays a single atomic.

**Stub lifecycle.** `freeObject` on a promoted channel does
`refcount -= 1`; the last decrement frees the `SharedChannel` and
`deinit`s every queued envelope. Because each heap's stub is an ordinary
GC-managed object, no cross-heap tracing is ever needed.

**Identity.** Two stubs for one `SharedChannel` are distinct heap objects,
so raw `eq?` would report `#f` for "the same channel" seen from two threads.
`eqv?`/`equal?` (and the scheduler's waiter matching, §5) compare the
`shared` pointer when both operands are promoted channels (Unresolved
question 4 confirms the exact predicate set).

**Foreign channel objects become a descriptive error — promoted or not.**
Every channel primitive checks `ch.header.owner != gc.id` and raises
`"channel belongs to another thread; pass it through the thread thunk to share it"`.
The **only** legal cross-thread handle is a locally owned stub created by
`deepCopy` (through a thread thunk or a message). Scope the claim
honestly: the check itself reads the foreign object's header, so it
converts Motivation Path 2 into a clean error only **while the object is
live**. If the owner drops its last reference and its GC frees the
channel — or the owning thread exits and its heap is torn down — a
foreign access through the stale global is still a use-after-free. That
residual hole is a property of the globals-aliasing model itself, which
remains unsound for *every* heap value reached through it (strings and
vectors as much as channels); fixing it is a globals-model change, out of
scope here (kaappi#1455 covers mutex/condvar only). What this KEP
guarantees is narrower and real: the common mistake — a live channel
reached through a shared global — gets a diagnosis and a fix suggestion
instead of silent corruption. An earlier draft blessed *promoted* stubs reached through the
shared globals map; that was wrong — not because reads race (the `shared`
field is write-once-before-spawn on a non-moving heap, and a foreign
reader touches no other byte of the object), but because of **lifetime**:
a foreign user holds no refcount, so rebinding the global lets the owner's
GC free the stub — and possibly the last-referenced `SharedChannel` —
under the foreign thread. Requiring locally owned stubs means the §1
refcount protocol accounts for every user, which in turn makes the §5
deadlock heuristic sound (Unresolved question 2). Debug and `--gc-stress`
builds assert that channel primitives never observe a foreign `owner`.

### 3. Thread thunks and join results become envelopes

`thread-start!`
([`primitives_srfi18.zig:210`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L210))
changes from "root the thunk, let the child copy it later" to: **copy the
thunk into an envelope on the parent thread, before `Thread.spawn`**. The
child then copies out of the envelope into its fresh heap. This costs one
extra copy per `thread-start!` (envelope in + child out, versus one direct
copy today) and buys three things:

- the concurrent-copy race in the Motivation is gone — the copy runs on the
  thread that owns the source heap, and the envelope is immutable afterward;
- channels captured by the thunk are promoted *by the owner*, on the owner's
  thread — the only place promotion is legal;
- the thunk snapshot has clear semantics: the value as of the
  `thread-start!` call. The snapshot is *atomic with respect to all Scheme
  code*, not best-effort: `deepCopy` runs as one native primitive on the
  calling thread with no fiber switch points, so no Scheme mutator — on
  this thread or any other — can run mid-copy (no other OS thread may
  legally mutate this heap at all, and the aliased-object exceptions,
  mutexes and condvars, are uncopyable and error out of the graph before
  any question of tearing arises). No caller-side synchronization is
  needed for compound updates: mutations before the call are in the
  snapshot, mutations after it are not. The flip side of atomicity — one
  uninterruptible copy stalls every fiber on the calling thread for its
  duration — is priced in Drawbacks.

`thread-join!`'s result path is unified the same way: the child's result
(and exception) crosses in an envelope instead of the bespoke
`child_registry.storeResult` deep-copy-at-join
([`primitives_srfi18.zig:300`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L300))
— one mechanism for every value that crosses a thread boundary.

### 4. Send and receive semantics

`channel-send` dispatches on `ch.shared`:

- **null** — today's code path, byte for byte
  ([`primitives_fiber.zig:101`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_fiber.zig#L101)),
  plus the local capacity/closed checks of §6 when set.
- **non-null** — the sequence below. The envelope is built *outside* the
  lock (`deepCopy` allocates and must not hold the channel mutex), and a
  **slot reservation** taken *before* building it makes the eventual push
  infallible. The reservation is what keeps park/retry and error paths
  exactly-once: when a send parks, **no envelope exists yet** — the
  `yield_retry` rewind re-runs only the cheap reservation step, so nothing
  is duplicated, leaked, or lost — and a built envelope always has a slot
  waiting for it.

```
 1. lock
 2.   if closed: unlock → raise "send on closed channel"
 3.   if bounded and queue_len + reserved == capacity:
 4.       register own ThreadNotifier in send_waiters (dedup: no-op if present)
 5.       unlock → park: status .waiting, waiting_on = the stub, yield_retry
 6.       (the retry re-enters at step 1; nothing has been copied yet)
 7.   reserved += 1
 8. unlock
 9. build envelope (deepCopy the payload)
      on failure: lock; reserved -= 1; snapshot-and-clear send_waiters
      (the slot reopened) — and recv_waiters too if closed: a receiver
      may be parked waiting out this very reservation (receive step 6);
      unlock; ring the snapshots; envelope.deinit() — which releases,
      via freeObject, every stub refcount the partial copy took (§1);
      raise. Nothing was enqueued: "send fails ⇒ nothing sent" holds,
      though promotion of reachable channels is sticky (§2, Drawbacks).
10. lock
11.   reserved -= 1; push envelope; snapshot-and-clear recv_waiters
12. unlock
13. ring each snapshotted notifier (§5), releasing its registration
    refcount (§7)
```

Steps 1–7 hold the mutex **continuously**, so the full-check and the
waiter registration cannot interleave with a receive — the classic lost
wakeup (observe full → a receive pops and rings the then-empty list →
register → park forever) is structurally impossible, and no separate
"re-check" step is needed. The residual window — registered but not yet
parked when a remote wake arrives — is closed by the `wake_pending` sweep
ordering in §5. A message becomes visible only at step 11, so a receiver
can never observe a half-built envelope.

**A reservation is the point of no return.** The `closed` check runs only
at admission (step 2). A sender that reserved its slot and released the
lock may find, back at step 10, that a concurrent `channel-close!` has
closed the channel in the interim — the push still proceeds, and the
message is delivered through close's drain-then-EOF rule (§6). "Close
stops sends" therefore means precisely: no send is *admitted* after
close; a send already admitted is never failed after its copy work, and
its message is never lost *or abandoned* — receivers return eof only
once `reserved == 0` (receive step 6), so an admitted message is always
enqueued, and drained by any receiver still looping, before
end-of-stream is observable (model finding 2). (The sender's own stub
holds a refcount, so the channel cannot be destroyed while its send is
in flight.)

`channel-receive` mirrors it:

```
 1. lock
 2.   if queue non-empty:
 3.       pop envelope; snapshot-and-clear send_waiters (a slot opened)
 4.       unlock; ring the snapshot; deepCopy out into own heap;
 5.       envelope.deinit(); return the value
          on copy failure: lock; push the envelope back at the queue
          head (FIFO preserved — the failed receive never happened);
          snapshot-and-clear recv_waiters; unlock; ring; raise.
          "Receive fails ⇒ nothing received": the envelope is untouched,
          its stubs keep their refcounts, the message stays deliverable
          in order, and the ring re-wakes receivers that parked while
          the queue was momentarily empty. (Partial copy-out garbage on
          the receiver's heap is unrooted and collects normally,
          releasing any stub refcounts it took via freeObject.) One
          consequence: the pop's ring may already have admitted a
          sender into the freed slot, so a bounded queue can
          transiently exceed its capacity by the number of concurrently
          failing receives — admission (step 3 of send) remains strict,
          and the overshoot drains with the next receive.
 6.   if closed and reserved == 0: unlock → return (eof-object)     (§6)
 7.   register own ThreadNotifier in recv_waiters (dedup) — reached
      with the channel open, or closed with admitted sends still in
      flight: eof must not race a reservation, so the receiver parks
      and is rung by the late push (or by step 9's failure ring)
 8. unlock → park (.waiting on the stub, yield_retry rewind —
    [primitives_fiber.zig:183])
```

Both waiter snapshots are taken **under the lock** and rung after release
— a live waiter list is never iterated unlocked. Wake policy is
**wake-all** on both sides, matching every existing wake discipline in the
runtime ([`fiber.zig:347`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L347)):
losers of the retry race re-park **and re-register** — the §5 sweep
flips parked waiters unconditionally precisely so that losers get to
run and restore the registration their ring consumed (model finding 1);
the mutex-guarded pop and
reservation-backed push make delivery and enqueue exactly-once. FIFO holds
per channel with respect to *completed* sends: a reservation is not yet an
enqueue, so two racing senders' order is decided at step 11 (they had no
defined order anyway), while a single fiber's sends stay ordered because
it runs them sequentially. Fairness *across* competing receivers is not
guaranteed (same as today's fibers).

The existing caveat that a fiber cannot park under a re-entrant native frame
(README "Fibers" limitation) applies unchanged to shared-channel waits: the
main-thread fallback is a blocking OS-level wait on the notifier rather than
a deadlock error (§5).

### 5. Cross-thread wakeup

Each OS thread's reactor gains a **notifier** — the mechanism KEP-0001
resolved question 4 named as the revisit trigger:

```zig
// reactor.zig additions
pub fn notifyHandle(self: *Reactor) *ThreadNotifier;   // created at Reactor.init
pub fn notify(handle: *ThreadNotifier) void;           // thread-safe, signal-safe

pub const ThreadNotifier = struct {
    refcount: std.atomic.Value(u32),   // held by SharedChannels that registered it
    wake_pending: std.atomic.Value(bool),
    alive: std.atomic.Value(bool),     // cleared at reactor deinit
    backend: ...,                      // kqueue ident or eventfd fd
};
```

- **kqueue (macOS/BSD):** register `EVFILT.USER` once at `Reactor.init`
  (`EV.ADD | EV.CLEAR`); `notify` posts `kevent` with `NOTE.TRIGGER`
  (verified in Zig 0.16 `std.c`: `EVFILT.USER`, `NOTE.TRIGGER = 0x01000000`).
- **epoll (Linux):** an `eventfd(0, EFD.NONBLOCK | EFD.CLOEXEC)`
  (`std.os.linux.eventfd`, `linux.zig:2645`) registered for read (**not**
  ONESHOT — unlike fd registrations, the notifier must stay armed); `notify`
  writes 8 bytes; the poll loop drains it on wake.
- **WASI:** no SRFI-18 threads exist there; `notify` is a no-op and nothing
  ever calls it.

`notify` always does **both**: set `wake_pending` (release store), then
ring the fd. The fd covers a thread blocked in — or about to block in —
`reactor.poll`: a kqueue `EVFILT.USER` trigger and an eventfd counter both
stay pending until retrieved, so a notify that lands just before the
`kevent`/`epoll_wait` call is still delivered (`EV.CLEAR` clears on
*retrieval*, not on the tick of time passing). The flag exists so a thread
busy running Scheme notices without a syscall. The woken thread — never
the sender — sweeps its own fibers under one mandated sequence:

```zig
// The single normative consume protocol, at both wake-check sites:
while (notifier.wake_pending.swap(false, .acq_rel)) sweepSharedWaiters();
// Only after the loop exits false may the scheduler block in
// reactor.poll: a notify arriving after the last swap still rang the
// fd, which poll observes immediately; one arriving before it was
// swept by the loop. No interleaving loses a wakeup.
```

`sweepSharedWaiters` flips to `.suspended` **every** fiber on the
scheduler's **shared-waiter registry** — unconditionally. Filtering the
sweep by per-channel readiness ("non-empty queue for a receiver, free
slot for a sender") looks like an obvious optimization and is unsound:
rings snapshot-and-clear the waiter lists (§4, §6), so a fiber that was
rung but lost the retry race to a faster thread has no registration
left; if the sweep also declines to flip it, nothing ever will — later
sends ring a list its thread is no longer on, and even `channel-close!`
wakes only registered notifiers (model finding 1: a permanent hang,
found as a 25-step counterexample). Flipping unconditionally makes the
§4 wake-all discipline literal: woken fibers retry their primitive,
and losers re-park and re-register under the lock. The cost is spurious
retries bounded by the registry length — acceptable because the
registry holds only shared-channel waiters (below), and in the §9
server topology shared channels stay off the hot path. (The two
targeted alternatives — registrations that persist until a fiber is
actually flipped, or a sweep that re-registers unready fibers — buy
back the spurious retries at the price of taking channel locks from
the sweep and rewriting §7's lifecycle rules; rejected for v1, revisit
only if Phase 7 measures registry-storm retries.)
The registry is a per-scheduler list that a fiber joins when it
parks on a promoted channel and leaves when the sweep flips it (or its
timeout removes it); it is owned and mutated only by the scheduler's own
thread, so it needs no lock, and it holds fiber pointers, not heap
values, so it adds no GC roots (§7). It exists to make the sweep
O(shared-channel waiters) rather than O(all fibers): the
`wakeChannelWaiters`-style full scan
([`fiber.zig:347`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L347))
is fine for local wakes, but a §9 server thread holds thousands of
parked I/O fibers, and walking all of them on every cross-thread message
would put an O(connections) scan on the messaging hot path. Woken fibers
retry their primitive (§4); spurious
wakes re-park. The sweep hooks into the two per-tick wake-check sites that
already exist: `FiberScheduler.schedule()`'s expired-timer check
([`fiber.zig:284`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L284))
runs the swap loop each tick, and `parkOnReactor`
([`fiber.zig:486`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L486))
runs it before blocking and treats a fired notifier fd like any other
readiness event (drain the eventfd / consume the trigger, then sweep).

**Why this stays safe against KEP-0001's fd-reuse analysis:** resolved
question 4 accepted fd-keyed registration *because* no user code runs
between `poll()` and the status flips — a property that cross-thread events
could break. The notifier deliberately carries **no payload**: no fd, no
fiber pointer, no channel pointer crosses threads through the wakeup path.
All state that a foreign thread can touch lives inside `SharedChannel` under
its mutex; fiber statuses are only ever flipped by their owning thread. The
tokio-style recycle race therefore still cannot occur, and no token
indirection is needed.

**Deadlock detection weakens, soundly.** Today an empty-channel receive
with no runnable fibers raises a deadlock error
([`primitives_fiber.zig:183`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_fiber.zig#L183)).
For a *shared* channel, another thread may send at any time, so local
reasoning is only valid when no other thread can hold a reference. Rule:
a wait on a shared channel is treated as "wakeup possible" (block in
`reactor.poll` on the notifier) whenever `refcount > 1` **or** other live OS
threads exist (a process-global atomic thread count maintained by
`thread-start!`/thread exit); only when both are false do today's deadlock
semantics apply. This errs toward blocking — a genuine cross-thread deadlock
hangs like it would in Go — and `channel-receive`'s new timeout arguments
(§6) are the escape hatch. The main-fiber case follows the same rule: where
it would raise a deadlock error today, it instead blocks in `poll` waiting
for the notifier.

The `hasRunnableFibers` / `Reactor.isEmpty` pair
([`fiber.zig:312`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L312),
[`reactor.zig:154`](https://github.com/kaappi/kaappi/blob/54706a0c/src/reactor.zig#L154))
extends accordingly: fibers waiting on externally-referenced shared channels
count as "alive, waiting".

### 6. Bounded capacity, timeouts, and close

Three API extensions round out the model. All three work for **local**
channels too, with their state on `types.Channel` until promotion:
`capacity: ?u32`, `closed: bool`, and a queue-length count join the struct
in §2, and `promoteChannel` carries them into the `SharedChannel` (step 1).
The local implementations need no new wake machinery — a local sender
parks through the existing `waiting_on` protocol, and the two events that
change what a waiter can do (`dequeueChannel` freeing a slot,
`channel-close!`) call `wakeChannelWaiters`
([`fiber.zig:347`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L347)),
which already wakes senders and receivers uniformly; the retry sorts out
who proceeds. Bounded channels therefore do **not** force promotion:
fiber-only backpressure stays on the lock-free path.

- **`(make-channel)` / `(make-channel capacity)`** — default unbounded
  (today's semantics); with a capacity, `channel-send` on a full channel
  parks the sender until a receive frees a slot (backpressure): §4 steps
  3–6 on the shared path, `waiting_on` parking on the local path.
- **Timeouts on both operations** —
  `(channel-receive ch [timeout [timeout-val]])` **and**
  `(channel-send ch v [timeout [timeout-val]])`, SRFI-18-style, exactly
  the shape `thread-join!` already accepts
  ([`primitives_srfi18.zig:431`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L431)),
  implemented on the reactor timer heap that timed waits already use.
  Without `timeout-val`, expiry raises (matching `thread-join!`'s
  `join-timeout`); with one, it is returned. Send timeouts exist for
  symmetry: Drawbacks leans on timeouts as the escape hatch for weakened
  deadlock detection, and a sender parked on a full channel in a
  cross-thread deadlock needs the same hatch as a receiver. A timed-out
  waiter simply stops waiting; any notifier registration it left behind is
  cleaned up by the §7 lifecycle rules (a stale ring is a harmless
  spurious sweep).
- **`(channel-close! ch)` / `(channel-closed? ch)`** — end-of-stream as a
  first-class state. The shared-path sequence, same shape as §4:

  ```
   1. lock
   2.   if closed: unlock → return                          (idempotent)
   3.   closed = true
   4.   snapshot-and-clear recv_waiters AND send_waiters — close wakes
        everyone, both directions
   5. unlock
   6. ring every snapshotted notifier (§5); wake local waiters
      (wakeChannelWaiters)
  ```

  (The local path is steps 2, 3, and the local wake of 6.) Effects on
  each party, exhaustively: **parked and future senders** observe
  `closed` at §4 step 2 and raise `"send on closed channel"`; a sender
  that had already **reserved** before the close completes its push and
  the message is delivered — reservation-as-admission (§4), so close
  never fails a send after its copy work and never loses an admitted
  message. **Receivers** drain the remaining queue first — including
  late reservation-admitted pushes: the queue check precedes the closed
  check, and eof additionally requires `reserved == 0` (§4 receive
  step 6), so a receiver that arrives inside an admitted send's copy
  window parks and is rung by the late push (or by the failure path's
  closed-channel ring, §4 step 9) instead of returning a premature
  end-of-stream that would abandon the admitted message (model
  finding 2; the local path has no reservation window and is
  unaffected) — then return
  `(eof-object)`, the same end-of-stream convention as ports, so the
  worker-loop idiom needs no sentinel protocol:
  `(let loop ((x (channel-receive ch))) (unless (eof-object? x) … (loop (channel-receive ch))))`.
  One check keeps the sentinel unambiguous: `(eof-object)` is a
  first-class value, and a *sent* eof-object would be indistinguishable
  from end-of-stream at the receiver — unlike ports, whose read side can
  never yield a data eof. `channel-send` therefore rejects it before §4
  step 1 (one immediate-value comparison, no lock, both representations):
  `"cannot send an eof-object on a channel; use channel-close! to end the stream"`.
  The idiom that would naturally hit this — a port-to-channel bridge
  looping `(channel-send ch (read-line p))` past the port's end — is
  exactly the case the error message redirects to `channel-close!`.
  **Queued envelopes** at destroy-at-zero are deinit'd by the §1 rule
  regardless of closed state. Close is legal only through a locally owned
  handle (§2). Without first-class close, every pool and server invents
  ad-hoc sentinels; §8's `pool-shutdown!` is the immediate consumer.

### 7. GC and teardown interactions

- **Marking:** a promoted stub has no heap-value fields to trace (its
  `head`/`tail` are NIL); envelopes are invisible to every collector —
  their GCs are never registered for collection and never collect (filled
  once under `deepCopy`'s `no_collect`, freed wholesale).
- **`markFiberState` / write barriers:** `waiting_on` already traced
  ([`fiber.zig:570`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L570));
  no new Value fields are added to `Fiber`.
- **Waiter-list lifecycle (normative):** at most **one entry per
  `ThreadNotifier` per list** — registration dedups by pointer (a no-op if
  the thread is already registered, however many of its fibers wait) and
  takes `+1` on the notifier. An entry is removed, releasing that
  refcount, when: (a) a notify **snapshots-and-clears** the list (§4/§6 —
  the ringer releases after ringing; threads whose fibers re-park simply
  re-register), (b) the channel is destroyed at refcount zero, or (c) any
  path holding the lock finds `alive == false` and prunes opportunistically
  (send, receive, close, promotion, destroy). A timed-out waiter's entry
  may thus persist until the next ring — one harmless spurious sweep — but
  dedup bounds total retained state at *threads × channels* regardless of
  waiter churn, and the per-entry refcount makes lazy pruning UAF-free.
- **Thread teardown:** the child VM/GC teardown at join is unchanged —
  envelopes queued by the dead thread are *not* on its heap and survive it;
  that is the point. Its `ThreadNotifier` flips `alive = false` and drops
  the reactor backing; `notify` on a dead handle is a no-op; its remaining
  list entries are pruned per the lifecycle rules above (the refcount keeps
  the struct itself valid until the last entry is released).
- **`--gc-stress` and leak discipline:** `SharedChannel`, envelopes, and
  notifiers form a new class of non-GC-managed, refcounted runtime state.
  Every phase lands with thread-churn tests under `-Dgc-stress=true` and
  the unit suite's leak checking; the refcount protocol above is the
  complete ownership story (stubs own the SharedChannel; the SharedChannel
  owns queued envelopes and notifier references).

### 8. `(kaappi parallel)` — multi-core scheduling as a library

With shared channels, the multi-core story needs almost no new runtime. The
library is pure Scheme over `(srfi 18)` + `(kaappi fibers)`:

```scheme
(define-record-type pool (make-pool* tasks threads) pool?
  (tasks pool-tasks) (threads pool-threads))

(define (make-pool n)
  (let ((tasks (make-channel)))
    (make-pool*
      tasks
      (map (lambda (_)
             (thread-start!
               (make-thread
                 (lambda ()
                   (let loop ((msg (channel-receive tasks)))  ; parks on the notifier
                     (unless (eof-object? msg)      ; closed ⇒ drain queue, then exit
                       (let ((thunk (car msg)) (reply (cdr msg)))
                         (channel-send reply
                           (guard (e (#t (cons 'error e)))
                             (cons 'ok (thunk)))))
                       (loop (channel-receive tasks))))))))
           (iota n)))))

(define (pool-submit pool thunk)
  (let ((reply (make-channel)))          ; promoted on send (owner-side), aliased in
    (channel-send (pool-tasks pool) (cons thunk reply))  ; raises after shutdown
    reply))

(define (task-wait reply)
  (let ((r (channel-receive reply)))
    (if (eq? (car r) 'ok) (cdr r) (raise (cdr r)))))

(define (pool-shutdown! pool)
  (channel-close! (pool-tasks pool))     ; workers drain queued tasks, then see EOF
  (for-each thread-join! (pool-threads pool)))
```

Shutdown semantics fall out of §6's close protocol rather than sentinel
messages: `pool-shutdown!` closes the task channel (waking all idle
workers at once), each worker finishes its current task, drains any
still-queued tasks, exits on `(eof-object)`, and is joined. Tasks
submitted before shutdown all run and their replies stay receivable —
including a submit that *races* the shutdown: reservation-as-admission
(§4) plus the `reserved == 0` eof rule (§6) guarantee that a task
admitted before the close is drained by some worker before any worker
sees end-of-stream (model finding 2 showed the pre-amendment protocol
silently dropping exactly such a task, hanging its `task-wait`);
`pool-submit` after shutdown raises the closed-channel error.

`parallel-map` / `parallel-for-each` chunk the input, submit, and reassemble
in order. Exports: `make-pool`, `pool-submit`, `task-wait`, `pool-shutdown!`,
`parallel-map`, `parallel-for-each`, `processor-count`. Every task thunk and
result crosses by copy — the library documentation leads with that.

One new primitive: **`processor-count`** via `std.Thread.getCpuCount`
(`Thread.zig:293`), registered in `(kaappi parallel)`.

Deliberate non-features (see Alternatives): no fiber migration, no work
stealing, no shared task deque. A fiber's saved state is a slice of its
heap's registers/frames; it is meaningless on another heap. Parallelism
granularity is the *task*, chosen by the user; concurrency granularity
within each worker remains the fiber.

### 9. Multi-core HTTP (ecosystem, depends on KEP-0001 Phase 5)

`kaappi-net` grows a `reuseport` option (one `setsockopt(SO_REUSEPORT)` in
`csrc/kaappi_net.c`). `kaappi-http` adds:

```scheme
(http-listen-parallel port handler)                    ; processor-count threads
(http-listen-parallel port handler thread-count)
```

Each thread opens its own `SO_REUSEPORT` listen socket and runs
`http-listen-fiber` — zero fd passing, zero shared accept state. One
platform caveat is load-bearing: **`SO_REUSEPORT` only balances on
Linux.** Linux (≥3.9) hashes the connection 4-tuple across all listening
sockets; Darwin/BSD merely *permit* the shared bind, and TCP connections
concentrate on the most recently bound socket (FreeBSD grew
`SO_REUSEPORT_LB` precisely because of this; macOS has no equivalent).
Since macOS is the primary dev platform, Phase 6 starts by measuring
per-socket accept distribution on both kernels; if Darwin skews as badly
as its reputation, `http-listen-parallel` there falls back to a
userspace distributor — one acceptor thread handing accepted fds (plain
fixnums, valid process-wide) over a shared channel to workers that wrap
them into ports locally. Linux keeps the kernel-balanced path either
way. Shared channels are otherwise not on the hot path; they
carry only the shutdown signal. This slots into the server-model table from
KEP-0001's motivation as the fourth entry: *threads × fibers = cores ×
thousands of connections*.

**Measured (Phase 6, [kaappi#1471](https://github.com/kaappi/kaappi/issues/1471)).**
The accept-distribution harness (P7,
[`kaappi-net/research/reuseport-accept-distribution/`](https://github.com/kaappi/kaappi-net/tree/main/research/reuseport-accept-distribution))
ran N ∈ {2, 4, 8, cores} listeners on one `SO_REUSEPORT` port against
M = 10 000 short-lived connections. **Linux** (kernel 6.8, x86_64) spread
accepts near-uniformly — max/min per-listener ratio 1.03–1.14, chi-squared
2.31–15.55. **Darwin** (25.5.0, aarch64) put **100 % of connections on the
last-bound socket** at every N (max/min = ∞). The reputation is exactly
right. Since Darwin's ratio at N = cores (∞) exceeds the pre-registered
threshold of 3, the criterion fires and the userspace fd-distributor
fallback is implemented; Linux keeps the plain kernel-balanced path.

Two facts the implementation surfaced, recorded here so §9 matches what
shipped. First, the fallback keeps the **full threads × fibers model** — each
worker fiber-multiplexes its connections just like the Linux path. The one
constraint that shapes *how* is that a secondary thread which **blocks** in
`channel-receive` does not run its other ready fibers, so a worker cannot
block-receive the next fd and still serve the ones it holds. The workers
therefore **poll** the fd channel with a zero timeout and yield with
`thread-sleep!` (which does dispatch sibling fibers) between polls; a spawned
handler fiber per fd then runs during those yields. Polling also keeps the
hand-off off the cross-thread-wakeup path entirely. (An earlier draft of this
section claimed the fallback was limited to worker-count concurrency; that was
an artifact of a stale build, corrected here — verified multiplexing:
20 concurrent requests with a 100 ms handler across 2 workers complete in
~0.3 s, not ~1 s.) Second, the shipped signature is
`(http-listen-parallel handler port [thread-count [host]])` — *handler first*
— to match the four existing `http-listen-*` procedures, rather than the
port-first order sketched above.

## Drawbacks

- **Two copies per message** (in to envelope, out to receiver). This is the
  price of keeping heaps isolated and primitives lock-free, and it is the
  same asymptotic cost `thread-start!`/`thread-join!` already charges. Big
  read-mostly data fanned out to N workers is copied N times; a
  shared-immutable-data story is future work, not this KEP.
- **A large send stalls its whole scheduler.** The §3 snapshot guarantee
  exists *because* `deepCopy` runs as one native primitive with no fiber
  switch points — so a multi-megabyte `channel-send` (or thunk copy)
  blocks every fiber on that core, including thousands of parked server
  connections in the §9 topology, for the duration of the copy. BEAM
  affords copy-at-boundary semantics because it preempts on reductions; a
  cooperative scheduler cannot. Applications chunk large payloads;
  Phase 7's gate measures tail latency (not just throughput) under
  concurrent large sends, and the refcounted immutable-payload lever
  (Unresolved question 1) is the structural fix for big read-mostly data.
- **Envelope overhead.** A GC struct per message is heavier than a malloc'd
  byte buffer. Accepted to reuse the audited `deepCopy` (correctness first);
  Phase 7 measures and, if needed, swaps the envelope backing for a reusable
  arena behind the same interface.
- **Queued envelopes are invisible to GC accounting.** They live outside
  every heap, so a fast producer against a slow consumer grows process
  memory that no collection heuristic sees or reclaims — nothing pushes
  back until the OS does. Bounded channels (§6) are the mitigation: give
  cross-thread pipelines a capacity so producers park instead of queueing
  without limit.
- **`thread-start!` gets marginally slower** (one extra thunk copy) in
  exchange for deleting a real race. Thunks are typically small closures.
- **Weakened deadlock detection** on shared channels: cross-thread deadlocks
  hang (as in Go) rather than raise, mitigated by receive timeouts.
- **New unmanaged-memory surface.** Refcounted `SharedChannel` / envelope /
  notifier lifetimes are exactly the kind of manual protocol the GC
  otherwise spares us; the teardown discipline in §7 plus gc-stress
  thread-churn tests are the containment.
- **Refcount cycles leak.** A never-received message containing (a stub
  of) the channel it is queued on — `(channel-send ch ch)` — pins the
  `SharedChannel` forever (§1). Accepted: a cycle requires abandoning a
  channel with itself in flight, leak checking makes it loud in tests,
  and Unresolved question 6 holds the door open for a detector if real
  programs hit it.
- **Promotion is sticky and can be incidental.** Any channel reachable
  from a sent value (including via closure capture) is promoted as a
  `deepCopy` side effect — even if the send subsequently fails — and never
  demotes. Never incorrect, only slower for that channel from then on;
  documented in the guide (don't capture channels you want kept local).
- **`eq?` on channels is no longer identity across threads** (stubs);
  `eqv?`/`equal?` compensate, but it is a subtlety users can trip on.
- **Channel dispatch branch** on every send/receive — one predictable
  null-check on the local fast path; expected unmeasurable, verified in
  Phase 1 benchmarks.

## Alternatives considered

- **Shared heap with a global interpreter lock.** Makes every value
  trivially sharable and every program single-core again — the opposite of
  the goal. Rejected.
- **Shared heap with a concurrent GC.** The honest way to get shared
  mutable state, and a multi-year rewrite: every one of 601 primitives, the
  write barrier, and the entire rooting discipline (`.claude/rules/gc-safety.md`)
  assume single-threaded heaps. The share-nothing model is Kaappi's
  load-bearing simplification; this KEP builds *on* it rather than replacing
  it. Rejected (revisit only with overwhelming evidence).
- **Single-copy messages (sender-heap reference, copy at receive).** Halves
  the copy cost but couples lifetimes across threads: the sender's heap must
  pin every in-flight message (cross-thread root registration racing the
  sender's collections) and must outlive consumption (a thread cannot exit
  with messages in flight — or must migrate them at exit, which is the
  envelope copy anyway, now on the teardown path). Rejected: the coupling
  buys back one copy and spends it on the GC's simplicity.
- **Flat byte serialization instead of envelope GCs.** A compact encoder
  would be faster per message but must re-implement the entire copyable
  domain — cycles, records, hash tables, closures *with bytecode* — that
  `deepCopy` and `bytecode_file.zig` only jointly cover today. Deferred as a
  Phase 7 optimization behind the `Envelope` interface, not a design change.
- **Transparent work stealing / fiber migration.** A fiber's saved state is
  registers and frames full of pointers into its owning heap
  ([`fiber.zig:28`](https://github.com/kaappi/kaappi/blob/54706a0c/src/fiber.zig#L28));
  migrating one means deep-copying arbitrary suspended VM state including
  continuations — the exact things `deepCopy` correctly refuses. Go affords
  migration because goroutines share one heap. Rejected as incompatible
  with isolated heaps; tasks (closures over channels) are the migration
  unit instead.
- **A distinct `shared-channel` type.** Simpler to implement (no promotion),
  but forks the API in two, makes library code choose a lane in advance, and
  turns "hand your channel to a thread" into a type error instead of just
  working. Promotion confines all the complexity to thread boundaries.
  Rejected; noted as the fallback if promotion proves subtler than specified.
- **Erlang-style per-thread mailboxes.** A mailbox is a channel you make at
  spawn time; channels are strictly more general (M:N, first-class,
  reply-to) and already exist in the API. Rejected.

## Prior art

How other runtimes answer the same two questions — *what crosses a thread
boundary, and who guarantees that's safe* — sorted by where the guarantee
lives. (Survey current as of 2026-07; links verified.)

| System | Heap model | Message cost | Safety guaranteed by | Fibers/tasks migrate? |
|---|---|---|---|---|
| **Kaappi (this KEP)** | isolated per thread | copy in + copy out (envelope) | runtime copy at boundary | no |
| [Erlang/BEAM](https://www.erlang.org/blog/message-passing/) | isolated per process | one copy (into receiver heap/fragment) | runtime copy at boundary | yes (schedulers steal processes) |
| [Racket places](https://docs.racket-lang.org/reference/places.html) | isolated per place | copy; restricted to immutable transparent values | runtime copy + message-type restriction | no |
| [Dart isolates](https://medium.com/dartlang/dart-2-15-7e7a598e508a) | logically isolated, physically shared (isolate groups) | copy, or O(1) transfer at `Isolate.exit` | runtime copy / whole-graph transfer | no |
| [Pony + ORCA](https://dl.acm.org/doi/10.1145/3133896) | per-actor heaps, zero-copy sharing | zero (reference passed) | static reference capabilities + ORCA GC protocol | yes (work-stealing actor scheduler) |
| [Swift 6 regions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md) | shared | zero (`sending` transfers ownership) | compile-time region/flow analysis | tasks hop executors |
| [Verona BoC](https://microsoft.github.io/verona/publications.html) | isolated regions | zero (region ownership transfer) | region type system + `when` scheduling | behaviours scheduled freely |
| [OCaml 5](https://arxiv.org/abs/2004.11663) | shared (domains) | zero (reference) | programmer (+ `Atomic`, race-checked libs) | fibers stay on their domain; domainslib steals tasks |
| [Go](https://go.dev/) | shared | zero (reference) | programmer + race detector | yes (goroutine work stealing) |
| [Guile fibers](https://github.com/wingo/fibers/wiki/Manual) | shared (Boehm GC) | zero (reference) | programmer | **yes — work stealing across per-core schedulers** |
| [CPython 3.14 free-threading](https://peps.python.org/pep-0703/) | shared | zero (reference) | per-object locks + biased refcounting | threads are OS threads |

**The copy-at-boundary family (where this KEP sits).** Erlang is the
existence proof that per-process heaps + copied messages scale to
million-process systems; the [BEAM's own
retrospective](https://www.erlang.org/blog/message-passing/) frames copying
as the *enabler* of pauseless-in-practice GC, not a compromise. Its three
refinements after 25 years of production are instructive: (1) large
binaries (>64 bytes) live in a **process-independent refcounted heap** and
cross by reference; (2) an
[`off_heap` message-queue mode](https://www.erlang.org/doc/system/eff_guide_processes.html)
lets senders allocate messages outside the receiver's heap to cut lock
contention — structurally the same move as this KEP's envelopes; (3)
literals are shared read-only. [Racket
places](https://users.cs.northwestern.edu/~robby/pubs/papers/dls2010-tsffd.pdf)
(DLS 2011) is the closest published relative — separate VM instances per OS
thread, channels carrying copied immutable data — and its escape hatch
(`shared-flvector`/`shared-bytes`: mutable flat numeric data visible to all
places) marks exactly where copy-semantics pinches first: big flat numeric
arrays. [Dart 2.15](https://medium.com/dartlang/dart-2-15-7e7a598e508a)
kept isolate *semantics* but moved isolates of a group onto one physical
heap, so `Isolate.exit` can hand the entire result graph to the parent in
constant time instead of copying.

**The static-isolation family.** [Pony's
ORCA](https://www.ponylang.io/media/papers/OGC.pdf) (OOPSLA 2017) and
[Swift's region-based isolation](https://www.massicotte.org/concurrency-swift-6-se-0414/)
(SE-0414/SE-0430, shipped in Swift 6, 2024) get zero-copy messaging by
proving statically that the sender cannot touch the value after sending —
via reference capabilities and control-flow region analysis respectively.
Microsoft's [Verona / Behaviour-Oriented
Concurrency](https://microsoft.github.io/verona/publications.html)
(OOPSLA 2024) is the current research frontier of the same idea (isolated
regions + `when` behaviours, data-race- and deadlock-free by construction),
now being retrofitted to Python as
[Pyrona](https://microsoft.github.io/verona/pyrona.html). None of this
transfers to a dynamically-typed R7RS Scheme: without a type system to
carry the proof, "sender no longer uses it" cannot be checked, so the
runtime copy is what remains.

**The shared-heap family, and what it costs.** [OCaml
5](https://arxiv.org/abs/2004.11663) (ICFP 2020) is the best-documented
retrofit: roughly a decade from Multicore OCaml's start to release,
centered on a mostly-concurrent major GC with stop-the-world parallel minor
collections. [CPython's free-threading](https://peps.python.org/pep-0703/)
(PEP 703, officially supported in 3.14, October 2025) replaced the GIL with
biased refcounting plus per-object locks at the cost of ~5–10%
single-thread overhead and a multi-year ecosystem migration
([PEP 779](https://peps.python.org/pep-0779/) targets default-on toward the
end of the decade). Two datapoints cut the other way and are worth naming:
**Kotlin/Native launched with an isolation model** (only *frozen* object
graphs could cross threads) **and abandoned it** in 1.7.20 for a shared
heap with a tracing GC, because freezing was too restrictive in practice
([migration guide](https://kotlinlang.org/docs/native-migration-guide.html))
— an ergonomics warning this KEP answers with transparent promotion rather
than a new type and a new failure mode. And [Guile
fibers](https://wingolog.org/archives/2017/06/29/a-new-concurrent-ml) — the
nearest neighbor, a Concurrent-ML library for the other major R7RS-adjacent
Scheme — runs one scheduler per core **with work stealing of fibers across
cores**, which is only possible because Guile sits on a shared
(Boehm-Demers-Weiser) heap; even so, its manual notes allocation scaling is
sub-linear across NUMA nodes. That contrast is the clearest justification
for this KEP's no-migration stance: fiber migration is a shared-heap
feature, and Kaappi's isolated heaps are the deliberate foundation of its
lock-free primitive layer.

**Lessons folded into this design, and future levers it leaves open:**

1. *Envelopes off the receiver's heap* mirror BEAM's `off_heap` strategy —
   senders never contend on receiver-heap allocation (§1, §4).
2. *Erlang's refcounted binary heap* suggests the natural first
   copy-elision: large **immutable** payloads (bytevectors, strings) could
   cross by refcounted reference without breaking the no-shared-mutable
   invariant. Folded into Unresolved question 1 as the measured escape
   hatch, alongside the immediate fast path.
3. *Dart's `Isolate.exit`* suggests a heap-adoption optimization for
   `thread-join!`: Kaappi's heaps are non-moving linked object lists, so a
   dying child's *entire heap* could in principle be spliced into the
   parent's GC (re-stamping `Object.owner`) instead of deep-copying the
   result — O(live objects) re-stamping versus O(result size) copying, a
   win when the result *is* most of the heap. Noted as a Phase 7 candidate,
   not a commitment.
4. *Racket's shared flat vectors* mark the pressure point (numeric arrays)
   to watch for in `parallel-map` workloads before inventing any
   shared-memory type.
5. *WebAssembly's
   [shared-everything-threads](https://github.com/WebAssembly/shared-everything-threads)
   proposal* (in active development, 2025–2026) may eventually give the
   WASM target real threads; the notifier abstraction should keep its
   backend pluggable rather than assume WASI stays single-threaded forever.

## Cross-platform / compatibility impact

- **Platforms.** kqueue `EVFILT.USER` (macOS/BSD) and `eventfd` (Linux
  x86_64/aarch64/riscv64 — plain syscalls, no arch concerns). Both verified
  present in Zig 0.16's std.
- **WASM/WASI.** No OS threads, so no promotion ever happens; channels
  behave exactly as today. `notify` compiles to a no-op behind the existing
  `is_wasm` gating. `(kaappi parallel)` on WASM: `processor-count` returns 1
  and `make-pool` degrades to running tasks on the calling thread's fibers
  (documented).
- **Sandbox mode.** SRFI-18 thread creation stays blocked; same degradation
  as WASM.
- **Backward compatibility.** Additive at the API level with one
  carve-out: sending a literal `(eof-object)` down a channel — previously
  legal and meaningless — becomes an error, because §6 gives eof the
  end-of-stream meaning (no test-suite or ecosystem code does this
  today). Single-thread fiber programs: no semantic change, and "no
  measurable performance change" is enforced by the Phase 1 fast-path
  benchmark gate (invariant 3). Thread thunks that capture channels: used
  to error, now work. Channels reached via shared globals from a child:
  used to be silent memory corruption (Motivation), now a descriptive
  error while the object is live (§2 scopes the residual lifetime hole)
  — undefined behavior narrowed, not eliminated.
  `thread-start!` thunk snapshot timing moves from "sometime after spawn,
  racy" to "at the call" — programs that relied on post-start mutation of
  captured data were racing; none exist in the test suites or ecosystem.
- **kaappi#1455 (cross-thread mutex/condvar).** Orthogonal and compatible:
  that PR fixes the existing globals-aliased SRFI-18 primitives; this KEP
  adds no new mutex semantics. A later cleanup may reimplement cross-thread
  condvar waits on the notifier instead of the 1 ms sleep-poll loop
  ([`primitives_srfi18.zig:449`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L449))
  — noted, not required.

## Unresolved questions

*Questions 1, 2, and 6 have research plans — literature, method, and
pre-registered decision criteria — in
[`research/open-problems.md`](../research/open-problems.md) (P3, P4,
P6), which also covers the §§4–6 protocol-verification plan (P2) and
the §9 accept-distribution measurement (P7).*

1. **Envelope cost.** Is a GC struct per message acceptable for small hot
   messages (fixnums, short strings)? Phase 1 lands a
   `channel-send`/`channel-receive` cross-thread micro-benchmark; Phase 7
   decides whether the envelope backing becomes a reusable arena. Two
   copy-elision levers to evaluate with the benchmark in hand: immediates
   can skip the envelope entirely (a fixnum needs no heap), and large
   **immutable** payloads (bytevectors, strings) could cross by refcounted
   reference in a process-wide side heap — BEAM's proven design for >64-byte
   binaries (see Prior art) — without breaking the no-shared-mutable
   invariant.
2. **Deadlock heuristic precision.** §2's rejection of foreign-owned
   handles means every legal user of a `SharedChannel` holds a counted
   stub, so per-channel `refcount > 1` is by itself a sound "another
   thread may act" test — an envelope in flight holds a stub refcount too,
   so even an unreceived message keeps the channel "externally
   referenced". The narrowed question: is the coarse "other live threads
   exist" disjunct still needed at all, or can it be dropped in favor of
   pure refcount reasoning? Settle during Phase 3 review with the test
   matrix.
3. **Unify `thread-join!` timeouts with the notifier.** The OS-thread join
   path polls status at 1 ms
   ([`primitives_srfi18.zig:449`](https://github.com/kaappi/kaappi/blob/54706a0c/src/primitives_srfi18.zig#L449));
   a child could `notify` its parent at exit instead. In scope for Phase 3
   if cheap, else follow-up.
4. **Equality surface.** Exactly which predicates unwrap stubs: `eqv?` and
   `equal?` certainly; does `eq?` too (making stubs fully transparent, at
   the cost of a special case in a hot primitive)? Also: should `write`
   print a stable shared-channel id for debugging?
5. **`parallel-map` chunking policy** (one task per element vs. N chunks)
   and whether `pool-submit` results should be first-class channels (as
   specified) or an opaque `task` record. Library-level; decide in Phase 5
   with usage feedback from the examples repo.
6. **Cycle leaks.** §1 accepts that reference counting never reclaims a
   channel kept alive only by stubs inside its own (or a peer's) queued
   envelopes. Revisit after Phase 5 if real programs form such cycles;
   the candidates are a debug-build cycle reporter (trial deletion over
   the stub graph at leak-check time) or documentation alone. A general
   cycle collector is out of proportion to the structure.

## Implementation plan

Phases 1–4 are the critical path, in order. Phase 5 needs 3; Phase 6 needs
KEP-0001 Phase 5; Phase 7 needs 4.

**Phase 1 — SharedChannel core, single-threaded.** `src/shared_object.zig`
(the generic shared-object protocol: refcounted header, stub
alloc/release helpers, leak-check hook); `src/shared_channel.zig`
(SharedChannel as the protocol's first instance, with the intrusive
envelope FIFO, Envelope, the full §1
refcount state machine — owner stub = 1, destroy at zero); `Channel.shared`
field; owner-side promotion with local-queue drain and local-waiter
migration (§2); `deepCopy` `.channel` arm (promote + alias); the §4
send/receive sequences on the shared representation, including slot
reservation and the failure path (reservation released, envelope deinit,
nothing enqueued); foreign-owner error for all channel primitives.
Everything testable on one thread (promote, send, receive,
channel-in-channel, refcount teardown, failed-send atomicity, and
re-entrant promotion — promoting a channel whose own queue contains it,
§2 step 2), plus the local fast-path benchmark (invariant 3's gate).
Merge gate: the P2 model suite (`research/tla/run.sh` in the KEPs repo)
stays green; any §4–§6 pseudocode change re-runs it first — amendment
before code.

**Phase 2 — Envelopes at thread boundaries.** `thread-start!` copies the
thunk into an envelope parent-side (closing the concurrent-copy race);
`thread-join!` result/exception via envelope; retire the direct
parent-heap→child `deepCopy` and `child_registry.storeResult` special case;
process-global live-thread counter. First real cross-thread channel tests
(send before receiver parks — no wakeup machinery needed yet; a receiver
that parks first hangs until Phase 3, so Phases 2 and 3 ship in the same
release).

**Phase 3 — Cross-thread wakeup.** `ThreadNotifier` + `Reactor.notify`
(`EVFILT.USER` / `eventfd` / WASI no-op); single-lock-hold registration
with snapshot-and-clear wakes (§4) and the normative waiter lifecycle
(§7: dedup, per-entry refcount, opportunistic pruning); the per-scheduler
shared-waiter registry and the `wake_pending`
swap-loop protocol at both wake-check sites (§5); refcount-aware deadlock
semantics including the main-fiber blocking path; notifier teardown.
Regression test: park locally → promote → remote send wakes (§2).
Second regression: a rung receiver that loses the pop race re-parks,
re-registers, and is woken by the next ring — the unconditional-sweep
guarantee (§5, model finding 1).
Multi-thread stress tests (N producers / M consumers × waiter churn ×
`-Dgc-stress=true`), plus the kaappi#1455 mutex/condvar suite re-run to
confirm no interaction.

**Phase 4 — Capacity, timeouts, and close.** `(make-channel capacity)`
with send-side parking (slot reservation shared-side, `waiting_on`
local-side); timeout/timeout-val on **both** `channel-send` and
`channel-receive` via the reactor timer heap; `channel-close!` /
`channel-closed?` with drain-then-EOF receive semantics and wake-all;
the local-channel `capacity`/`closed` fields and `dequeueChannel` wake
(§6); the eof-object send rejection (§6). Required interleaving tests
from the model: reserve → concurrent close → push completes and the
message is drained before EOF (reservation-as-admission, §4); all
until-eof workers racing a reserved send across close — the admitted
task is drained, not destroyed (§6 `reserved == 0` eof rule,
finding 2); copy failure of the last reserved send on a closed channel
— the failure ring wakes eof-waiting receivers (§4 step 9, finding 3);
and a failed receive re-queues at the head with the message redelivered
in order (§4 receive step 5), including the transient capacity
overshoot on a bounded channel.

**Phase 5 — `(kaappi parallel)`.** The library (pool, submit, wait,
parallel-map/for-each, shutdown), the `processor-count` primitive, WASM
degradation, docs page, and a worked example in `kaappi-examples`.

**Phase 6 — Ecosystem.** `reuseport` option in `kaappi-net`; measure
per-socket accept distribution on Linux and macOS first (§9's caveat) and
implement the Darwin userspace-distributor fallback if the skew demands
it; `http-listen-parallel` in `kaappi-http`; benchmark against
`http-listen-threaded`/`-prefork`/`-fiber`; documentation of the four server
models; correct the concurrency chapter of *The Kaappi Book*.

**Phase 7 — Performance.** Cross-thread message micro-benchmarks; envelope
arena (and/or immediate fast path) if Phase 1/3 numbers demand it;
`parallel-map` scaling curve vs. core count; notifier coalescing under
send storms; tail latency of a fiber server under concurrent large sends
(the head-of-line drawback); symbol-table lock contention with
symbol-heavy messages across many threads (§1).
