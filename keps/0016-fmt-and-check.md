# KEP-0016: The Canonical Formatter (kaappi fmt) and Static Linter (kaappi check)

| Field | Value |
|-------|-------|
| **KEP** | 0016 |
| **Title** | The Canonical Formatter (kaappi fmt) and Static Linter (kaappi check) |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/fmt.zig`, `src/fmt_print.zig`, `src/check.zig`, `src/check_lint.zig`, `src/cli_spec.zig`, `src/main.zig`), `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | KEP-0005 (The Diagnostic Contract) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. `fmt` and `check`
already have accurate dev docs (`docs/dev/fmt.md`, `docs/dev/check.md`);
this KEP consolidates them into a numbered contract and records the few
places doc and source diverge (noted inline).*

## Summary

Kaappi ships two deterministic source-tooling subcommands that together
close out the "machine-legibility epic" (#1503): `kaappi fmt`, a canonical
comment-preserving formatter, and `kaappi check`, a compile-only static
linter. `fmt` reads Scheme through its *own* concrete-syntax reader (one
that keeps comments), builds a CST, and pretty-prints a single canonical
layout — 2-space R7RS indentation, 80-column reflow — guarded by a
real-reader `equal?` round-trip check so a formatter bug can never corrupt a
file. `check` drives the *real* compiler over every top-level form, executes
nothing, and reports the reserved `KP4xxx` lint findings (unknown top-level
variable, wrong arity, wrong-type literal) under a soundness invariant: it
never rejects a program R7RS permits.

This is a retroactive, *as-built* KEP with two deliberate scoping decisions.
First, `fmt` is the primary subject and gets a full reference spec — its
style rules, the distinguished-subform table, the idempotency and
round-trip guarantees, and the comment/line-ending policy — because a
canonical formatter *is* a compatibility/style contract (every diff in the
ecosystem depends on it being stable). Second, `check` is covered narrowly:
its three lint *rules* and analysis design are specified here, but its
diagnostic *payload* — the `KP` code taxonomy, the registry, the JSON/LSP
`Diagnostic` shape, the `error-object-code` surface, the stability policy —
is **not**. That belongs to [KEP-0005](0005-diagnostic-contract.md), which
`check` consumes unchanged through the same `lsp_diagnostic.zig` serializer
the CLI and the language server use. This KEP declares `Requires: KEP-0005`
and does not re-specify any of it.

## Motivation

`fmt` and `check` are the connective tooling of the machine-legibility
epic, and each is a contract worth pinning:

- **A canonical formatter is a stability contract for the whole
  ecosystem.** `fmt`'s job, in the dev doc's words, is to make "diffs
  meaningful, end style review, and give agents format-on-save invariance —
  the same job `zig fmt` does for the compiler's own Zig." That only holds
  if the canonical form is *stable and idempotent*. The exact style rules
  (the distinguished-subform table, the 80-column reflow, call-vs-body
  break selection) and the two invariants they rest on (`measure` agrees
  with the emitter; layout is a pure function of content+comments) are
  precisely what a future change must not silently break. Today they live
  only in `fmt_print.zig` and a doc whose subform list is illustrative
  rather than exhaustive.
- **The round-trip safety net is a design position worth recording.**
  `fmt` refuses to write unless the real reader confirms the formatted text
  is `equal?` to the original datum sequence — "a bug in the lexer, parser,
  or printer can therefore never corrupt a source file; at worst a file is
  left unformatted." That "correctness over formatting" stance (and its one
  consequence, cyclic-datum files left untouched) is the kind of decision a
  KEP should preserve.
- **`check` is the sharpest test of the KEP-0005 boundary.** Like the LSP
  (KEP-0015), `check` emits diagnostics through the shared serializer and
  claims a reserved code range (`KP4xxx`) under KEP-0005's registry and
  stability policy. Recording *exactly* what `check` adds (three rules, a
  narrow type/arity table, a soundness invariant) versus what it inherits
  (everything about the diagnostic payload) keeps the two KEPs from
  drifting and keeps `check` from ever growing a second diagnostic shape.

## Guide-level explanation

### Formatting

```bash
kaappi fmt src/            # format every file under src/ in place
kaappi fmt --check src/    # report files that would change; exit 1 if any do
cat foo.scm | kaappi fmt   # no args: read stdin, write formatted result to stdout
```

`fmt` produces one canonical layout regardless of how the input was spaced
or line-broken: 2-space indentation, single-space separators, closing
parens gathered, and forms reflowed to fit 80 columns. It never edits inside
a datum — string, number, character, and symbol spellings are preserved
byte-for-byte (`'x` is not expanded to `(quote x)`, `#xFF` stays `#xFF`).
Comments and single blank lines survive. It is idempotent: formatting an
already-formatted file changes nothing (and `fmt` won't rewrite a file whose
content wouldn't change). Crucially, `fmt` will **refuse to touch a file** if
it can't prove the result is semantically identical to the original, so it is
safe to run over a whole tree.

### Checking

```bash
kaappi check foo.scm                     # compile-only lint; text diagnostics
kaappi check --diagnostics=json foo.scm  # machine-readable Diagnostic JSON
kaappi check --deny-warnings foo.scm     # warnings fail the exit code too
```

`check` reads, macro-expands, and compiles every top-level form but **runs
nothing**. On top of the ordinary read/compile diagnostics it adds three
lint findings: an unknown top-level variable (`KP4001`, warning), a call to
a known built-in with the wrong number of arguments (`KP4002`, error), and a
literal argument of a type a built-in can't accept there (`KP4003`, error).
Its guiding rule is soundness: **it never flags something R7RS says is
valid** — forward references are legal, so an unknown variable is only a
warning, and the error checks fire only when a call is *guaranteed* to fail.

`fmt` and `check` are independent tools; the only thing they share is the
philosophy of the #1503 epic — deterministic, machine-legible output across
the toolchain.

## Reference-level design — fmt

### CLI surface

Subcommand `fmt` (`cli_spec.zig:344`): "Canonically format Scheme source in
place," positional `.path`, and exactly one fmt-specific flag, `--check`
(`cli_spec.zig:283`, "Report files needing formatting without writing").
There is no `--diff`, `--write`, `-o`, or `--in-place`. Dispatch is
`main.zig:595`. Two modes (`fmt.zig:571`): with path args, format **each
file in place** (directories via the `.path` positional); with **no** args,
read stdin and write the formatted result to stdout (`runStdin`,
`fmt.zig:633`). Exit codes (`fmt.zig:586`): `1` on any read/parse/round-trip
error; in `--check` mode `1` if any file would change; else `0`. Write mode
rewrites **only when content actually changes** (`formatFile` compares
`formatted == source` and skips the write, `fmt.zig:618`).

### Formatting model — CST, not token munging

`fmt` uses its **own** concrete-syntax reader, separate from the
interpreter's, because the ordinary reader discards comments and "cannot
drive a formatter." The pipeline: a lexer emits every lexeme — including the
three comment kinds (`;` line, `#| |#` block, `#;` datum) — with a
`newlines_before` count; a parser builds a CST of `Node`s (lists/vectors,
atoms, reader prefixes `'` `` ` `` `,` `,@`, datum labels `#3=`, datum and
line/block comments), keeping each lexeme's text **verbatim**; and the
printer (`fmt_print.zig`) lays it out. Entry points: `fmt.zig:512` `parse`,
`fmt.zig:522` `formatSource`, `fmt_print.zig:41` `print`. The formatter
"rearranges whitespace *between* lexemes; it never edits a lexeme" — so all
atom spellings, quote forms, and radix/exactness prefixes are preserved.

### Style rules (the canonical form)

Constants (`fmt_print.zig:36`): `max_width = 80`, `indent_step = 2`. Rules:
2-space bodies; runs of spaces/tabs collapse to one; closing parens are
gathered (never dangling, unless a trailing line comment forces the break);
a form fitting in 80 columns goes on one line, else it breaks; layout depends
only on content and comments, never on the input's line breaks; output is
always LF.

**Break-shape selection** (`styleOf`, `fmt_print.zig:364`) picks between two
shapes:

- **Body style** (`emitBodyStyle`, `:184`): a fixed number of
  *distinguished* leading subforms stay on the head line; the remaining body
  goes one item per line, indented 2.
- **Call style** (`emitCallStyle`, `:211`): the first argument stays on the
  head line and the rest align under it (the Emacs/`scmindent` default).
  Used for function calls, `cond`, `and`/`or`, vectors, and **any
  unrecognised head** — so unfamiliar macros format predictably.

The **distinguished-subform table** (`bodyDistinguished`,
`fmt_print.zig:381`) is the canonical style contract; `n` is the count of
subforms kept on the head line:

- **n = 1**: `lambda`, `define`, `define-values`, `define-syntax`,
  `define-record-type`, `define-library`, `let*`, `letrec`, `letrec*`,
  `let-values`, `let*-values`, `let-syntax`, `letrec-syntax`, `when`,
  `unless`, `case`, `parameterize`, `guard`, `syntax-rules`, `test-group`,
  `test-group-with-cleanup`.
- **n = 0**: `begin`, `case-lambda`.
- **n = 2**: `do`, `receive`.
- `let` is special-cased in `styleOf` (`:369`): a named let
  `(let loop ((…)) …)` uses body-2, a plain let body-1.
- Unknown heads default to call style.

*(Divergence to fix: `fmt.md` lists a representative subset of this table
and says "and the like"; the source table above is authoritative and should
be quoted in the doc.)*

### Idempotency and the round-trip safety net

`fmt` guarantees `fmt(fmt(x)) == fmt(x)`. It rests on two tested invariants:
the fit predicate (`measure`/`computeMeasure`, `fmt_print.zig:294`) and the
inline emitter agree exactly on width; and layout is a pure function of
content + comments. A subtlety: `hasBodyBlank` (`:347`) forces a break only
for a blank the layout will actually preserve, so dropped blank lines never
resurrect on a second pass.

The safety net is `verifyRoundTrip` (`fmt.zig:531`): before writing, `fmt`
re-reads *both* the original and the formatted text with the **real**
interpreter reader (`readAllRooted`) and compares the datum sequences with
`primitives.deepEqual` (`equal?`). Any mismatch or read failure → it
refuses to write, reports an error, and returns `.failed`. Hence "a bug in
the lexer, parser, or printer can never corrupt a source file; at worst a
file is left unformatted." One documented consequence: self-referential
(cyclic datum-label) files cannot be compared and are left untouched.

### Comment, blank-line, and line-ending policy

- Line comments force their enclosing list to break and keep the closing
  paren off their line. A comment on the same source line as the preceding
  datum stays **trailing**; a comment on its own line **leads** the next
  datum.
- A **single** blank line between body items / top-level forms is preserved;
  runs collapse to one (`emitTopLevel`/`blankLine`, `fmt_print.zig:82`); a
  blank before a subform riding the head line is dropped.
- Layout line endings normalise to **LF**, and the file ends in exactly one
  `\n` (#2093; Windows writes LF via binary mode). **Bytes inside a datum
  are never touched** — string literals, SRFI-267 raw strings, piped symbols
  `|a\rb|`, and char literals survive byte-for-byte. One known deviation
  (#2079): because the reader ends a `;` comment only at `\n`, a lone CR
  inside a comment is preserved rather than treated as a line end.

### Malformed input

`fmt` **refuses to format** a file it cannot parse: `formatSource` errors
propagate and `formatFile` returns `.failed` (`fmt.zig:608`). The
`ParseError` set (`fmt.zig:661`) names the failure precisely
(`UnterminatedList`, `UnterminatedString`, `UnterminatedBlockComment`,
`UnexpectedRightParen`, `DanglingPrefix`, `DanglingDatumComment`,
`NestingTooDeep`, `OutOfMemory`). Deep nesting is *rejected*, not crashed.

### Tests

`src/tests_fmt.zig` (input→output cases, comment/blank preservation, the
idempotence property, semantics-preserving round-trip over `fuzz_gen`
programs, parser diagnostics); `tests/scheme/fmt/fmt.sh` (CLI behaviour,
`--check` exit codes, stdin, line-ending policy, and a **corpus-wide**
zero-semantic-drift + idempotence sweep over every `.scm`/`.sld` in
`tests/scheme/` and `lib/`); `tests/scheme/fmt/fmt-adversarial.sh` (hard
comment-placement cases, each asserting a second pass is a no-op); and an
on-demand fuzzer `tools/fmt_fuzz.py`.

## Reference-level design — check (scope-limited)

### What check is

A compile-only static analyzer, independent of `fmt`. It "reads,
macro-expands, and compiles every top-level form … but executes no program
code, and adds the reserved `KP4xxx` lint findings." It drives the **real**
compiler (`ir.lowerAndOptimize` calls `check_lint.maybeWalk`), discards the
bytecode, and turns IR optimization off during the check so no call is
folded away before it can be inspected (`check.zig:87`). Env-setup forms are
classified via the same `vm.topLevelHead`/`runTopLevelHead` entry the real
interpreter uses.

### The three lint rules (this KEP's scope)

- **`KP4001`** (warning) — an unknown top-level variable: a free reference
  that is neither a built-in, an import, nor defined in the file
  (`checkGlobalRef`, `check_lint.zig:161`). A *warning*, not an error,
  because R7RS forward references are legal.
- **`KP4002`** (error) — wrong argument count on a direct, unshadowed call
  to a known built-in, compared against the VM-registered arity
  (`checkArity`, `:232`).
- **`KP4003`** (error) — a literal argument of a type a known built-in
  cannot accept in that position (`checkTypes`, `:256`).

The **type/arity table** (`type_table`, `check_lint.zig:301`, via
`TypeSpec`) is deliberately narrow — pair accessors, list ops, the numeric
core, string/vector/char operations — and intentionally **omits**
higher-order/polymorphic built-ins (`map`, `apply`, `append`, `cons`,
`eq?`, `display`, `not`). Only self-evaluating and quoted literals are
type-checked. Macro-synthesised calls are suppressed
(`enter`/`exitMacroExpansion`), and `apply`/`call/cc`/`eval`/
`call-with-values` lower to passthroughs so their arity is not checked.

### The soundness invariant

"`kaappi check` never rejects a program that R7RS says is valid. Anything
the spec permits is at most a warning." Error-severity findings fire only
when a call is *guaranteed* to fail. This invariant is guarded by a
conformance test: the full R7RS suite must pass `kaappi check` with zero
errors in CI.

### CLI surface

Subcommand `check` (`cli_spec.zig:336`): "Compile-only static analysis,
nothing is executed," positional `.scm_file`, flags `--diagnostics=text|json`
(`cli_spec.zig:267`), `--deny-warnings` (`:268`, "Treat lint warnings as
errors for the exit code"), and `--lib-path`. Dispatch `main.zig:570`. Exit
code (`check.zig:100`) is nonzero iff any error-severity finding exists, or,
with `--deny-warnings`, any warning. Text output is
`line:col: label[CODE]: message` plus a `check: N errors, M warnings`
summary (`reportText`); JSON output is one `Diagnostic` per line
(`reportJson`).

*(Divergence to note: the site guide describes `--diagnostics=json` as
"JSON Lines on stderr" for run-mode, but `check`'s `reportJson` writes to
**stdout** — `check.zig:376`. Worth reconciling in the docs.)*

### The KEP-0005 boundary (what check does *not* own)

`check` emits through `lsp_diagnostic.zig` — the same object and serializer
as `kaappi --diagnostics=json` and the language server (#1505).
`reportJson` (`check.zig:360`) builds an `lsp_diagnostic.Diagnostic` from
`spanRange(f.span)`, `severityOf(f.code.info().severity)`,
`f.code.render(...)`, and `f.message`, then calls `diag.writeJson` —
"nothing new to parse." Everything about that payload belongs to
**KEP-0005** and is **not** re-specified here:

- the `KP` code taxonomy and the reserved `KP4xxx` range;
- the diagnostic registry, severity semantics, and stability policy;
- the JSON/LSP `Diagnostic` shape and `writeJsonString` escaping;
- the `error-object-code` Scheme surface.

This KEP owns only the three rules, the type/arity table, the soundness
invariant, and the compile-only analysis design. Note the sharing with the
LSP (KEP-0015) is at the *serializer* level (`lsp_diagnostic.zig`), not a
shared analysis module — `check` has its own IR-walk lint pass.

### Tests

`src/tests_check.zig` (compiler-driven unit tests; negative cases for
shadowing, redefinition, quoting, macro suppression, non-literals);
`tests/scheme/errors/check.sh` (CLI behaviour, `--deny-warnings`,
`--diagnostics=json` parity, and the R7RS conformance guard);
`tests/scheme/errors/explain.sh` (each `KP4xxx` registry example triggers
its code).

## Drawbacks

Bundling `fmt` and `check` in one KEP couples two independent tools; a
future change to only one touches a shared document. Justification: both are
the #1503 machine-legibility epic's deterministic-tooling pair, both are
small enough that a KEP each would be thin, and the `check` half is
intentionally a *pointer* to KEP-0005 rather than a full spec, so the
document's weight is overwhelmingly the formatter.

Freezing the fmt style table in a numbered doc risks reading as immutable.
It is not meant to — the Unresolved questions treat the distinguished-subform
set and the 80-column width as amendable. The value is that *changing* the
canonical form becomes a visible, reviewable amendment, because such a change
re-flows every file in the ecosystem and must be understood as the
compatibility event it is.

## Alternatives considered

- **Two separate KEPs (fmt, check).** Rejected: `check` scoped against
  KEP-0005 is only a page of rules and a boundary statement — too thin to
  stand alone — and both tools are the same epic's output. They are
  independent in code but coherent as a "deterministic source tooling" KEP.
- **Fold `check` into KEP-0005.** Tempting, since `check` claims a KP range.
  Rejected for the same reason the LSP wasn't folded in (KEP-0015):
  KEP-0005 is a cross-surface *data contract*; `check` is an *analysis tool*
  with lint rules, a type table, and a soundness invariant that are not
  diagnostic-payload concerns. The clean split is "KEP-0005 owns the codes
  and shape; KEP-0016 owns the rules that raise them," via `Requires`.
- **Fold `check` into KEP-0015 (LSP).** Rejected: they share the serializer,
  not the analysis; the LSP runs `check`-like analysis but the tools have
  different surfaces (editor protocol vs CLI exit codes) and different
  scoping choices. Cross-reference, don't merge.
- **Leave both to their dev docs.** The dev docs are unusually good, but
  they are not numbered, reviewable contracts, their subform list is
  illustrative rather than exhaustive, and the stream divergence
  (stdout vs stderr) and the fmt table gaps show doc drift a source-verified
  KEP corrects.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- `fmt` normalises layout line endings to LF on every platform (binary-mode
  writes on Windows) but never alters bytes inside a datum; the canonical
  form (2-space indent, 80-column reflow, the distinguished-subform table) is
  identical across platforms.
- `fmt`'s round-trip guard uses the real reader and `equal?`, so a formatter
  defect degrades to "file left unformatted," never corruption — the same
  guarantee on every platform.
- `check` is compile-only and executes nothing, so it has no runtime/OS
  footprint; it is unaffected by `--sandbox` beyond the ordinary flag and is
  not a WASM concern.
- `check` consumes the KEP-0005 diagnostic serializer unchanged; its
  `KP4xxx` codes live in the same registry and under the same stability
  policy as every other `KP` code.

## Unresolved questions

1. **Is the canonical form frozen?** Should changes to the
   distinguished-subform table or the 80-column width require a KEP
   amendment (given they re-flow the whole ecosystem), or only a CHANGELOG
   note?
2. **Configurability**: `fmt` is intentionally zero-config. Is that
   permanent, or is a narrow escape hatch (width, or a per-project
   subform-arity override) ever in scope? The zero-config stance is a
   feature; the question is whether to state it as a guarantee.
3. **The stdout/stderr divergence** for `check --diagnostics=json`: is
   stdout the intended stream (differing from run-mode's stderr), and should
   the guide be corrected to match, or the code aligned to run-mode?
4. **Expanding the `check` type/arity table**: how far should `KP4003`
   coverage grow without risking the soundness invariant, and should
   user-library exports (not just built-ins) ever be arity-checked?
5. **Should `fmt` gain a diff mode** (`--diff`) distinct from `--check`, or
   is exit-code-plus-in-place-write the intended minimal surface?
6. **Comment-attachment edge cases** (the #2079 lone-CR-in-comment
   deviation): is the reader's `;`-ends-at-`\n`-only rule the permanent
   contract, or a documented wart to fix?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`, with
   `Requires: KEP-0005` recorded in the index.
2. **Reconcile the dev docs.** Update `fmt.md` to quote the authoritative
   `bodyDistinguished` table (not the illustrative subset), and correct the
   `check --diagnostics=json` stream description (stdout vs stderr) in the
   site guide.
3. **Decide the canonical-form-freeze and configurability questions**
   (Unresolved 1–2) and annotate the style-rules section accordingly.
4. **Cross-link KEP-0005 and KEP-0015** from `check.zig`/`fmt.zig` and this
   KEP so the diagnostic-serializer boundary and the shared-tooling epic are
   discoverable from code.
5. **Publish user-facing guidance** on `kaappi.github.io` tying `fmt`,
   `check`, and `--diagnostics=json` together as the machine-legibility
   toolchain, linking this KEP and KEP-0005.
6. **On acceptance**, triage the remaining questions (Unresolved 3–6) into
   tracked issues so future formatter/linter changes amend this KEP rather
   than the docs alone.
