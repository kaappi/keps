# KEP-0005: The Diagnostic Contract

| Field | Value |
|-------|-------|
| **KEP** | 0005 |
| **Title** | The Diagnostic Contract |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (reader, compiler, VM, primitives), `kaappi.github.io` (new diagnostics reference page) |
| **Created** | 2026-07-13 |
| **Requires** | KEP-0004 (Accepted) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit
[`ce6656c7`](https://github.com/kaappi/kaappi/commit/ce6656c7) (main, 2026-07-13,
KEP-0002 Phase 4) and were verified against that source, including by building
`zig-out/bin/kaappi` at that commit and running the repro snippets in the
Motivation directly. Doc-site references are pinned against the
`kaappi.github.io` `main` branch as of the same date. This KEP is the design
record for the "machine legibility" campaign tracked in
[kaappi#1503](https://github.com/kaappi/kaappi/issues/1503); the phase headings
below name the specific implementation issues.*

## Summary

Kaappi's error messages are already good for a human reading a terminal: an
undefined-variable error reads `err.scm:2: error: undefined variable
'countr'. Did you mean 'count'?`, with a source snippet, a stage label
(`read error` / `compile error` / runtime `error`), and a
non-zero exit code. But a *message string is the only identity a diagnostic
has*. There is no stable identifier a tool — an AI agent, a CI gate, an editor
— can match on without scraping prose that is free to be reworded, and some
paths still leak internal Zig error names to the user
(`<stdin>:1:12: read error: error.UnexpectedChar`).

This KEP defines a **diagnostic contract**: a single registry that gives every
user-facing diagnostic a stable `KP`-prefixed code, a message template, and a
prose explanation, plus the surfaces that expose it — coded text output,
`--diagnostics=json`, `kaappi explain <code>`, and one Scheme-visible,
compatibility-affecting addition: an `error-object-code` accessor and a
`kaappi-diagnostics` `cond-expand` identifier, following the exact discipline
KEP-0004 set for discoverable deviations.

The bulk of this work (CLI output, JSON, `explain`) is tooling *around* the
language — territory R7RS-small is silent on, and which by
[KEP-0004](0004-discoverable-deviations.md)'s framing needs no KEP on its own.
This document exists because (a) the **stability commitment** — a shipped code
is never renumbered or reused — is a cross-cutting promise worth recording
before the first code ships, and (b) `error-object-code` is a genuine
Scheme-surface addition that affects compatibility, which the
[KEP process](../README.md#when-a-kep-is-needed) requires a KEP for.

## Motivation

### The status quo, verified

Built at `ce6656c7` and run directly:

```scheme
; a genuinely unbound reference (not a shadowed builtin)
(define counter 10)
(display countr)
; => err.scm:2: error: undefined variable 'countr'. Did you mean 'count'?
;    (display countr)
```

```
$ echo '(car 5)' | kaappi
error: type error in 'car': expected pair, got 5

$ echo '((lambda (x) x) 1 2)' | kaappi
error: expected 1 arguments, got 2

$ echo '(define x #\bogus)' | kaappi
<stdin>:1:12: read error: error.UnexpectedChar
```

Three things stand out. The did-you-mean machinery
([`vm.zig:466` `findSimilarName`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/vm.zig#L466),
a bounded Levenshtein search over the globals table) is already better than
most Schemes ship. The reader carries a real `line:col`
([`reader.zig:80` `getLineCol`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/reader.zig#L80),
consumed throughout `main.zig`). And yet the last example prints
`error.UnexpectedChar` — a raw Zig error-enum tag
([`errors.zig`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/errors.zig)
defines the 15-variant `KaappiError`) — straight to the user. There is no
identifier on any of these an agent can key on except the English text, and
the text is the part we most want to be free to improve.

### What an agent actually needs

The operational test for the whole legibility campaign
([kaappi#1503](https://github.com/kaappi/kaappi/issues/1503)) is: *an agent can
go from a failing program to a correct, verified fix using only documented CLI
output* — no screen-scraping, no reading compiler source, no guessing. A
diagnostic fails that test today on three counts:

1. **No stable handle.** "Did the build fail for the reason I just fixed, or a
   new one?" is answerable only by substring-matching prose that may change
   between releases.
2. **No structure.** The suggestion (`Did you mean 'count'?`) is *rendered into
   the sentence* rather than emitted as data an agent can apply mechanically —
   even though the fix is already computed.
3. **No explanation channel.** "What does this diagnostic mean in general?"
   requires leaving the toolchain for a web search, which for a version-specific
   compiler is a correctness hazard, not just friction.

### Why the existing `error_type` enum is the seed, not the solution

The built-in error object already carries a coarse discriminant.
[`types.zig:396`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/types.zig#L396):

```zig
pub const ErrorObject = struct {
    pub const ErrorType = enum(u8) {
        general, file, read, join_timeout, abandoned_mutex,
        terminated_thread, uncaught_exception, channel_timeout,
    };
    header: Object,
    message: Value,     // string
    irritants: Value,   // list
    error_type: ErrorType = .general,
    uncaught_reason: Value = VOID,
};
```

This 8-value enum is exactly how `read-error?` and `file-error?` are
implemented today
([`primitives_control.zig:159,165`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/primitives_control.zig#L159)),
and it proves the point that an error object can carry a stable discriminant
at near-zero cost — it already does. What it is *not* is fine-grained (eight
buckets for the whole runtime), stable-by-contract (it is an internal enum, free
to be reordered), or exposed (no accessor returns it as a value). The diagnostic
registry is the disciplined generalization of this field: the existing
predicates get re-expressed over it, and it gains a Scheme-visible accessor.

### Two error worlds, and which one carries the code

Kaappi ships **both** R7RS error objects (the built-in `ErrorObject` above) and
the SRFI-35/36 condition system as portable libraries
([`lib/srfi/35.sld`](https://github.com/kaappi/kaappi/blob/ce6656c7/lib/srfi/35.sld),
[`36.sld`](https://github.com/kaappi/kaappi/blob/ce6656c7/lib/srfi/36.sld) —
`make-condition`, `condition?`, `&error`, `condition-ref`, …). SRFI-35 is
already Scheme's answer to "a catchable, dispatchable error taxonomy," and it is
the correct prior art for the *catchable* half of this proposal. The code
attaches to the built-in `ErrorObject`, which is what the implementation itself
raises and what `guard` sees for a built-in error; §"Reference-level design"
specifies how the two relate.

## Guide-level explanation

**Coded text output.** The default human output gains a bracketed code:

```
err.scm:2:10: error[KP3001]: undefined variable 'countr'. Did you mean 'count'?
    (display countr)
             ^~~~~~
```

The code is the stable part; the message after it is free to improve release
to release.

**Structured output.** Agents and tools ask for JSON and get one object per
diagnostic (JSON Lines on stderr), in the **LSP `Diagnostic` shape the language
server already emits** — no new schema to learn:

```
$ kaappi --diagnostics=json err.scm
{"range":{"start":{"line":1,"character":9},"end":{"line":1,"character":15}},
 "severity":1,"code":"KP3001","source":"kaappi",
 "message":"undefined variable 'countr'",
 "data":{"suggestions":[{"kind":"rename","replacement":"count"}]}}
```

**Self-explaining compiler.** Every code has an entry the binary carries with
it, à la `rustc --explain`:

```
$ kaappi explain KP3001
KP3001: undefined variable

A variable was referenced that has no binding in scope...
  (display countr)   ; countr is not defined

Common fixes:
  - Check for a typo (kaappi suggests the nearest defined name).
  - Ensure the defining form runs before the reference...
```

**Scheme-visible dispatch.** A program — a test harness, an agent-driven REPL,
an error-handling library — can dispatch on the code without touching any R7RS
accessor's behavior:

```scheme
(import (scheme base) (kaappi diagnostics))

(guard (e ((eq? (error-object-code e) 'KP3001)
           (offer-rename-fix e))
          (else (raise e)))
  (load-user-program))
```

And it can guard the whole capability behind a feature test, KEP-0004 style:

```scheme
(cond-expand
  (kaappi-diagnostics
    (define (code-of e) (error-object-code e)))
  (else
    (define (code-of e) #f)))   ; older/minimal build: no codes
```

## Reference-level design

### 1. The code taxonomy

`KP` + four digits, ranged by pipeline stage so the leading digit alone tells
an agent *where* a diagnostic came from:

| Range | Stage | Source of truth |
|-------|-------|-----------------|
| `KP1xxx` | Read / lexical | `reader.zig`, `reader_tokens.zig`, `reader_datum.zig` |
| `KP2xxx` | Expand / compile | `expander.zig`, `compiler*.zig`, `ir.zig` |
| `KP3xxx` | Runtime | `vm*.zig`, `primitives*.zig` |
| `KP4xxx` | Static analysis / lint | `kaappi check` ([kaappi#1511](https://github.com/kaappi/kaappi/issues/1511)) — reserved |
| `KP9xxx` | Internal compiler error | the panic/ICE path ([kaappi#1514](https://github.com/kaappi/kaappi/issues/1514)) |

The ranges are deliberately sparse; four digits give 1000 codes per stage
against a current inventory of a few dozen distinguishable diagnostics.
Granularity target: **one code per user-distinguishable condition**, which is
finer than the 15-variant `KaappiError` enum (an implementation detail that maps
*many-to-one* onto codes — e.g. `TypeError` fans out into per-primitive,
per-expected-type codes) and finer than the 8-variant `ErrorObject.ErrorType`.

### 2. The registry

One comptime table (`src/diagnostics.zig`, new) is the single source of truth.
Each entry binds together the three things that today live apart — the code, the
message template scattered across `setErrorDetail` call sites, and the
explanation that currently exists nowhere:

```zig
pub const Diagnostic = struct {
    code: Code,                  // enum(u16), stable ordinal ↔ "KP3001"
    name: []const u8,            // "undefined-variable"
    template: []const u8,        // "undefined variable '{s}'"
    explanation: []const u8,     // prose for `kaappi explain`
    default_severity: Severity,  // error | warning
};
```

The registry supersedes the ad-hoc formatting at raise sites. Instead of
[`vm_dispatch.zig:1363`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/vm_dispatch.zig#L1363)'s
`setErrorDetail("undefined variable '{s}'. Did you mean '{s}'?", …)`, a raise
site names a code and supplies arguments; the message is rendered from the
registry template, and the code rides along. `error_type`'s existing predicates
(`read-error?`, `file-error?`) are re-expressed as "code is in the KP1xxx read
set" / "code is the file-error code," so the two never disagree.

### 3. Structured output — reuse, do not invent

`--diagnostics=json` emits the LSP
[`Diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic)
structure (`range`, `severity`, `code`, `source`, `message`,
`relatedInformation`), one JSON object per line on stderr. This is not a new
schema: the language server already serializes exactly this shape for
`textDocument/publishDiagnostics`
([`kaappi_lsp.zig:666`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/kaappi_lsp.zig#L666)).
The CLI path shares that serializer, so the two cannot drift. Fix suggestions
(the already-computed did-you-mean) map to `data.suggestions` with
`kind`/`replacement`, mirroring LSP code-action semantics. `relatedInformation`
carries secondary locations (Rust-borrow-checker style) once spans support it.

Positions are best-effort and widen as span tracking
([kaappi#1506](https://github.com/kaappi/kaappi/issues/1506)) lands: reader
diagnostics already have `line:col`; runtime diagnostics have a line today
(`vm.zig`'s `captureErrorLocation` walks frames via
[`func.line_table`/`lineForOffset`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/vm.zig#L502))
and gain a column when the instruction span table does. JSON must ship *before*
full spans — it emits what is known and the ranges tighten later.

### 4. `error-object-code` — the Scheme-visible surface

The one part of this KEP that touches the language surface, and the reason it is
a `Standards`-type KEP.

- **Signature.** `(error-object-code obj)` returns an **interned symbol** (e.g.
  `KP3001`) for an error object the implementation raised with a code; `#f`
  otherwise. `eq?` on the returned symbol is the intended dispatch primitive
  (fast, and reads naturally in a `guard`).
- **`#f` cases, explicitly.** A user error from `(error msg irritant …)` →
  `#f`. A raised non-error object — R7RS `raise` accepts *any* value
  ([`primitives_control.zig:40`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/primitives_control.zig#L40))
  — → `#f` (it is not even an error object). Only implementation-originated
  diagnostics carry a `KP` code. The `KP` namespace is **reserved to the
  implementation**; whether user code may attach its own codes is Unresolved
  question 2.
- **R7RS surface untouched.** `error-object?`, `error-object-message`,
  `error-object-irritants` keep their exact behavior. `error-object-code` is
  additive metadata; a program that never calls it sees no change.
- **Representation.** `ErrorObject` gains a `code` field alongside the existing
  `error_type` — the same enum-ordinal trick, already proven on that struct.
  Default is an "uncoded" sentinel so every existing raise site stays valid
  during the migration. `allocErrorObject`
  ([`memory.zig:430`](https://github.com/kaappi/kaappi/blob/ce6656c7/src/memory.zig#L430))
  — the single construction site — gains a coded variant; the accessor
  materializes the interned symbol from the ordinal on demand.
- **Home library.** A new `(kaappi diagnostics)` library, **never** an extension
  of `(scheme base)`'s exports (that would be a real deviation — a non-standard
  binding in a standard library's namespace). Final name is Unresolved
  question 4.
- **Feature identifier.** `kaappi-diagnostics` is added to
  `types.platform_features` following KEP-0004 §1's mechanism exactly, true when
  the registry and accessor are compiled in.

### 5. Stability policy — the actual contract

This is the load-bearing commitment, and the reason a registry beats scattered
strings:

1. Once a code appears in a **released** version, it is **never renumbered and
   never reused** for a different meaning. A diagnostic that is removed leaves
   its code **permanently reserved** (a tombstone entry).
2. A code's **message text and explanation may be reworded freely** — that is
   the whole point of separating the stable code from the mutable prose.
3. A code's **severity may tighten or relax** across a major version (an error
   demoted to a warning, say) but the code persists.
4. **Pre-1.0 latitude.** Until Kaappi reaches a stability milestone, codes are
   *intended* stable but the registry may be renumbered in bulk *once*, loudly,
   if the initial taxonomy proves wrong — after which rule 1 is absolute. This
   mirrors the "living document until Final" posture the KEP process itself
   takes.

A CI gate asserts registry integrity: every registered code has a non-empty
explanation ([kaappi#1507](https://github.com/kaappi/kaappi/issues/1507)), no
two entries share a code, and no released code has vanished without a tombstone.

## Drawbacks

- **A long migration with a long tail.** Every raise site must eventually name a
  code. Until then a catch-all (`KP9000`, "uncategorized") is unavoidable, and
  there is a real risk of a persistent tail of uncoded errors that never get
  their own entry. Mitigation: phase by traffic (the handful of diagnostics real
  programs actually hit first — undefined variable, type error, arity), and let
  the completeness gate ratchet coverage rather than demand it all at once.
- **A forever commitment made early.** A mis-scoped or mis-numbered code is
  permanent debt. Mitigation: codes are cheap and the ranges are sparse — reserve
  generously, and use the one-time pre-1.0 bulk-renumber escape hatch if the
  taxonomy is genuinely wrong.
- **A second source of truth, in principle.** A registry separate from the raise
  sites could drift from them. Mitigation: it is engineered to be the *single*
  source — the message template moves *into* the registry, so a raise site that
  wants a message must reference a code; there is no second copy to drift.
- **`error-object-code` returning `#f` for user errors is a sharp edge.** A user
  who writes `(error "bad")` and expects `error-object-code` to give them
  something back gets `#f`. This is deliberate (the `KP` space is the
  implementation's) but will surprise someone; Unresolved question 2 asks
  whether user-attachable codes are worth it.

## Alternatives considered

- **Text diagnostics only, no codes.** The status quo. Rejected: it fails the
  operational test — an agent cannot get a stable handle or a structured
  suggestion, and Elm's famously friendly-but-uncoded errors are the cautionary
  example of stopping here (great for humans, opaque to tools).
- **Expose the internal `KaappiError` enum as the codes.** Rejected: those 15
  variants are an implementation detail (they include control-flow signals like
  `Yielded` and `ContinuationInvoked` that are not diagnostics at all), they are
  too coarse (one `TypeError` for every type error in the system), and freezing
  them as a public contract would ossify the internals. The registry is
  deliberately a separate, curated namespace.
- **Invent a Kaappi-native diagnostic JSON schema.** Rejected: the LSP
  `Diagnostic` shape already exists, agents and editors already parse it, and —
  decisively — the language server *already serializes it in this codebase*. A
  bespoke schema would be a second serializer to write and keep in sync for no
  benefit. (SARIF was considered as the CI-oriented alternative and is noted as
  a possible *additional* output in Unresolved question 5, not a replacement.)
- **Put `error-object-code` in `(scheme base)`.** Rejected outright: adding a
  non-standard binding to a standard library's namespace is exactly the kind of
  deviation KEP-0004 and the vision doc's "R7RS-small is the contract" rule
  forbid. It lives in a `(kaappi …)` library.
- **Reuse the SRFI-35 condition hierarchy instead of a code on the error
  object.** Considered seriously, since SRFI-35 is already the Scheme-native
  dispatchable taxonomy. Rejected as the *primary* surface because the codes must
  serve the CLI and JSON paths too (where there is no condition object, only a
  compiler diagnostic), so the registry has to exist independently of SRFI-35
  regardless; wiring codes *also* onto compound conditions is left as Unresolved
  question 6 rather than made load-bearing.

## Cross-platform / compatibility impact

- **WASM/WASI.** The registry is comptime data and ships on every target;
  `error-object-code`, `--diagnostics=json`, and `explain` all work on the wasm
  build. No platform carve-out.
- **Sandbox mode.** No interaction — diagnostics are orthogonal to the
  `--sandbox` capability set.
- **Backward compatibility.** Purely additive. `error-object?` /
  `-message` / `-irritants` are unchanged; the new `ErrorObject.code` field
  defaults to "uncoded" so every existing raise site and every existing program
  keeps working. The full R7RS conformance suite must pass untouched — a
  guardrail, not an aspiration.
- **`.sbc` cache.** Codes are a runtime concern and are *not* serialized into
  bytecode, so the registry adds no cache-format change. (Span tracking,
  [kaappi#1506](https://github.com/kaappi/kaappi/issues/1506), does bump the
  `.sbc` format — that is its concern, not this KEP's.)
- **LSP.** Codes flow into the language server's existing diagnostics for free,
  so editors get `KP` codes and (via `explain`) hover documentation with no
  additional protocol work.

## Prior art

Session research, 2026-07-13. Two distinct traditions matter here, and this KEP
deliberately joins them:

**Stable printed-code registries** (the CLI/agent surface):

| System | Codes | `explain` equivalent | Structured output |
|--------|-------|----------------------|-------------------|
| **Rust** | `E0308`, stable, documented | `rustc --explain E0308` | `--error-format=json` |
| **TypeScript** | `TS2345`, stable numeric | — (codes are documented externally) | structured diagnostics API |
| **C# / Roslyn** | `CS0103`, stable | docs per code | MSBuild structured logs |
| **Clang/GCC** | warnings named (`-Wunused`), errors not uniformly coded | — | `-fdiagnostics-format=json` |

Rust is the model: a stable code, a first-party `--explain`, and a JSON format,
all keyed on the same identifier. This KEP is, in one sentence, "bring Rust's
diagnostic-code discipline to Scheme."

**Condition-type hierarchies** (the catchable Scheme surface): R6RS conditions
(Chez, Racket's `exn` hierarchy), SRFI-35/36 (which Kaappi already ships),
Gauche's `<error>` subtypes. These give a program a dispatchable *taxonomy of
error values* — the tradition `error-object-code` slots into.

The gap this KEP fills: **no Scheme surveyed pairs a stable, documented,
`explain`-able printed-code registry with the language.** Schemes have rich
catchable condition hierarchies; they do not have `rustc --explain`. Kaappi can
have both, and — because it already ships SRFI-35/36 and an LSP that serializes
LSP-shaped diagnostics — it is unusually well positioned to, with most of the
raw material already in the tree.

## Unresolved questions

1. **Symbol vs. dedicated type for the code in Scheme.** `error-object-code`
   returns a symbol (`'KP3001`), dispatched with `eq?`. Is that the right
   primitive, or should there also be an `error-object-code=?` /
   range-predicate helper (e.g. "any read error") so programs aren't hardcoding
   individual numbers? Leaning toward shipping the symbol plus a small set of
   range predicates that mirror the existing `read-error?`/`file-error?`.
2. **User-attachable codes.** May a program tag its own `(error …)` with a code,
   and if so in what namespace (certainly not `KP`)? Deferred; `#f` for all user
   errors is the conservative v1.
3. **Granularity, concretely.** "One code per user-distinguishable condition" is
   the principle, but the first pass must draw actual lines — is `(car 5)` vs.
   `(car "x")` one type-error code or two? Proposed: one code per
   (primitive-agnostic) *expected-type violation*, with the offending value in
   the message, not the code. To be settled during Phase 1.
4. **Library name.** `(kaappi diagnostics)` vs. folding the accessor into an
   existing `(kaappi …)` library. Genuinely open.
5. **SARIF as an additional CI format.** `--diagnostics=json` is LSP-shaped for
   editor/agent parity; CI security/quality tooling often speaks
   [SARIF](https://sariftool.github.io/) instead. Worth a second
   `--diagnostics=sarif` emitter, or is LSP-shaped JSON enough until demand
   appears? (Same "wait for real demand" posture as KEP-0004's runtime-variance
   predicates.)
6. **Codes on compound conditions.** Should a SRFI-35 compound condition carry a
   code too, or only the built-in `ErrorObject`? Kept out of the load-bearing
   path deliberately; revisit if programs want to dispatch on codes through the
   SRFI-35 surface.
7. **`KP9xxx` and `error-object-code`.** Internal compiler errors get codes for
   the crash-report path ([kaappi#1514](https://github.com/kaappi/kaappi/issues/1514)),
   but should `error-object-code` ever return one — i.e. should a program be able
   to `guard` on "the compiler hit a bug"? Leaning no (ICEs abort; encouraging
   programs to depend on them is wrong), but the code still exists for the report.

## Implementation plan

Phased to match the campaign issues under
[kaappi#1503](https://github.com/kaappi/kaappi/issues/1503). The registry is the
keystone; everything else hangs off it.

**Phase 0 — This KEP → Accepted.** Settle the taxonomy ranges, the stability
policy, and the `error-object-code` surface (Unresolved questions 1–4 in
particular) on the PR before implementation begins.

**Phase 1 — Registry + coded text output.**
[kaappi#1504](https://github.com/kaappi/kaappi/issues/1504). Introduce
`src/diagnostics.zig` with the initial code set (the high-traffic diagnostics
first), route the highest-traffic raise sites through it, and add `error[KPxxxx]`
to text output. Retire `error.UnexpectedChar`-style leaks. This is the
foundation; nothing else starts until the registry exists.

**Phase 2 — Structured output + spans (parallel).**
`--diagnostics=json` ([kaappi#1505](https://github.com/kaappi/kaappi/issues/1505),
reusing the LSP serializer) can proceed as soon as Phase 1 lands, emitting the
positions known today. Full source spans
([kaappi#1506](https://github.com/kaappi/kaappi/issues/1506)) is the deepest,
longest change (reader → IR → bytecode debug info, `.sbc` bump) and runs in
parallel; JSON ranges tighten as it lands.

**Phase 3 — `kaappi explain` + completeness gate.**
[kaappi#1507](https://github.com/kaappi/kaappi/issues/1507). Explanations live in
the registry; the gate that fails CI when any code lacks one is what keeps the
contract honest as codes accrue.

**Phase 4 — The Scheme-visible surface.**
[kaappi#1508](https://github.com/kaappi/kaappi/issues/1508). `error-object-code`,
the `(kaappi diagnostics)` library, and the `kaappi-diagnostics` `cond-expand`
identifier (KEP-0004 §1 mechanism). Gated behind the R7RS-suite conformance
guard. This is the phase this KEP most exists to authorize.

**Phase 5 — Lint codes.**
[kaappi#1511](https://github.com/kaappi/kaappi/issues/1511). `kaappi check`
claims the reserved `KP4xxx` range under the same registry and stability policy.

**Docs — diagnostics reference page.** A page on kaappi-lang.org generated *from
the registry* (so it cannot drift from what the binary emits), linked next to
the KEP-0004 `conformance.md` page. The same generator backs
`kaappi explain --all`.
