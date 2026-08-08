# KEP-0012: thottam — The Package Manager

| Field | Value |
|-------|-------|
| **KEP** | 0012 |
| **Title** | thottam — The Package Manager |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/thottam.zig`, `src/thottam_state.zig`, `src/thottam_proc.zig`, `src/thottam_fs.zig`, `src/thottam_semver.zig`, `src/cli_spec.zig`, `src/main.zig`), `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against that source, not just
`docs/dev/thottam.md`, as of 2026-08-08 (the brief notes where doc and
source diverge).*

## Summary

thottam is Kaappi's package manager: a **second compiled Zig binary**,
built and released alongside `kaappi`, that installs ecosystem libraries by
git-cloning them, resolving SemVer constraints against their git tags,
running each package's declared `build:` command, copying its `lib/` tree
into `~/.kaappi/lib/`, and recording the resolved git commit in a lockfile.
The `kaappi` interpreter then adds `~/.kaappi/lib` to its library search
path automatically, so an installed package is importable with no flags. It
began as a shell script in v0.1.0 and was rewritten as the current compiled
binary in v0.2.0; SemVer constraints in `depends:` arrived in v0.8.0.

This is a retroactive, *as-built* KEP. It proposes no behavioural change. It
writes down thottam's externally-visible contracts — the `kaappi.pkg`
manifest grammar, the `pkg[@ver][::url]` install-spec grammar, the
lockfile format, the dependency-resolution algorithm (a recursive
first-writer-wins DFS with **no conflict detection**), the fetch and trust
model (git identity only; no content hashing; arbitrary `build:` shell
execution), and the `$KAAPPI_HOME` filesystem layout — so that changes to
any of them are measured against a numbered baseline. It also records
thottam's dependence on `thottam_semver.zig`, the 3-field version parser
that [KEP-0009](0009-version-library.md) proposes to reconcile against a
full SemVer 2.0.0 grammar.

## Motivation

The KEP process explicitly names "changes to the package manager / build
model" as KEP-worthy, yet the package manager itself — a whole second
shipped binary that fetches and executes third-party code — has never had a
design record. Its user-facing contracts are currently defined only by
`docs/dev/thottam.md` (which the source already contradicts in places) and
the code:

- **The manifest and lockfile are file formats other tools and package
  authors depend on.** `kaappi.pkg` and `thottam.lock` are consumed and
  produced across releases; their grammar is a compatibility surface. There
  is no numbered statement of what those formats guarantee.
- **The resolution and trust model carry real, non-obvious limitations
  that users should be able to cite.** thottam does *no* conflict
  detection — the first dependent to reach a package name wins, and a
  second, possibly-incompatible constraint on the same name is silently
  skipped. It does *no* content-hash verification — integrity is git-commit
  identity only. And it executes each package's `build:` line as a shell
  command and auto-loads the native libraries it produces, i.e. installing
  a package is full trust of its source. These are defensible design
  positions, but today they live only as code behaviour and a one-line
  banner warning.
- **The doc already lies in places.** For example, `thottam.md` describes a
  `depends: name[@ver::url]` inline-URL form, but `depends:` is split only
  on spaces before each token is re-parsed; and it omits the `verify`
  subcommand entirely. A numbered, source-verified record replaces a
  drifting one.

A written contract turns "read five Zig modules and a test file" into "read
KEP-0012," and gives future changes — a real solver, checksum
verification, a registry beyond GitHub — something to amend.

## Guide-level explanation

thottam is its own command, not a `kaappi` subcommand:

```bash
thottam install kaappi-json            # clone, resolve, build, install into ~/.kaappi/lib
thottam install kaappi-net@v0.3.0      # pin an exact tag
thottam install 'kaappi-http@^0.2'     # resolve a caret range against the repo's git tags
thottam install mylib::https://example.com/mylib.git   # install from a custom URL
thottam list                           # list installed packages
thottam update [pkg]                   # update one package, or all
thottam remove kaappi-json             # uninstall
thottam verify                         # check installs still match the lockfile
thottam --locked install               # refuse anything not already pinned in the lockfile
```

After `thottam install kaappi-json`, a program just imports it — no
`--lib-path` needed, because `kaappi` adds `~/.kaappi/lib` to its search
path:

```scheme
(import (kaappi json))
```

A package describes itself with a `kaappi.pkg` manifest at its repo root:

```
name: kaappi-http
version: 0.2.0
build: make                    # only if the package has native code to build
depends: kaappi-net kaappi-json
source: https://github.com/kaappi/kaappi-http
```

What actually happens on `thottam install kaappi-http`: thottam clones the
repo into `~/.kaappi/src/kaappi-http`, reads its manifest, **installs each
dependency first** (recursively), runs the `build:` command, copies the
`lib/` tree into `~/.kaappi/lib/`, copies any produced `.dylib`/`.so`/`.dll`
flat into `~/.kaappi/lib/`, and appends a lockfile line recording the
resolved git commit. The important thing to understand as a user:
**installing a package runs that package's build command and loads its
native libraries — thottam trusts the source completely, and so are you.**

## Reference-level design

### Binary and command dispatch

thottam is a separate Zig binary with its own `main()`
(`thottam.zig:811`) and panic banner (`thottam.zig:20`), built by
`zig build` and shipped in every release artifact. Dispatch is a flat
string `if/else` chain over the first non-flag word, not a spec-driven
table:

| Command | Entry | Behaviour |
|---|---|---|
| `install` | `doInstall` (`thottam.zig:375`) | Recursive fetch/resolve/build/install. |
| `remove` | `doRemove` (`:524`) | Uninstall; update lockfile + installed list. |
| `list` | `doList` (`:562`) | List installed packages. |
| `update` | `doUpdate` (`:607`) | Re-fetch one package or all. |
| `verify` | `doVerify` (`:703`) | Per-package `OK`/`MISMATCH`/`MISSING` vs lockfile SHA. *(Undocumented in `thottam.md`.)* |

Flags are defined authoritatively in `cli_spec.zig:361`
(`ThottamId = enum { locked, help, version_flag, completions_flag }`):
`--locked`, `-h`/`--help`, `--version`, `--completions <bash|zsh|fish>`.
The flag loop scans past the subcommand, so `thottam install --locked pkg`
and `thottam --locked install pkg` are equivalent (`thottam.zig:828`). The
`thottam_subcommands` table (`cli_spec.zig:372`) exists only for
completion generation; positionals reach dispatch unparsed as
`pkg[@ver][::url]`. There is **no `add` subcommand**.

### The `kaappi.pkg` manifest

Parsed by `parsePkgManifest` (`thottam_state.zig:57`) into `PkgManifest`
(`thottam_state.zig:10`). Line-based; the key must start at column 0; the
value is trimmed of spaces/tabs/CR. Four recognized keys — `name:`,
`depends:` (space-separated), `build:`, `source:` — with unknown keys
ignored and last-of-duplicate-key winning (CRLF tolerated). Security guard:
a `source:` value beginning with `-` is dropped (`thottam_state.zig:68`) to
prevent option injection into git.

### Install-spec and dependency-spec grammar

`parsePkgSpec` (`thottam_state.zig:26`) parses `pkg[@ver][::url]`: split at
the first `::` for the source URL, then at the first `@` before it for the
version. A URL beginning with `-` is dropped. `depends:` is split on spaces
into tokens, and **each token is itself re-parsed by `parsePkgSpec`**, so a
dependency may carry its own `@ver`/`::url`. `isValidPkgName`
(`thottam_state.zig:42`) restricts names to `[A-Za-z0-9_-]` and rejects
traversal/absolute/empty names — this guards the install tree, since the
name becomes a directory.

### Version constraints (`thottam_semver.zig`)

`ConstraintOp = enum { gte, gt, lte, lt, eq, caret, tilde }`
(`thottam_semver.zig:24`). `Constraint.matches` (`:30`): **caret** locks
the leftmost non-zero component (`^1.2.3` → same major; `^0.2.3` → same
minor; `^0.0.3` → exact patch); **tilde** locks major+minor with `>=`.
`parseConstraints` (`:48`) splits on `,` (conjunction — all must hold via
`matchesAllConstraints`, `:93`), trims surrounding quotes, and caps at
**4 constraints** (returns null past 4).

Resolution against a repo's tags: `resolveVersion` (`thottam.zig:187`) runs
`git ls-remote --tags`, parses each `refs/tags/<tag>` as a `Semver`, and
keeps the highest tag satisfying all constraints. This runs **only** when
the spec `isConstraintSpec` (starts with `> < ^ ~`); a plain `@v1.0.0` is
checked out directly without resolution.

### Dependency resolution: recursive DFS, first-writer-wins

`doInstall` (`thottam.zig:375`) is a recursive depth-first walk:

1. A `visited` `StringHashMap` guards cycles and duplicates (`markVisited`,
   `:358`, copies keys because dependency names alias manifest memory freed
   on unwind — #784).
2. `isInstalled` short-circuits already-present packages.
3. Dependencies are installed **before** the package's own `build:` and
   `lib/` copy (`:491`).

There is **no global solver, no backtracking, and no conflict detection**.
If two packages depend on the same name, `visited` skips the second
entirely — whichever dependent is reached first fixes the resolved version,
and a second constraint on that name is never checked. Transitive
dependencies are handled purely by recursion depth. This is a deliberate
simplicity/scope choice, and one of the most important things this KEP
records because it is invisible from the outside until it bites.

### Fetch and trust model

All git runs through `thottam_proc.zig`, which invokes `/usr/bin/git` by
absolute path on POSIX (`thottam_proc.zig:148`) and `git` on PATH on
Windows, via a manual `fork`/`execve` with pipe capture (`runCapture`,
`:4`). Clone is `git clone --quiet -- <url> <dir>` (`thottam.zig:459`);
checkout is `git checkout --quiet <ver> --`. The `--` terminators and the
reject-leading-`-` guards defend against git option injection (#614, #736,
#969). The default clone URL is `{org}/{pkg}.git` where `org` is
`$KAAPPI_ORG` or `https://github.com/kaappi` (`thottam.zig:791`); a `::url`
spec or manifest `source:` overrides it.

The `build:` command is executed via `/bin/sh -c <build_cmd>`
(`thottam.zig:317`; refused on Windows), and the native libraries it
produces are copied into the shared `lib/` and later auto-loaded. **The
trust model beyond git/TLS transport is: none.** No signatures, no content
checksums. The usage banner is explicit (`thottam.zig:772`): thottam runs
the package's build command and copies its native libraries, so package
manifests from untrusted sources must be reviewed before installing.
Installing a package is equivalent to running its author's code.

### The lockfile

Path `$KAAPPI_HOME/thottam.lock` (default `~/.kaappi/thottam.lock`,
`thottam.zig:799`). Format is one line per package, space-separated:
`<pkg> <sha> [source-url]` (the URL column present only for
custom-sourced packages). Writer `appendLockEntry`
(`thottam_state.zig:117`); reader `getLockedEntry` (`:89`), which is
prefix-safe (`kaappi-net` must not match `kaappi-net-x`, #403). The
recorded SHA is the resolved git commit (`git rev-parse HEAD`,
`getPkgSha`, `thottam.zig:226`). **No content hashes** — integrity is
git-commit identity, verified two ways: `--locked` refuses packages absent
from the lockfile and aborts on a post-checkout SHA mismatch
(`doInstall:403`), and `verify` reports `OK`/`MISMATCH`/`MISSING` per
package (`doVerify:703`). A separate `installed.txt` records installed
names.

### Filesystem layout (`$KAAPPI_HOME`)

`$KAAPPI_HOME` is `$KAAPPI_HOME` env or `$HOME/.kaappi`
(`$USERPROFILE/.kaappi` on Windows), built in `buildConfig`
(`thottam.zig:783`):

- `lib/` — installed `.sld` sources (directory structure preserved) and
  native libraries (copied flat).
- `src/` — git clones, one directory per package.
- `installed.txt` — flat list of installed names.
- `thottam.lock` — the lockfile.

`thottam_fs.zig` is a portable filesystem layer (#1609) that reimplements
`cp -R` / `find` / `mkdir -p` / `rm -rf` / `touch` directly (no spawned
processes, identical Windows behaviour): `copyTree` (`:164`, merge
semantics), `removeTree` (`:216`, which retries via `makeWritable` for
git's read-only pack files), `collectFilesWithSuffix` (`:267`). Symlinks
are never followed — an escape guard (`removeIfLink`, `:76`).

### Search-path wiring (in the `kaappi` binary)

`main.zig:453` assembles the library search path in this order: (1)
explicit `--lib-path` entries, (2) the running script's own directory, (3)
`~/.kaappi/lib` (thottam's install dir), (4) an exe-relative `../lib`
fallback for from-source builds (#1523). So installed packages are
importable with no flags, and `--lib-path` still takes precedence. On
POSIX, `~/.kaappi/lib` is also prepended to
`DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH` so native `ffi-open` finds installed
shared libraries (`main.zig:502`). Note: `~/.kaappi/lib` is deliberately
**not** on the `kaappi compile` `libkaappi_rt.a` search path (see
[KEP-0010](0010-llvm-native-backend.md)).

### Relationship to KEP-0009 and the version parser

`thottam_semver.zig` is thottam's own version parser — a 3-field
`Semver { major, minor, patch: u32 }` (`:3`) with no shared code with any
runtime version library. It **drops prerelease and build metadata
entirely**: `Semver.parse` reads exactly three dot-separated integers and
*rejects* any tag carrying `-pre` or `+build`
(`Semver.parse("1.0.0-rc1")` → `null`), so such tags never become install
candidates. The test rationale states this is intentional for ranges
without a prerelease tag of their own, matching node-semver's default. It
is exactly this parser that [KEP-0009](0009-version-library.md) proposes to
reconcile against a full SemVer 2.0.0 grammar via a shared conformance
vector; this KEP records the current, pre-reconciliation behaviour so the
two can be compared. Known laxities are tracked under #2130 (extra dotted
components silently discarded; leading zeros accepted; `parseInt` accepting
`+`/`_`).

### Tests

`tests_thottam.zig` covers `Semver.parse` (v-prefix, zero-defaulting,
rejection of prerelease/build/signed/empty, u32-overflow safety),
constraint operators and caret/tilde per node-semver, `parseConstraints`
conjunction and the 4-constraint cap, `parsePkgSpec` splitting and
option-injection guards (#614), `isValidPkgName`, manifest parsing, and
lockfile round-trips including prefix-safe lookup (#403). Sibling modules
carry inline tests: `markVisited` (#784), `checkoutVersion` guards (#736,
#780), and `thottam_fs` symlink-escape / read-only-pack cases.

## Drawbacks

An as-built KEP for a subsystem still evolving (Windows port #1609, module
split #1063/#1089, semver laxities #2130) risks drift. Mitigation: this KEP
records *contracts and design positions* (the manifest/lockfile formats,
the first-writer-wins resolution, the git-identity trust model) rather than
mirroring implementation detail, and pins line references to a commit.

Writing down "no conflict detection" and "no checksum verification" as
current behaviour could be read as endorsing them permanently. It is not:
the Unresolved questions flag both as candidates for change. The record's
job is to make the current position explicit enough that a change to it is a
visible, reviewable amendment rather than a silent behavioural shift.

## Alternatives considered

- **Leave it at `docs/dev/thottam.md`.** Rejected: that doc is not a
  reviewable decision record, and it already contradicts the source (the
  `depends` inline-URL claim; the missing `verify` command). A numbered,
  source-verified KEP supersedes a drifting doc.
- **Fold thottam into KEP-0009** (the version library). Rejected: KEP-0009
  is about *version semantics*; thottam is a fetch/build/resolve subsystem
  that merely consumes a version parser. They reference each other but have
  distinct scopes — conflating them would bury the package-manager design
  under SemVer minutiae.
- **Split into several KEPs** (manifest format, resolution, trust model).
  Rejected as premature fragmentation: the trust model is only
  comprehensible alongside the fetch/build flow it secures, and the
  resolution algorithm alongside the manifest it reads.
- **Wait for a "real" solver / registry before documenting.** Rejected: the
  current simple model is what ships today and what users hit; recording it
  now is what lets a future solver be proposed *against* a baseline.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- thottam ships on every platform kaappi does. git is the sole fetch
  transport (absolute `/usr/bin/git` on POSIX; `git` on PATH on Windows).
  `build:` runs via `/bin/sh -c` and is **refused on Windows**, so packages
  needing a native build step are POSIX-only to install.
- `thottam_fs.zig` gives identical file-operation semantics across
  platforms without spawning processes (#1609).
- The `kaappi.pkg` manifest, the `pkg[@ver][::url]` spec grammar, and the
  `thottam.lock` line format are cross-version compatibility surfaces.
- Installed packages are picked up by the interpreter with no flags via
  `~/.kaappi/lib`, but are deliberately **not** visible to the
  `kaappi compile` native backend (KEP-0010).
- The trust model (git identity only, arbitrary `build:` execution, native
  library auto-load) is identical on all platforms; there is no sandboxed
  install mode.

## Unresolved questions

1. **Should the `kaappi.pkg` and `thottam.lock` formats be frozen as
   versioned contracts?** If so, does changing a field require a KEP
   amendment, or only a CHANGELOG note and a format-version bump?
2. **Is first-writer-wins resolution the intended long-term behaviour, or a
   documented interim?** A future proposal for real conflict detection /
   backtracking would supersede this section.
3. **Should thottam add content-integrity verification** (checksums or
   signatures) beyond git-commit identity, especially for custom `::url`
   sources outside the `kaappi` GitHub org?
4. **Is there a sandboxed / build-less install mode worth having** for
   pure-Scheme packages, so installing does not imply executing the
   author's `build:` line? (Cross-reference the sandbox boundary in
   [KEP-0011](0011-ffi-and-sandbox.md).)
5. **What is the reconciliation plan with KEP-0009's version library** —
   does thottam eventually consume the runtime `(kaappi version)` parser
   (sharing prerelease/precedence rules), or stay on its own reduced
   `thottam_semver.zig`? The #2130 laxities are the concrete forcing
   function.
6. **Registry beyond GitHub**: the default org and the `::url` escape hatch
   are the whole discovery model. Is a registry/index in scope for a future
   KEP?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Reconcile `docs/dev/thottam.md`** with source: fix the `depends`
   inline-URL description, add the `verify` subcommand, and point the doc at
   this KEP as the canonical, numbered summary.
3. **Decide the format-freeze and change-control questions**
   (Unresolved 1) and annotate the manifest/lockfile sections accordingly.
4. **Coordinate with KEP-0009** on the `thottam_semver.zig` reconciliation
   (Unresolved 5); if the shared conformance vector lands, record here
   which prerelease/precedence rules thottam adopts.
5. **Publish user-facing guidance** on `kaappi.github.io` (the thottam
   ecosystem page): the trust model and the "installing runs the author's
   build" caveat, the `--locked` / `verify` integrity workflow, and the
   no-conflict-detection limitation, linking this KEP.
6. **On acceptance**, triage Unresolved 2–4 and 6 into tracked issues in the
   core repo so any future solver / checksum / registry work amends this
   KEP rather than starting from source.
