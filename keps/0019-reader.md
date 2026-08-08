# KEP-0019: The Datum Reader

| Field | Value |
|-------|-------|
| **KEP** | 0019 |
| **Title** | The Datum Reader |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/reader.zig`, `src/reader_tokens.zig`, `src/reader_datum.zig`, `src/primitives_io.zig`, `src/types.zig`) |
| **Created** | 2026-08-08 |
| **Requires** | — |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. `docs/dev/architecture.md`
describes the reader in one row (with slightly stale line counts, noted
below); there is no dedicated reader dev-doc. This KEP is the interpreter's
reader; the formatter has a separate concrete-syntax reader owned by
[KEP-0016](0016-fmt-and-check.md).*

## Scope

This KEP specifies the **interpreter's datum reader** — the Reader stage of
`Source → Reader → Expander → IR` — its grammar, its lexer/parser
architecture, datum-label handling, source-span tracking, the `read`
procedure, and its error *conditions*. It defers, by reference:

- **Value representation** (how symbols/pairs/numbers are heap-allocated,
  interned, NaN-boxed) → [KEP-0017](0017-gc-and-value-model.md). The reader
  constructs values; it does not define them.
- **The numeric tower internals** (bignum/rational/complex construction) →
  the arithmetic/numeric modules. The reader *tokenizes and validates*
  numeric syntax and *delegates* value construction; that boundary is
  recorded here but the tower itself is not specified.
- **Diagnostic code shape** (the `KP1xxx` codes and JSON) →
  [KEP-0005](0005-diagnostic-contract.md). The reader supplies only its
  `ReadError` conditions and a detail string.
- **Macro expansion / hygiene** → [KEP-0018](0018-macro-expander-hygiene.md).
  The reader produces plain data; hygiene is downstream.
- **The formatter's separate CST reader** (`fmt.zig`) →
  [KEP-0016](0016-fmt-and-check.md). Kaappi deliberately has *two* readers;
  this is the interpreter's.

## Summary

Kaappi's reader is a **lexer + recursive-descent parser** split across three
files (`reader.zig`, `reader_tokens.zig`, `reader_datum.zig`) that turns
source text into Scheme data. It implements the full R7RS read grammar —
lists and dotted pairs, vectors, bytevectors, booleans, characters, strings,
the peculiar-identifier and `|piped|` symbol forms, the quote family, line /
nested-block / datum comments, `#!fold-case` directives, and `#N=`/`#N#`
datum labels for shared and circular structure — plus a set of SRFI reader
extensions (SRFI 30/38/62/169/207/267/270) and a deliberate exclusion (SRFI
10 `#,()`). Numbers are tokenized in the reader but their heap values are
built by the arithmetic modules, through the *same* `parseNumberText` that
backs `string->number` so the two cannot diverge. The reader records a
1-based source `Span` per pair/vector into a GC side-table for downstream
diagnostics and the LSP, and drives the Scheme `read` procedure with an
incremental parse loop so interactive and chunked ports return on a complete
datum.

This is a retroactive, *as-built* KEP. It proposes no change. Its value is to
write down the read grammar as one reviewable contract — including the SRFI
extension set, the datum-label cycle-patching algorithm, the reader/number
delegation boundary, the span side-table, and the nesting/token limits —
rather than leaving "what syntax does Kaappi read?" answerable only by
reading three files and a trail of issue numbers.

## Motivation

The reader is the front door to the language and a genuine compatibility
surface, yet it is documented only by one architecture-doc row:

- **The read grammar is a contract programs depend on.** Every SRFI
  extension the reader accepts (raw strings `#"…"`, string-notated
  bytevectors `#u8"…"`, digit separators `_`, hex floats `#x1.2p3`) and
  every one it rejects (SRFI 10 `#,()`, explicitly excluded for safety) is a
  decision that affects what source is valid. There is no numbered record of
  that surface.
- **Two behaviours are subtle and load-bearing.** The datum-label machinery
  (`#N=`/`#N#`) reads genuinely circular structure by pre-allocating a
  placeholder and patching it in place — an algorithm worth recording. And
  number reading *delegates* construction to the same parser as
  `string->number` (#1911), a deliberate anti-divergence design that a naive
  change could undo. Both live only in code.
- **Spans are the input to diagnostics and the LSP.** The reader is where
  `file:line:col` originates: it records a `Span` per pair/vector into a GC
  side-table (#1506) that KEP-0005 diagnostics and the language server
  (KEP-0015) consume. Documenting where positions come from ties the
  tooling story together.
- **The two-reader split deserves to be explicit.** Kaappi has this reader
  *and* the formatter's comment-preserving CST reader (KEP-0016). Recording
  why (the ordinary reader discards comments) prevents the recurring
  confusion of treating them as one.

## Guide-level explanation

The reader turns text into data. From Scheme it is the `read` procedure; in
the interpreter it is the pass that runs before compilation. It accepts the
standard R7RS surface:

```scheme
(a b . c)            ; dotted list
#(1 2 3)             ; vector
#u8(0 255)           ; bytevector
#\newline  #\x3bb    ; named and hex characters
"a\tb\x41;"          ; string with escapes
|weird symbol|       ; piped symbol
'x  `(,y ,@ys)       ; quote / quasiquote / unquote / unquote-splicing
; line comment
#| nested #| block |# comment |#
#;(ignored datum)
#1=(a . #1#)         ; a circular list, read correctly
```

Beyond R7RS it also reads several SRFI extensions — raw strings
`#"DELIM…DELIM"`, string-notated bytevectors `#u8"…"`, digit separators
(`1_000_000`), and hex floats (`#x1.2p3`) — and it honours `#!fold-case` to
switch to case-insensitive symbol reading for the rest of a port. It does
*not* implement SRFI 10 `#,()`, which is deliberately excluded.

Two things worth knowing:

- **Circular and shared structure works.** `#N=` labels a datum and `#N#`
  refers back to it, so genuinely cyclic data reads without looping.
- **`read` is incremental.** Reading from an interactive terminal or a
  chunked port returns as soon as one complete datum is available, refilling
  only when a datum is genuinely unfinished — so a REPL responds on the
  closing paren.

Numbers deserve a note: the reader recognizes the numeric *syntax*
(radixes, exactness, rationals, complex, inf/nan) but hands the actual value
construction to the arithmetic modules — the *same* code path as
`string->number`, so `(read)` and `string->number` always agree.

## Reference-level design

### Architecture

A **lexer + recursive-descent parser** across three files that form one
logical unit:

- `reader.zig` (~1115 lines) — the `Reader` struct, the `Token` union, the
  `ReadError` set, whitespace/comment skipping, and string/symbol scanning.
- `reader_tokens.zig` (~1327 lines) — number, hash-dispatch (`readHash`),
  character, radix, and raw/byte-string tokenizing.
- `reader_datum.zig` (~357 lines) — datum construction (lists, vectors,
  bytevectors, quote forms, datum labels, cyclic patching).

Entry points (`reader.zig`): `Reader.init(gc, source)` and
`initWithName(gc, source, name)` (default source name `"<input>"`);
`nextToken()` (the single token-dispatch entry, resetting the error-detail
buffer and skipping trivia); `readDatum()` and `readDatumOrEof()` — the
latter returning `null` on clean EOF so `read` can yield an eof-object.
There is **no `readAll`**; every driver loops `readDatum` until error or
EOF (file loading, `check`, and the REPL's completeness probe). *(Divergence
to fix: `architecture.md` gives approximate, slightly stale line counts.)*

### Datum grammar

Dispatch is in `nextToken` (`reader.zig:319`) and `readHash`
(`reader_tokens.zig:677`):

- **Lists** `()`, **dotted lists** `(a . b)` — a `.` followed by a delimiter
  is the improper-tail dot; a `.` outside list context is `DotNotInList`.
- **Vectors** `#(…)` and **bytevectors** `#u8(…)` (elements must be fixnums
  0–255), both GC-rooted through `extra_roots` during construction.
- **Booleans** `#t #f #true #false` (the long forms must match exactly and
  end at a delimiter).
- **Characters** `#\x` — single, named (`space newline tab return null alarm
  backspace delete escape`, case-insensitive), `#\xHH` hex (validated
  ≤ 0x10FFFF, non-surrogate), and multibyte UTF-8.
- **Strings** and **symbols** (plain, Unicode, `|piped|`, peculiar) — see
  below.
- **Quote family** `'` `` ` `` `,` `,@` expand to `(quote …)` /
  `(quasiquote …)` / `(unquote …)` / `(unquote-splicing …)`.
- **Comments**: `;` line, `#| … |#` nested block (depth-limited), and `#;`
  datum comments (read-and-discard one datum).
- **Datum labels** `#N=` / `#N#` (see below).
- **Directives** `#!fold-case` / `#!no-fold-case`; other `#!name` directives
  are consumed and ignored (there is **no** `#!default`).

**SRFI reader extensions present**: SRFI 30 (nested block comments), SRFI 38
(datum labels), SRFI 62 (`#;` datum comments), SRFI 169 (digit separators
`_`), SRFI 207 (string-notated bytevectors `#u8"…"`), SRFI 267 (raw strings
`#"DELIM…DELIM"`, no escapes), SRFI 270 (hex floats). **Excluded**: SRFI 10
`#,()` external forms, "deliberately excluded" per `docs/dev/srfi-exclusions.md`
as unscoped reader-macro dispatch.

### Number tokenizing and the delegation boundary

Numbers are tokenized inside the reader (`reader_tokens.zig`) but their heap
values are constructed by other modules at datum-construction time
(`reader_datum.zig:37`): `bignum.parseBignumString`,
`primitives_arithmetic.makeRational*`, `primitives_numeric.parseNumberText`,
`gc.allocComplexEx`. This is the reader/number boundary: **the reader
validates numeric syntax and picks a token variant; the arithmetic/numeric/
bignum modules build the value** (representation → KEP-0017).

- **Radix** `#b/#o/#d/#x` and **exactness** `#e/#i` prefixes (one further
  prefix of the other kind allowed, e.g. `#e#x10`).
- **Exactness handling** routes `#e/#i` bodies through
  `primitives_numeric.parseNumberText` — the **same parser behind
  `string->number`** — so the reader and `string->number` cannot diverge
  (#1911; the older token-level f64→continued-fraction path was removed,
  #1907/#1908/#1909).
- **Tower**: fixnum (promoted to bignum past `i48`), bignum, rational `a/b`,
  flonum, and complex (`a+bi`, `+i`, pure imaginary, radix-prefixed
  `#x1+2i` per R7RS `<complex R>`, #2243), with exact components required to
  round-trip through f64 or raise `InvalidNumber`.
- **inf/nan** (`+inf.0 -inf.0 +nan.0 -nan.0` and `…i` imaginaries), exponent
  markers `e/s/f/d/l` normalized to `e`, SRFI 169 digit separators, and
  SRFI 270 hex floats.
- Prefixed numeric tokens require a trailing delimiter so `#b1p4` is not
  silently split (#1929).

### String and character escapes

**String escapes** (`reader.zig:646`): `\n \r \t \a \b \" \\ \|`; `\xHH…;`
hex scalar → UTF-8; and line-continuation `\<newline>` skipping intraline
whitespace. Any other escape is `InvalidEscape`; an unterminated string is
`UnterminatedString`. Strings read by the interpreter loader are marked
immutable; `read` produces mutable strings. **Piped-symbol escapes** use the
same set plus `\xHH;`, but an unknown escape falls through to a literal byte
rather than erroring. **Raw strings** (SRFI 267) interpret no escapes;
**byte strings** (SRFI 207) take ASCII bytes with `\xHH;` meaning one raw
byte 0–255.

### Symbols

`<initial>` is ASCII alpha or one of `! $ % & * / : < = > ? @ ^ _ ~`;
`<subsequent>` adds digits and `+ - . @`. The reader also accepts Unicode
identifiers (via `unicode_tables.alphabetic_ranges`), `|vertical bar|`
symbols with escapes, and the peculiar identifiers (`+`, `-`, `...`,
sign-subsequent forms like `->foo`), with sign-vs-number disambiguation in
`nextToken`. Case folding, when enabled, is applied per-symbol via a
Unicode-aware `charFoldcase`. Interning is delegated to the symbol table
(KEP-0017).

### Datum labels and cyclic structure

The label table is a fixed `[32]?Value` array on the Reader (labels 0–31; a
larger label is `InvalidNumber`). A definition `#N=`
(`reader_datum.zig:103`) pre-allocates a placeholder pair `(VOID . NIL)`,
roots it, stores it in `labels[n]`, and reads the datum — so forward and
self references resolve to the placeholder. If the datum is a pair, its
car/cdr are copied into the placeholder (write-barriered) and the
placeholder is returned, preserving identity for cycles; otherwise the datum
is stored and `patchPlaceholder` runs. `patchPlaceholder`
(`reader_datum.zig:290`) does an iterative traversal over pairs and vector
slots with an `AutoHashMap` visited-set for O(1) cycle detection, replacing
every placeholder occurrence with the real datum.

### Source spans

The reader tracks byte `pos` only; line/column are computed on demand
(`getLineCol`, an O(n) scan used on error paths). After each datum,
`recordSpan(val, start_pos)` records a 1-based, half-open `types.Span`
(`{line, col, end_line, end_col}`) into `gc.source_spans` (an
`AutoHashMap(Value, Span)`). **Only pairs and vectors are keyed** — they
have heap identity; interned symbols and immediates cannot be (#1506). A
`record_spans` flag disables this for throwaway parses (the REPL
completeness probe) to avoid growing the never-pruned span table. The
compiler copies each span's start line/col into the bytecode line table for
runtime `file:line:col`; end positions are not carried into bytecode. These
spans are what KEP-0005 diagnostics and the LSP (KEP-0015) render.

### The `read` procedure and ports

`read` (and `read-char`, `peek-char`, `read-line`, `read-string`,
`eof-object`, `eof-object?`) are registered in `primitives_io.zig`; there is
**no `read-syntax`** (spans are a side-table, not attached syntax objects).
`readDatumFn` handles two port kinds:

- **String ports**: a `Reader` over the remaining slice (plus any peeked
  byte), seeded with the port's `fold_case`, parses one datum, advances the
  port position, and persists `fold_case` back to the port (#2175).
- **fd/buffered ports**: drains peek/buffer/fd, then runs an **incremental
  parse loop** — parsing with `incomplete_input = true` and refilling on
  exactly `UnexpectedEof`, saving unconsumed bytes back to the read buffer
  (#847, #1893). A whitespace-only buffer is discarded unless a `#!`
  directive was seen.

Clean EOF becomes an eof-object; read errors are raised as error objects with
`error_type = .read` and message `"read error: <detail>"`.

### Error conditions (diagnostic shape deferred to KEP-0005)

The `ReadError` set (`reader.zig:7`): `UnexpectedEof`, `UnexpectedChar`,
`UnexpectedRightParen`, `InvalidNumber`, `InvalidCharacterName`,
`UnterminatedString`, `InvalidEscape`, `DotNotInList`, `NestingTooDeep`,
`TokenTooLong`, `OutOfMemory`. These map to `KP1001`–`KP1010` in
`diagnostics.zig`, but that *code/JSON shape is KEP-0005's* — this KEP owns
only the conditions and the thread-local `read_error_detail` buffer (reset
each token, used to echo the offending token, e.g. "identifiers cannot begin
with a digit"). `UnexpectedEof` doubles as the incremental-refill signal.

Limit constants (`reader.zig:126`): `MAX_NESTING_DEPTH = 1024`,
`MAX_BLOCK_COMMENT_DEPTH = 256`, `MAX_TOKEN_BYTES = 64 KiB`. *(Divergence to
note: the CHANGELOG's "1025 level"/"depth 1023" framing is off-by-one versus
the literal `1024`, and the #2110–2113 prefix-chain overflow fixes are
largely the formatter's reader, KEP-0016.)*

### fold-case

Default is case-sensitive (R7RS). `#!fold-case` / `#!no-fold-case` toggle a
per-Reader flag; folding is applied per-symbol, Unicode-aware. `read` seeds
the flag from the port and writes it back after a successful parse so the
directive persists across `read` calls (#2175), with a `saw_directive` flag
keeping the incremental buffer alive so a directive isn't discarded with
otherwise-blank input.

### Tests

Inline tests in `reader.zig` (integers, booleans, symbols, lists, dotted
pairs, quotes, strings, raw strings, characters, comments, fold-case, datum
labels, prefixed-number delimiter enforcement);
`tests_reader_incremental.zig` (chunk-boundary / `incomplete_input`);
`tests_spans.zig` (span math and reader→IR→bytecode line table); and Scheme
smoke tests under `tests/scheme/smoke/` (token validation, string-port peek,
incomplete datum, dotted-pair datum comment, large bytevector `k`, …).

## Drawbacks

The reader is under steady refinement (recent complex-number and
number-sharing work #2182/#2243, incremental-read hardening #1893/#1940), so
an as-built KEP risks drift. Mitigation: the KEP records the *grammar
surface, the delegation boundary, the datum-label algorithm, and the span
contract* — which change rarely — rather than every token rule, and pins
line references to a commit.

Enumerating the SRFI extension set in a numbered document could read as a
frozen promise. The Unresolved questions treat the accepted/excluded set as
reviewable; the record's purpose is to make *adding or removing* a reader
extension a visible decision rather than a silent grammar change.

## Alternatives considered

- **Leave it to the architecture-doc row.** That row is one line and already
  carries stale line counts; it says nothing about the SRFI set, datum-label
  patching, spans, or the number-delegation boundary. A KEP gives the
  grammar a real home.
- **Fold the reader into KEP-0017 (values) or KEP-0018 (expander).**
  Rejected: the reader is a distinct pass with its own grammar and error
  model; KEP-0017 owns representation and KEP-0018 owns hygiene, and the
  reader precedes both. It references them for the value and downstream
  boundaries.
- **Merge with the formatter's reader (KEP-0016).** Rejected: they are
  deliberately *two* readers — the interpreter's discards comments and
  interns/allocates values; the formatter's preserves comments in a CST and
  never allocates Scheme values. One KEP each keeps the split honest; each
  notes the other.
- **Split "grammar" and "read procedure/ports" into two KEPs.** Rejected as
  over-fragmentation: the incremental parse loop, `fold_case` persistence,
  and the span side-table only make sense alongside the grammar they
  serve.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- The read grammar (R7RS plus the SRFI 30/38/62/169/207/267/270 extensions,
  minus SRFI 10) is identical on all platforms; UTF-8 source and Unicode
  identifiers are handled uniformly.
- Number reading shares `parseNumberText` with `string->number` on every
  platform, so `(read)` and `string->number` agree everywhere.
- Source spans are recorded identically and feed the same diagnostics
  (KEP-0005) and LSP (KEP-0015) surfaces across platforms.
- The nesting (1024), block-comment (256), and token (64 KiB) limits are
  fixed constants, uniform across platforms.
- The reader constructs values via the GC/value model (KEP-0017); it has no
  OS footprint of its own and is unaffected by `--sandbox`/WASM beyond the
  general policies.

## Unresolved questions

1. **Is the SRFI reader-extension set a frozen contract?** Should adding or
   removing an accepted extension (or revisiting the SRFI 10 exclusion)
   require a KEP amendment, or only a CHANGELOG note?
2. **`read-syntax` and attached spans**: spans are a side-table keyed only by
   pair/vector identity. Is a `read-syntax` that attaches positions to *all*
   data (including atoms) ever in scope — and would that require the syntax
   objects KEP-0018/0007 also want?
3. **The datum-label table is fixed at 32 entries.** Is that a permanent
   limit, or should it grow (and would a dynamic table change the
   `InvalidNumber`-on-overflow behaviour programs might rely on)?
4. **The 1024 nesting limit** (and the CHANGELOG off-by-one framing): is the
   literal cap the contract, and should the two readers (interpreter and
   formatter) share one documented limit?
5. **fold-case persistence across `read` calls** (#2175): is per-port
   directive state the intended long-term behaviour, and should it be a
   documented property of `read`?
6. **Span-table growth**: `gc.source_spans` is never pruned. Is that
   acceptable for long-lived readers, or a documented cost worth a lifecycle
   policy?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`.
2. **Correct and expand the docs**: fix the architecture-doc line counts,
   and write the first `docs/dev/reader.md` (grammar, SRFI set, datum-label
   patching, spans) seeded from this KEP's reference section.
3. **Decide the extension-set and datum-label-limit questions**
   (Unresolved 1, 3) and annotate the grammar section accordingly.
4. **Cross-link KEP-0005** (the `KP1xxx` mapping of the reader's conditions),
   **KEP-0016** (the formatter's separate reader), and **KEP-0017** (value
   construction) from `reader.zig` and this KEP.
5. **Reconcile the nesting-limit framing** (Unresolved 4) so the CHANGELOG
   and the literal constant agree, and consider a shared documented limit
   for both readers.
6. **On acceptance**, triage the `read-syntax`, fold-case-persistence, and
   span-lifecycle questions (Unresolved 2, 5, 6) into tracked issues so
   future reader work amends this KEP rather than the scattered fixes.
