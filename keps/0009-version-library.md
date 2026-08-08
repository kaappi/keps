# KEP-0009: A `(kaappi version)` Library for SemVer 2.0.0

| Field | Value |
|-------|-------|
| **KEP** | 0009 |
| **Title** | A `(kaappi version)` Library for SemVer 2.0.0 |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Standards |
| **Target** | `kaappi` core (`lib/kaappi/version.sld`, `src/thottam_semver.zig`, `kaappi.github.io`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against that source as of
2026-08-08.*

## Summary

Kaappi says it follows [Semantic Versioning 2.0.0](https://semver.org/), but
it has no first-class notion of a version. The only version logic in the tree
is `src/thottam_semver.zig`, a private helper inside the package manager that
parses `major.minor.patch` and **silently discards** anything after the patch
number — the very prerelease and build-metadata fields that make a string a
SemVer 2.0.0 version rather than a bare `x.y.z` triple. Nothing at the Scheme
level can parse, compare, or requirement-match a version at all.

This KEP proposes `(kaappi version)`: a small, pure-Scheme library that
parses a version string into a record, compares two versions with SemVer's
precedence rules (including prerelease ordering and build-metadata exclusion),
and tests a version against a requirement expression (`^`, `~`, `>=`, ranges).
It also proposes bringing `thottam_semver.zig` up to the full grammar so the
package manager and the library agree on what a version *is*, in the spirit of
the shared-contract discipline of [KEP-0008](0008-shared-ir-contract.md).

## Motivation

### The current parser is not a SemVer parser

`Semver.parse` in `src/thottam_semver.zig:8` splits on `.`, reads three
integers, and stops:

```zig
pub fn parse(s: []const u8) ?Semver {
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
    const patch = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}
```

The struct itself has only `major`, `minor`, `patch` fields
(`src/thottam_semver.zig:3`). Feed it `1.2.3-rc.1+build.5` and the `parseInt`
of `"3-rc"` fails, so the whole version is rejected as unparseable — a valid
SemVer 2.0.0 string that kaappi cannot represent. Feed it `1.2` and it
silently fills in `patch = 0`. There is no prerelease field, so there is no
way to express that `1.0.0-alpha` precedes `1.0.0`, which is the single most
important rule in the spec (§11.3–11.4).

This is fine *today* only because no published `kaappi.pkg` uses a prerelease
tag. It is a latent trap: the first library that tags `0.3.0-rc.1` will find
that `thottam install foo@^0.2` and version resolution behave in undefined
ways, with no diagnostic pointing at the cause.

### There is no version type at the Scheme level

A Kaappi program that wants to compare two version strings — a CLI checking a
minimum runtime, a config loader gating a feature, a library author writing a
compatibility shim — has nothing to reach for. It must either shell out or
hand-roll string splitting, and hand-rolled version comparison is a
well-known source of bugs (`"3.3.15.10" < "3.3.15.9"` under lexicographic
sort; `10 > 9` under numeric sort; the answer depends on rules most ad-hoc
code gets wrong). The runtime that *claims* SemVer compliance should ship the
one correct implementation so nobody re-derives it.

### The banner is not the contract

`kaappi --version` prints `Kaappi Scheme v0.22.3` (`src/cli.zig:190`). The
`v` is a display convention; the SemVer string is `0.22.3`. This KEP does not
change the banner, but it does draw the line clearly: the *version* is the
ASCII string `0.22.3`, and `(kaappi version)` is the module that gives that
string meaning. Exposing the running version as a parsed value (see
Reference-level design) lets a program ask "am I on at least 0.22?" without
string surgery on the banner.

## How other languages handle this

The research question was: does a language ship version handling in its
standard distribution, or leave it to a package? The instructive split:

| Language | Where it lives | Shape | Notes |
|---|---|---|---|
| **Elixir** | **stdlib** — [`Version`](https://hexdocs.pm/elixir/Version.html) | `Version` struct (`major/minor/patch/pre/build`) + `Version.Requirement` | Closest precedent: parse, `compare/2` → `:lt/:eq/:gt`, `match?/2`. Prereleases sort below releases; build is ignored in comparison. |
| **Rust** | package — [`semver`](https://crates.io/crates/semver) crate | `Version` + `VersionReq` | Not in std, but Cargo-blessed and near-universal; `^`/`~` ranges as popularized by node-semver. |
| **JavaScript** | package — [`node-semver`](https://github.com/npm/node-semver) | functions + `Range` | The de-facto reference implementation for `^`/`~`/range grammar the others cite. |
| **Go** | stdlib-adjacent — [`golang.org/x/mod/semver`](https://pkg.go.dev/golang.org/x/mod/semver) | string functions | SemVer 2.0.0 with one twist: version strings **must** carry a leading `v` (`v1.2.3`). |
| **Python** | stdlib-adjacent — [`packaging.version`](https://pydevtools.com/handbook/explanation/versioning-python-packages-semver-calver-and-pep-440/) | PEP 440 `Version` | Deliberately **not** SemVer: `1.0rc1`, epochs, `.postN`. A cautionary tale — see Alternatives. |
| **Ruby** | stdlib — `Gem::Version` | class | Comparison + pessimistic `~>` operator (RubyGems' answer to `~`/`^`). |

Takeaways that shape this design:

1. **The mainstream precedent for shipping it in-tree exists** — Elixir and
   Ruby both put a version type in the standard library, and Go ships one
   next to the toolchain. Kaappi already carries a (partial) one for its own
   package manager, so the marginal cost of finishing it and exposing it is
   low.
2. **Separate "a version" from "a requirement on versions."** Every mature
   implementation has two types: the point (`Version`) and the predicate over
   points (`VersionReq` / `Version.Requirement` / `Range`). We follow suit.
3. **`^` and `~` range semantics are node-semver's**, and Rust/Cargo copied
   them. kaappi's existing `thottam_semver.zig` already implements exactly
   this caret/tilde behavior (`src/thottam_semver.zig:30`), so we are
   standardizing what is already shipping, not inventing.
4. **Do not adopt PEP 440.** The user's stated goal is SemVer 2.0.0
   specifically; PEP 440's epochs and `rc1`-without-separator forms are a
   different grammar and would contradict the goal.

## Guide-level explanation

`(kaappi version)` is a pure-Scheme library — no build step, no FFI. It
introduces one disjoint type, `<version>`, and two vocabularies: comparison
and requirement matching.

### Parsing and inspecting

```scheme
(import (kaappi version))

(define v (string->version "1.4.2-rc.1+build.7"))

(version-major v)        ; => 1
(version-minor v)        ; => 4
(version-patch v)        ; => 2
(version-pre-release v)  ; => ("rc" 1)      ; list of strings/exact integers
(version-build v)        ; => ("build" "7") ; list of strings
(version->string v)      ; => "1.4.2-rc.1+build.7"  (round-trips)
(version? v)             ; => #t

(string->version "banana")   ; => #f   ; non-raising
(string->version "1.2")      ; => #f   ; SemVer requires all three parts
```

`string->version` returns `#f` on any string that is not a syntactically
valid SemVer 2.0.0 version. A variant `string->version*` raises a `(kaappi
version)`-tagged error instead, for call sites that treat a bad version as a
bug rather than a value.

### Comparing

Comparison follows SemVer §11 exactly: numeric fields compare numerically, a
prerelease version is *less than* its release, prerelease identifiers compare
per §11.4, and **build metadata is ignored**.

```scheme
(version<? (string->version "1.0.0-alpha") (string->version "1.0.0"))   ; => #t
(version<? (string->version "1.0.0-alpha.1") (string->version "1.0.0-alpha.beta")) ; => #t
(version=? (string->version "1.0.0+a") (string->version "1.0.0+b"))     ; => #t  ; build ignored

(version-compare (string->version "2.0.0") (string->version "1.9.9"))   ; => 'greater

;; sort a list of versions ascending
(list-sort version<? my-versions)
```

Provided predicates: `version=?`, `version<?`, `version<=?`, `version>?`,
`version>=?`, and the three-way `version-compare` returning `'less`,
`'equal`, or `'greater` (Scheme-idiomatic symbols rather than Elixir's
`:lt/:eq/:gt`).

### Requirement matching

A *requirement* is a predicate over versions, written in the same grammar
`thottam` already accepts on the command line, so `foo@^1.2` in a
`kaappi.pkg` and `(string->requirement "^1.2.0")` in code mean the same thing.

```scheme
(define req (string->requirement "^1.2.0"))

(version-satisfies? (string->version "1.5.0") req)   ; => #t
(version-satisfies? (string->version "2.0.0") req)   ; => #f
(requirement? req)                                    ; => #t

;; comma = AND, matching thottam's existing multi-constraint syntax
(version-satisfies? (string->version "1.4.0")
                    (string->requirement ">=1.2.0,<1.5.0"))   ; => #t
```

Supported operators: `=` (bare version), `>`, `>=`, `<`, `<=`, `^` (caret),
`~` (tilde), and comma-separated conjunction. This is exactly the operator set
`parseSingleConstraint` implements today (`src/thottam_semver.zig:63`); the
library is the Scheme-visible face of the same grammar.

### Asking about the running runtime

```scheme
(runtime-version)   ; => #<version 0.22.3>   ; the value behind `kaappi --version`

(version>=? (runtime-version) (string->version "0.22.0"))  ; => #t
```

`runtime-version` returns the interpreter's own version, parsed — the
programmatic form of the banner, so a script can gate on the runtime without
scraping `--version` output.

## Reference-level design

### The `<version>` record

`lib/kaappi/version.sld` defines a `define-record-type` with immutable fields:

```scheme
(define-record-type <version>
  (make-version major minor patch pre-release build)
  version?
  (major       version-major)        ; exact non-negative integer
  (minor       version-minor)        ; exact non-negative integer
  (patch       version-patch)        ; exact non-negative integer
  (pre-release version-pre-release)  ; list of (string | exact integer), possibly ()
  (build       version-build))       ; list of string, possibly ()
```

`make-version` is not exported directly; construction goes through
`string->version` / `string->version*` so the invariants below always hold.
A separate `version` constructor taking already-validated components is
exported for programmatic building (e.g. `(version 1 2 3 '() '())`).

### Grammar (SemVer 2.0.0, verbatim)

The parser accepts the BNF at <https://semver.org/#backus-naur-form-grammar-for-valid-semver-versions>:

- **version** = `<major> "." <minor> "." <patch>` then optional `"-" <pre>`
  then optional `"+" <build>`.
- **major/minor/patch** = a *numeric identifier*: `0`, or a non-zero digit
  followed by digits — **no leading zeros**.
- **pre-release** = dot-separated identifiers, each either a numeric
  identifier (parsed to an exact integer) or an *alphanumeric* identifier
  (`[0-9A-Za-z-]+` with at least one non-digit, kept as a string).
  Alphanumeric prerelease identifiers may have leading zeros; numeric ones
  may not.
- **build** = dot-separated identifiers of `[0-9A-Za-z-]+`, each kept as a
  string (build identifiers are never interpreted numerically).

Every character is ASCII by construction, which satisfies the user's
"version number would be ASCII alphanumerics" requirement: `string->version`
rejects any code point outside `[0-9A-Za-z.+-]`, and rejects empty
identifiers, leading-zero numerics, and a missing minor/patch.

### Comparison algorithm (SemVer §11)

`version-compare a b`:

1. Compare `major`, then `minor`, then `patch` numerically; first difference
   wins.
2. If both differ only past patch: a version **with** a prerelease is *less
   than* one **without** (§11.3). If both have prereleases, compare
   identifier lists left to right (§11.4):
   - numeric vs numeric → numeric order,
   - alphanumeric vs alphanumeric → ASCII lexical order,
   - numeric identifiers are *always lower* than alphanumeric,
   - a shorter list, all prior identifiers equal, is *lower*.
3. `build` is never consulted.

`version=?` is `(eq? 'equal (version-compare a b))`; the ordering predicates
are defined from `version-compare` so all seven agree by construction.

### Requirement type and matching

`<requirement>` wraps the same constraint set `thottam_semver.zig` uses: a
list of primitive constraints (op + version), matched conjunctively. Caret and
tilde reuse the exact rules at `src/thottam_semver.zig:30`:

- `^1.2.3` locks the major; `^0.2.3` locks the minor; `^0.0.3` locks the
  patch (the "left-most non-zero" rule).
- `~1.2.3` allows `>=1.2.3 <1.3.0`.

One clarification the Zig code leaves implicit and the library makes explicit:
**a version carrying a prerelease satisfies a requirement only if the
requirement's own comparator names that same major/minor/patch with a
prerelease** — i.e. `^1.2.0` does *not* match `1.3.0-rc.1` (node-semver's
rule). This prevents prereleases of a *future* version from leaking into a
caret range. This is a behavioral *addition* over today's Zig code, which has
no prerelease concept at all, so it cannot regress existing installs.

### Exported identifiers

```
version?  version  string->version  string->version*
version-major  version-minor  version-patch  version-pre-release  version-build
version->string
version-compare  version=?  version<?  version<=?  version>?  version>=?
version-pre-release?          ; #t iff pre-release list is non-empty
requirement?  string->requirement  string->requirement*
version-satisfies?
runtime-version
```

### `runtime-version` and the primitive it needs

The running version lives in Zig as `build_options.version`
(`src/main.zig:70`) and is not currently reachable from Scheme. This KEP adds
one nullary primitive, `%runtime-version-string`, returning that string, from
which `runtime-version` builds a parsed `<version>` once and memoizes it. The
primitive is placed in `(kaappi primitives)` (the explicit import channel
noted in CLAUDE.md), not `(scheme base)`, so it does not widen the R7RS
surface.

### Reconciling `thottam_semver.zig`

To make "kaappi follows SemVer 2.0.0" true of the package manager too,
`thottam_semver.zig` is extended to the full grammar:

- add `pre` and `build` fields to `Semver`,
- make `parse` accept (and correctly reject) prerelease/build,
- extend `order` with §11.3–11.4 prerelease precedence,
- keep the caret/tilde `matches` logic, adding the prerelease-scoping rule
  above.

The Scheme library and the Zig parser are then two implementations of one
grammar. Per the KEP-0008 discipline, a shared conformance vector (a table of
`input → parsed fields → pairwise ordering`) is checked by **both** the Zig
unit tests (`src/thottam_semver.zig` already has a `test` block at line 108)
and the Scheme test suite, so they cannot silently diverge.

## Drawbacks

- **Surface area.** It is one more core library to document and keep
  conformant. Mitigated by its small, closed API and a frozen upstream spec
  (SemVer 2.0.0 is at a final version and not evolving).
- **Two implementations of one grammar** (Zig + Scheme) is inherent
  duplication. The shared conformance vector is the guard, but a guard is not
  free. The alternative — having the Scheme library FFI into the Zig parser —
  is rejected below because it would make a pure library depend on a private
  package-manager internal.
- **Prerelease-scoping is a real behavior choice** with no single "obviously
  right" answer (npm and Cargo differ from Python here). Picking node-semver's
  rule ties us to explaining it.

## Alternatives considered

- **Ship nothing; let an ecosystem `kaappi-semver` package fill the gap.**
  Rejected: the runtime *asserts* SemVer compliance and already carries a
  parser for its own use; leaving users to install a third-party package to
  make sense of the runtime's own version string is a poor default, and Elixir
  and Ruby set the precedent of putting this in the standard distribution.
- **Expose `thottam_semver.zig` via FFI instead of a Scheme implementation.**
  Rejected: it inverts the dependency (a general-purpose library reaching into
  a package-manager internal), it cannot be used in the WASM/sandbox tiers
  where that code path may be absent, and a ~150-line pure-Scheme parser is
  cheap. The Zig code stays the package manager's, the Scheme library is the
  users', and the conformance vector keeps them honest.
- **Adopt PEP 440 (Python's scheme) for broader tooling reach.** Rejected:
  the explicit goal is SemVer 2.0.0. PEP 440 is a *different* grammar
  (epochs, `1.0rc1`, `.postN`, `.devN`) that is intentionally not SemVer;
  adopting it would contradict the request and the `semver.org` reference.
- **Require a leading `v` (Go's rule).** Rejected: SemVer 2.0.0 versions do
  not include `v`; it is a display prefix. `version->string` emits no `v`, and
  `string->version` rejects one. The banner keeps its cosmetic `v` (§"The
  banner is not the contract").
- **Fold this into KEP-0008's shared-IR contract.** Rejected: unrelated
  surface (versions, not compiler IR). KEP-0008 is cited only for the
  shared-conformance-vector *technique*.

## Cross-platform / compatibility impact

- **Pure Scheme, no FFI, no build step** — identical on every interpreter
  tier and on the LLVM native backend.
- **WASM / sandbox:** the library itself needs no host services. The one new
  primitive, `%runtime-version-string`, reads a comptime string
  (`build_options.version`) and is safe in the sandbox (it is not I/O). If a
  future sandbox policy wants to hide the runtime version, `runtime-version`
  is the single chokepoint to gate.
- **Backward compatibility:** additive. New library, new opt-in import,
  one new `(kaappi primitives)` entry. The `thottam_semver.zig` change is the
  only edit to existing behavior; it strictly *widens* what parses (previously
  rejected prerelease/build strings now parse) and adds ordering where there
  was none, so no currently-resolving install can change outcome — no
  published `kaappi.pkg` carries a prerelease tag today (see Motivation).
- **Docs:** a new Ecosystem/Guide page on kaappi.github.io, and a note in the
  `kaappi.pkg` manifest docs that its version/constraint grammar is now
  specified by this KEP.

## Unresolved questions

1. **Range-union (`||`).** node-semver supports `^1 || ^2`. thottam does not,
   and neither does this draft. Add disjunction now for parity, or defer until
   an ecosystem package needs it?
2. **Naming.** `string->version` / `version->string` are R7RS-idiomatic;
   Elixir-style `version-parse` reads better to some. Pick one convention
   before Accepted.
3. **`version-compare` return values.** `'less/'equal/'greater` (chosen here)
   vs reusing an existing kaappi ordering convention — does any current
   library already establish a three-way-compare symbol vocabulary to match?
4. **Prerelease-in-range rule.** Confirm node-semver's prerelease scoping is
   the behavior we want long-term before it becomes load-bearing in thottam's
   resolver.
5. Should `runtime-version` and `%runtime-version-string` ship in this KEP or
   split into a tiny follow-up, so the pure library can land first?

## Implementation plan

**Phase 1 — the pure library (no runtime coupling).**
`lib/kaappi/version.sld` with the `<version>` and `<requirement>` types,
parser, comparison, and requirement matching. Scheme test suite under
`tests/scheme/`, including the SemVer §11 precedence examples verbatim and the
shared conformance vector. Ships and is useful on its own.

**Phase 2 — reconcile the package manager.** Extend `thottam_semver.zig` to
the full grammar and prerelease ordering; wire the shared conformance vector
into its `test` block so Zig and Scheme are checked against the same table.

**Phase 3 — expose the runtime version.** Add `%runtime-version-string` in
`(kaappi primitives)` and `runtime-version` in the library (or split to a
follow-up per Unresolved Q5).

**Phase 4 — docs.** Ecosystem/Guide page on kaappi.github.io; update the
`kaappi.pkg` manifest documentation to reference this KEP as the normative
grammar for its `version:` and `depends:` version specs.
