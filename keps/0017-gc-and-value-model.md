# KEP-0017: The Value Representation and Per-Heap Garbage Collector

| Field | Value |
|-------|-------|
| **KEP** | 0017 |
| **Title** | The Value Representation and Per-Heap Garbage Collector |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/types.zig`, `src/memory.zig`, `src/gc_alloc.zig`, `src/gc_collect.zig`, `src/gc_sweep.zig`, `src/runtime_exports.zig`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. There is **no**
dedicated `docs/dev/memory.md` / `gc.md` / `values.md`; the closest prose is
`docs/dev/gc-safety-and-error-handling.md` (rooting, write barrier,
generational statement) and `docs/dev/thread-value-sharing.md` (the
cross-thread dimension — see the scope note). This KEP is the first
consolidated internal spec of the value model and the per-heap collector.*

## Scope

This KEP specifies **one thread's** memory model: the NaN-boxed value
representation, the heap object layout, the generational mark-and-sweep
collector that manages a single heap, precise rooting, allocation, and weak
references / finalization. It deliberately does **not** re-specify the
*multi-heap* concurrency dimension — per-thread heaps, owner-skipping marks,
the `CollectionState` stop-the-world safepoints across threads, and the
deep-copy at thread/channel boundaries. That belongs to
[KEP-0002](0002-cross-thread-channels.md) (Cross-Thread Channels and
Multi-Core Fiber Scheduling), and is cited-and-deferred where it touches the
collector below. In one sentence: **KEP-0017 owns the per-heap collector and
value representation; coordination among multiple per-thread heaps is
KEP-0002.**

("Per-heap," not "single-generation": the collector *is* generational — two
generations with a write barrier — but each thread owns exactly one heap.)

## Summary

A Kaappi `Value` is a NaN-boxed `u64`. Flonums are packed directly into the
word with no heap allocation; fixnums are a signed 48-bit payload
(magnitude ~2^47, auto-promoting to bignum on overflow); booleans,
characters, nil, eof, void, and undefined are immediates; and everything
else is a tagged pointer to an 8-byte-aligned heap `Object` whose header
carries the type tag, GC mark bit, generation, and an intrusive allocation
link. The collector is a **precise, non-moving, stop-the-world generational
mark-and-sweep**: young and old generations, minor collections every cycle
and a full collection every eighth, with a write barrier and remembered set
tracking old→young edges. It never scans the C stack — reachability comes
entirely from an explicit root set (a push/pop shadow stack plus VM
registers, frames, interned symbols, and the global environment). The value
model landed in v0.6.0; the generational collector in v0.8.0.

This is a retroactive, *as-built* KEP. It proposes no behavioural change. Its
job is to turn "read `types.zig` and four `gc_*.zig` files" into a numbered
record of the two contracts a memory model must pin: the **value encoding**
(which every primitive, the compiler, the native backend, and the WASM
target all depend on bit-for-bit) and the **rooting discipline** (the
GC-safety-by-construction invariant that a bug in it corrupts the heap). It
also records the deliberate design positions — precise not conservative,
non-moving, per-object allocation with no free list, no Scheme-level GC
control — and corrects two facts the scattered docs get subtly wrong.

## Motivation

The GC and value model are the foundation every other subsystem stands on,
and two of their properties are contracts that must not drift silently:

- **The value encoding is a cross-subsystem bit-level contract.** The
  NaN-box layout (`types.zig:16`–`32`) is depended on by all 692
  primitives, the compiler, the `.sbc` serializer (KEP-0014), the LLVM
  native backend — whose `llvm_emit_inline.zig` pulls the `nanbox` encoding
  at comptime — and the WASM target, which relies on the 48-bit pointer
  payload fitting a 32-bit `usize` (KEP-0013). A change to a tag constant is
  a change to all of them at once. Nothing in the KEP index records that
  encoding.
- **Rooting is GC-safety-by-construction, and getting it wrong corrupts the
  heap.** Because the collector is *precise* — it never scans the machine
  stack — a Value that lives only in a Zig local is invisible to the GC and
  can be freed mid-use. The whole system is designed around an explicit
  shadow-stack rooting discipline (`pushRoot`/`popRoot`, auto-rooted
  allocator arguments, root-stack truncation on error unwind) that native
  primitives and compiled code must follow. That discipline is the single
  most important invariant in the runtime and deserves a written statement,
  not just a dev-doc and a stress test.
- **The design has settled and is worth dating correctly.** The value model
  is v0.6.0; the generational collector is v0.8.0. Post-0.8.0 GC work is
  overwhelmingly *cross-thread* hardening (KEP-0002 territory), so the
  single-heap design is stable — the right moment to record it before its
  rationale is only reconstructable from a trail of issue numbers.

## Guide-level explanation

A Kaappi value is always exactly 64 bits. Most values need no heap at all:

- A **flonum** is its raw IEEE-754 bits — `3.14` is just a `f64` in the
  word, no allocation.
- A **fixnum** is a signed 48-bit integer (up to ~140 trillion); go past
  that and it silently becomes a heap bignum.
- **`#t`, `#f`, `#\a`, `'()`, `eof`, `(if #f #f)`** and the like are
  *immediates* — small bit patterns, no heap.
- Everything else — pairs, strings, vectors, closures, records, ports,
  bignums — is a pointer to a heap object.

The heap is managed by a garbage collector you never call directly (there is
no `(gc)` procedure). It is **generational**: most collections are quick
"minor" passes over recently allocated objects; occasionally a "full" pass
sweeps everything. It is **precise**, which has one consequence that matters
to anyone writing a C-level primitive or reading the internals: the
collector does **not** look at the C stack, so a value must be *rooted* —
registered with the GC — to survive an allocation. Native code does this
with a `pushRoot(&val); defer popRoot();` pair; the compiler and native
backend emit the same shadow-stack rooting. Forget to root, and the value
can be collected out from under you. To make that hard to get wrong, the
system auto-roots the arguments handed to allocation functions and unwinds
the root stack automatically when an error propagates.

Tuning is out-of-band: an env var (`KAAPPI_GC_THRESHOLD`) and build options
(`-Dgc-threshold`, `-Dgc-stress`) exist, but there is no Scheme API to force
or observe collection.

## Reference-level design

### Value representation (NaN-boxing)

`pub const Value = u64` (`types.zig:13`). Discrimination is by the top 16
bits. Tag constants (`types.zig:16`):

```zig
NANBOX_PTR       = 0xFFFC000000000000
NANBOX_FIX       = 0xFFFD000000000000
NANBOX_IMM       = 0xFFFE000000000000
NANBOX_THRESHOLD = 0xFFFC000000000000
NANBOX_PAYLOAD   = 0x0000FFFFFFFFFFFF   // 48-bit
CANONICAL_NAN    = 0x7FF8000000000000
```

- **Flonum**: `v < NANBOX_THRESHOLD` → raw `f64` bits, no heap. Real NaNs are
  canonicalized to `0x7FF8…` (`types.zig:716`) so they can't collide with
  tag space.
- **Pointer**: `(v >> 48) == 0xFFFC`. `makePointer` is `NANBOX_PTR |
  @intFromPtr(ptr)` — **a pure OR, no masking** (`types.zig:68`); `toObject`
  masks with `NANBOX_PAYLOAD`. This is why the model needs only 48
  addressable bits (see WASM below).
- **Fixnum**: `(v >> 48) == 0xFFFD`, a **signed `i48`** payload
  (`types.zig:43`), magnitude ~2^47; overflow auto-promotes to bignum.
  *(Correction: this is a 48-bit `i48`, not "47-bit"; the ~2^47 figure is
  the signed magnitude. There is no named `MAX_FIXNUM` — the bound is
  `std.math.maxInt(i48)`.)*
- **Immediates**: `(v >> 48) == 0xFFFE`. `NIL|0, FALSE|1, TRUE|2, VOID|3,
  EOF|4, UNDEFINED|5` (`types.zig:27`). Characters are immediates with bit
  `0x80` set: `makeChar = IMM | (codepoint << 8) | 0x80` (`types.zig:92`).

One subtlety worth recording: `makePointer` takes `&x.header` and
`Object.as()` recovers the enclosing struct via `@fieldParentPtr`, so a
header is **not** guaranteed to sit at byte offset 0 of its object
(`types.zig:60`, the #1618 Port regression).

### Heap object layout

Every heap object embeds `header: Object` (`types.zig:213`) as its first
declared field. The header carries:

- `tag: ObjectTag` — an `enum(u6)`, 41 variants (`types.zig:164`), covering
  pair, symbol, string, vector, closure, function, boxed flonum, bignum,
  rational, record/record_type, port, ephemeron, guardian, transport_cell,
  numeric_vector, and the concurrency tags (fiber/channel/mutex/…) that are
  KEP-0002's.
- `flags: Flags` — a `packed struct(u8)`: **`marked`**, **`generation: u1`**
  (young/old color), **`survive_count: u2`** (promotion counter),
  `immutable`, padding (`types.zig:232`). The mark bit and generation live
  here.
- `owner: u32` — the id of the owning GC. *(Structurally in scope; its
  cross-heap semantics are KEP-0002.)*
- `next: ?*Object` — an intrusive singly-linked allocation list.
- `_align` — forces 8-byte alignment so `v & 7 == 0`, required because
  wasm32 allocators may return 4-byte-aligned pointers (`types.zig:227`).

### Collector algorithm

A **precise, non-moving, stop-the-world generational mark-and-sweep**
(`docs/dev/gc-safety-and-error-handling.md:15`: "generational (young and old
generations, minor and full collections) with mark-and-sweep at its core").

`collect` (`gc_collect.zig:39`) increments a minor-cycle counter and runs a
**full collection every 8th cycle, a minor collection otherwise**
(`:44`); afterward it resets the threshold to
`@max(GC_THRESHOLD, object_count * 4)` (`:53`) — the heap-growth policy.

- **Minor** (`minorCollect`, `:56`) scans the remembered set (old→young
  edges) plus the roots and marks young objects only.
- **Full** (`fullCollect`, `:321`) clears old marks, marks from roots, clears
  the remembered set, and sweeps both generations.
- Reachability is a **simple mark bit**, not tri-color; `generation`
  distinguishes young/old and `survive_count` drives promotion (young
  objects surviving 2 minor cycles are promoted).
- The **write barrier** `GC.writeBarrier(container, new_val)`
  (`memory.zig:338`) records old→young edges into the remembered set, and
  must run after every `set-car!` / `vector-set!` / record mutation.

**Roots** (`markRoots`, `gc_collect.zig:654`): auto-rooted allocator
arguments (`arg_roots`); the slice being built for a vector/closure
(`slice_roots`); the **push/pop shadow stack** (`root_buffer`); an
`extra_roots` dynamic list; FFI callback closures
(`ffi_cb.markCallbackRoots`); interned symbols (under `symbol_mutex`); and a
`root_marker` hook into the VM's registers, call frames, handler stack, and
wind stack. The collector **does not scan the C/machine stack** — this is
precise, not conservative rooting (`gc-safety…md:31`: "the Zig stack, which
GC does not scan"). `markValue` uses an explicit worklist to avoid native
stack overflow on deep structures (#864).

**Sweep** (`gc_sweep.zig`) walks the intrusive object list, frees unmarked
objects through a per-tag `freeObject`, and updates
`objects_freed`/`bytes_freed` stats.

### Allocation

`gc_alloc.zig` does **no free list, no bump pointer, and no size classes** —
each object is an individual `allocator.create(T)` (`allocPair`,
`gc_alloc.zig:58`; `allocString`, `:152`; `allocVector`, `:237`), threaded
onto the intrusive `next` list by `trackObject` (`memory.zig:356`). Each
allocator calls `maybeCollect` **before** creating the object
(`memory.zig:473`): it collects when `enabled and (stress or object_count >=
gc_threshold)`, and separately enforces an absolute `memory_limit`
watermark (the `--max-memory` budget) by returning `error.OutOfMemory`. A
`no_collect` counter lets the compiler pin unrooted transients across a
region. The inline fixnum-arithmetic fast path skips allocation and rooting
entirely (#1493).

### Rooting discipline (GC-safety by construction)

The precise collector's correctness rests on an explicit root set:

- **Shadow stack**: `root_buffer: []*Value` + `root_count`
  (`memory.zig:181`), growable from 1024 to 65536 (#1298). `pushRoot(&val)`
  / `popRoot()` (`memory.zig:511`); `truncateRoots(depth)` snapshots and
  restores `root_count` on error unwind at pipeline boundaries
  (`compileExpression`, `vm_eval.eval`, `vm_calls.execute` — the #1855
  mechanism).
- **Auto-rooting**: `rootArgs`/`arg_roots` protect the Value arguments
  handed to an allocator; `slice_roots` protects a caller slice during
  vector/closure construction. This is what makes the common case safe
  without manual rooting.
- **Native primitives** follow the canonical `pushRoot(&val); defer
  popRoot();` pattern (reference impls: `reverse` in `primitives.zig`,
  `readVector` in `reader_datum.zig`).
- **Compiled code** (LLVM native backend, KEP-0010) uses the same shadow
  stack via C-ABI exports `kaappi_gc_push_root(slot)` and
  `kaappi_gc_pop_roots(n)` (`runtime_exports.zig:490`).

### Weak references and finalization

- **Ports** are the closest thing to a finalizer: `freeObject` closes the fd
  on sweep if still open (`fd > 2`, not a string port) with a best-effort
  buffered-output flush. Programs are still expected to `close-port`
  explicitly rather than rely on GC.
- **Weak references (SRFI-254)**: `ephemeron` (tag 37) and `guardian`
  (tag 38) get special GC treatment. `processWeakRefs`
  (`gc_collect.zig:332`) runs after the strong mark and before sweep, to a
  fixpoint: an ephemeron retains its value only once its key is proven
  reachable; a guardian resurrects registered elements whose watched object
  died, moving them to a ready queue for `(g)` retrieval. `transport_cell`
  (tag 39) is an ordinary strong pair on this non-moving collector.

### 32-bit / WASM

The NaN-box model holds on wasm32 (`usize = u32`): user pointers fit in the
48-bit payload and `makePointer` does no masking
(`porting.md:293`), and the `_align` field forces the 8-byte alignment
wasm32 allocators don't guarantee. Flonums and fixnums are `u64` words
regardless of architecture. See KEP-0013; no re-spec here.

### Tuning and introspection

There is **no Scheme-level GC procedure** — `(gc)`, `(collect-garbage)`,
`(gc-stats)` do not exist. Control is out-of-band: the env var
`KAAPPI_GC_THRESHOLD` (read in `runtime_exports.zig:22`); build options
`-Dgc-threshold` (default 8192 objects) and `-Dgc-stress` (collect on every
allocation); the internal `GC.enabled` flag, `no_collect` counter, and
`memory_limit`/`--max-memory` cap; and `GcStats` (peak object/byte counts,
freed counts) surfaced through `kaappi features` and `--profile` JSON.

### Multi-heap boundary (deferred to KEP-0002)

Where the collector touches concurrency, this KEP only cites the boundary:
each child thread gets its own VM and GC with an independent heap; marking
**skips objects owned by another GC** (`Object.owner` vs `GC.id`, #958),
which is exactly what keeps the mark phase heap-local; cross-thread
collection uses a `CollectionState` (`running`/`parked`/`stopped`/
`in_native`) with safepoints, and values crossing a thread or channel are
**deep-copied** into the receiver's heap (`gc_deep_copy.zig`), refusing 14
uncopyable tags. All of that — the deep copy, the owner-skipping marks, the
stop-the-world-across-threads coordination — is owned by KEP-0002.

### Tests

Zig units: `tests_gc_tracing.zig` (per-`ObjectTag` reachability under forced
collection), `tests_gc_root_boundary.zig` (root-stack unwinding, #1855),
`tests_gc_runtime_stress.zig` (values held where the collector can't see
them, #2160/#2161). Scheme stress suites under `tests/scheme/smoke/`
(`gc-rooting-stress.scm`, `gc-rooting-safety.scm`,
`gc-mark-contents-types.scm`, `gc-numeric-rooting.scm`,
`gc-root-growth.scm`) and `coverage/gc-stress-coverage.scm`, run with
`-Dgc-threshold=1` / `-Dgc-stress=true`.

## Drawbacks

The GC evolves, and much recent GC code is cross-thread — so an as-built KEP
risks either drifting or straying into KEP-0002's territory. Mitigation:
this KEP records the *per-heap* contracts (the value encoding, the
generational algorithm shape, the rooting discipline, weak-ref handling)
that are stable and heap-local, and explicitly cites-and-defers every
multi-heap fact rather than specifying it.

Pinning the value encoding in a numbered document could imply it is a public
ABI. It is not — it is an internal representation shared only among
same-version components (the `.sbc` `compilerHash` in KEP-0014 exists
precisely so cross-version blobs are rejected). The Unresolved questions ask
whether any of it should ever be stabilized; the record's job is to state
the current, deliberately-private contract clearly.

## Alternatives considered

- **Leave it to `gc-safety-and-error-handling.md`.** That doc is good on
  rooting and the write barrier but is scoped to *safety rules*, not the
  value encoding or the allocator/collector design, and there is no
  `values.md`/`memory.md` at all. A KEP consolidates the whole per-heap
  model and gives the encoding a citable home.
- **One big "memory & concurrency" KEP** merging this with KEP-0002.
  Rejected: KEP-0002 already owns cross-thread channels, scheduling, and the
  multi-heap coordination, and it is a *design* proposal with its own
  history. Merging would either duplicate it or bloat this as-built record.
  The clean seam is per-heap (here) vs. multi-heap (there).
- **Split value model and collector into two KEPs.** Rejected: the encoding
  and the collector are inseparable — the mark bit, generation, and owner
  live in the object header the pointer tag points at, and the precise
  collector's correctness is stated in terms of Values. One KEP keeps the
  invariant visible.
- **Wait for a moving/compacting collector before documenting.** Rejected:
  the non-moving, precise design is exactly the stable thing to record, and
  a future moving collector would be a *proposal* KEP that supersedes this
  as-built baseline — which is easier to write against a written baseline.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- The NaN-box value encoding is identical on 64-bit and 32-bit (wasm32)
  targets; the 8-byte-alignment guarantee is enforced by the object header.
- The value encoding is an internal, same-version representation shared by
  the primitives, compiler, `.sbc` serializer (KEP-0014), native backend
  (KEP-0010), and WASM target (KEP-0013) — not a stable public ABI.
- The collector is precise and non-moving on every platform; it never scans
  the C stack, so all platforms share the same rooting requirement.
- GC tuning is out-of-band (env var + build options) and identical across
  platforms; there is no Scheme-level GC surface.
- The per-heap collector described here is what each thread runs;
  multi-heap coordination (KEP-0002) layers on top without changing the
  per-heap contracts.

## Unresolved questions

1. **Should any part of the value encoding be a stabilized contract?** The
   `.sbc` `compilerHash` (KEP-0014) currently assumes it can change freely
   between builds. Is that the permanent stance, or should the encoding gain
   a documented stability guarantee?
2. **Is a Scheme-level GC surface wanted** — `(collect-garbage)`,
   `(gc-statistics)`, a heap-size query — or is the deliberate absence of
   one a feature to state as a guarantee?
3. **Non-moving is load-bearing** (raw pointers escape via FFI as integers,
   KEP-0011; `transport_cell` is a plain strong pair). Should "non-moving"
   be recorded as a contract other subsystems may rely on, or left as an
   implementation choice a future compacting collector could revisit?
4. **Generational tuning** (full every 8th cycle, promote after 2 minor
   survivals, threshold `× 4` growth): are these constants worth exposing or
   documenting as tunables, or intentionally fixed?
5. **Finalization beyond ports**: should the guardian/ephemeron machinery be
   the documented answer for resource cleanup, and should the KEP state that
   GC-driven fd-closing is a safety net, not a contract?
6. **The header-not-at-offset-0 invariant** (`@fieldParentPtr`, #1618): is
   this a permanent property new object types must respect, and should it be
   a checked invariant?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Write the missing dev-docs** (`values.md`, `memory.md`) — or a single
   consolidated one — seeded from this KEP's reference section, and link
   them here; `gc-safety-and-error-handling.md` continues to own the
   day-to-day rooting rules.
3. **Correct the record** where prior descriptions said "47-bit fixnum" or
   implied a single generation: it is a 48-bit `i48` payload and a
   two-generation collector.
4. **State the value encoding's stability stance** (Unresolved 1) alongside
   KEP-0014's `compilerHash`, so the "internal, same-version only" contract
   is explicit in both places.
5. **Cross-link KEP-0002** from `gc_collect.zig`/`memory.zig` and this KEP so
   the per-heap vs multi-heap boundary is discoverable from code.
6. **On acceptance**, triage the GC-surface, non-moving-contract, and
   tuning questions (Unresolved 2–6) into tracked issues so future
   memory-model work amends this KEP rather than the scattered docs.
