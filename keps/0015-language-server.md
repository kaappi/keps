# KEP-0015: The Language Server (kaappi-lsp)

| Field | Value |
|-------|-------|
| **KEP** | 0015 |
| **Title** | The Language Server (kaappi-lsp) |
| **Author** | Baiju Muthukadan <baiju.m.mail@gmail.com> |
| **Status** | Draft |
| **Type** | Informational |
| **Target** | `kaappi` core (`src/kaappi_lsp.zig`, `src/lsp_diagnostic.zig`, `build.zig`), `vscode-kaappi`, `kaappi.github.io` |
| **Created** | 2026-08-08 |
| **Requires** | KEP-0005 (The Diagnostic Contract) |
| **Supersedes** | — |

*All code references are pinned to kaappi commit `395e9d6e` (main,
2026-08-08) and were verified directly against source. The LSP has **no
dedicated `docs/dev/` document** — its only prose reference is the site
guide `editors.md` — so this KEP is its first internal spec, and it notes
where that guide overstates the implementation.*

## Summary

Kaappi ships a Language Server Protocol implementation, `kaappi-lsp`, as a
**separate binary** built alongside `kaappi`. It speaks JSON-RPC 2.0 over
stdio and implements six capabilities — full-document sync with push
diagnostics, completion, hover, document symbols, go-to-definition, and
find-references — analyzing each open document with the *real* reader and
compiler rather than a separate parser. It shipped in v0.3.0 (2026-06-23)
and drives the VS Code, Neovim, Emacs, and Helix editor integrations.

This is a retroactive, *as-built* KEP, and it is deliberately **narrow**: the
LSP's diagnostic payload — the JSON `Diagnostic` shape, the stable `KP`
codes, the severity mapping, the `source` field, the JSON escaping — is
**not the LSP's** and is not re-specified here. That is the [KEP-0005](0005-diagnostic-contract.md)
Diagnostic Contract, which the LSP consumes *unchanged* through the single
shared serializer `lsp_diagnostic.zig`. What this KEP owns is everything the
LSP adds on top: the JSON-RPC transport and framing, the six-capability
surface (and the deliberate non-goals), the document/analysis model that
turns open buffers into `diagnostics.Code` values while isolating state
between documents in one shared VM, and the specific, load-bearing
*simplifications* the LSP makes — whole-line diagnostic ranges,
first-error-only publishing, globals-only completion, and document-local,
lexical definition/reference lookup. Recording those keeps the guide's
promises honest and gives the server a baseline to grow from.

## Motivation

The LSP is a ~1,550-line subsystem with its own binary, its own protocol
surface, and four editor integrations — but no internal design doc, and a
user-facing guide that describes a more capable server than the one that
ships. Three reasons to write it down:

- **The KEP-0005 boundary is the whole point, and it should be explicit.**
  The LSP is the strongest example of the Diagnostic Contract paying off:
  `lsp_diagnostic.zig` is a *single* serializer feeding two surfaces
  (`kaappi --diagnostics=json` on the CLI and `publishDiagnostics` in the
  server), specifically so "the LSP must not grow a second one to drift
  against." A KEP that records exactly where KEP-0005 ends and the LSP
  begins makes that reuse a documented invariant rather than an accident one
  refactor could break.
- **The simplifications are real and currently undocumented.** A user
  reading `editors.md` is told the server offers diagnostics, completion of
  "all 600+ built-in procedures and your definitions," and "jump to where a
  symbol is defined." The shipped server publishes only the *first* failing
  form, highlights the *whole line* rather than the precise span, completes
  from `vm.globals` only (not document-local lexical bindings), and resolves
  definitions/references **only within the current document** by lightweight
  lexical scanning. These are reasonable scoping choices, but they are
  invisible until a user hits them.
- **State isolation in a shared-VM server is subtle and worth capturing.**
  The server analyzes every document in one long-lived VM, and had to grow
  machinery (macro-table snapshot/restore, imported-global pruning, output
  redirection to a discard sink) to stop one open document's `define-syntax`
  or `(display …)` from leaking into another's analysis or corrupting the
  JSON-RPC stream. That is exactly the kind of design lesson a KEP should
  preserve.

## Guide-level explanation

`kaappi-lsp` is a standalone binary that any LSP-capable editor launches and
talks to over stdin/stdout:

```jsonc
// The editor spawns `kaappi-lsp` and exchanges Content-Length-framed JSON-RPC:
initialize → initialized → textDocument/didOpen → …feature requests… → shutdown → exit
```

In VS Code (the `kaappi-scheme` extension), that launch is automatic; other
editors point their LSP client at the `kaappi-lsp` command. What you get:

- **Live diagnostics** as you type — parse, compile, and macro-expansion
  errors, shown with the same `KP` codes and messages as `kaappi check`.
- **Completion** of names in scope — built-in procedures and syntax, plus
  anything the file's own `import`s bring in.
- **Hover** showing a symbol's type and arity (e.g. `procedure`,
  `Arity: 2`).
- **Outline / breadcrumbs** from top-level `define`s and friends.
- **Go-to-definition** and **find-references** for top-level names in the
  current file.

Two things to understand about scope, because the server is intentionally
modest:

1. **Diagnostics are first-error-only and whole-line.** The server reports
   the first form that fails and highlights its whole line, rather than the
   exact sub-expression. (The CLI `--diagnostics=json` path can emit precise
   spans and every error; the editor path trades that for simplicity.)
2. **Definition and references are same-file and lexical.** They scan the
   open document's text; they do not follow `import`s or cross files, and
   references matches every lexical occurrence of the name without scope
   analysis.

Syntax highlighting is *not* the LSP's job — in VS Code it comes from a
TextMate grammar shipped in the extension; the LSP provides the semantic
features. Formatting is also separate: `kaappi fmt` is wired as an editor
filter, not an LSP `textDocument/formatting` handler.

## Reference-level design

### Binary, transport, framing

`kaappi-lsp` is its own executable (`build.zig:394`, 64 MB stack, installed
beside `kaappi`); there is **no `kaappi lsp` subcommand** (`cli_spec.zig`
has no `lsp` entry). Its `main` (`kaappi_lsp.zig:1075`) owns a VM and a
read-dispatch loop. Transport is **JSON-RPC 2.0 over stdio** with LSP
`Content-Length` framing: `readMessage` (`:121`) reads headers to
`\r\n\r\n`, parses `Content-Length`, and reads the exact body;
`writeMessage` (`:196`) emits the framed reply; logging goes to fd 2. Bodies
are parsed with `std.json.parseFromSlice` (`:1174`; the hand-rolled JSON was
replaced per #1066/#1091). `writeAll` retries short/`EINTR` writes because a
partial frame desynchronizes all later framing. On Windows,
`platform.initStandardStreams()` prevents `\n`→`\r\n` rewriting; on OpenBSD
the server raises its stack limit best-effort because it compiles user code
on the main thread. The advertised server version is a hardcoded `"0.1.0"`,
decoupled from the kaappi release.

### Capability surface

Server capabilities are a static `initialize_result` JSON string
(`kaappi_lsp.zig:40`): `textDocumentSync: 1` (Full), `completionProvider`
(no resolve, no trigger chars), `hoverProvider`, `documentSymbolProvider`,
`definitionProvider`, `referencesProvider`. Dispatched methods
(`:1200`–`:1243`):

| Method | Handler | Behaviour |
|---|---|---|
| `initialize` / `initialized` | `handleInitialize` (`:325`) | Handshake; sets `initialized`. A request before `initialize` gets `-32002`. |
| `shutdown` / `exit` | inline | Respond `null`; break the loop. |
| `textDocument/didOpen`, `didChange` | `handleDidOpenOrChange` (`:662`) | Replace stored text, run diagnostics, publish. |
| `textDocument/didClose` | inline (`:1217`) | Drop the document, publish an empty diagnostics array. |
| `textDocument/completion` | `handleCompletion` (`:329`) | Prefix-filtered globals. |
| `textDocument/hover` | `handleHover` (`:369`) | Type + arity. |
| `textDocument/documentSymbol` | `handleDocumentSymbol` (`:415`) | Top-level definitions. |
| `textDocument/definition` | `handleDefinition` (`:499`) | Same-file `define`* location. |
| `textDocument/references` | `handleReferences` (`:573`) | Lexical token scan. |

Unknown method with an id → `-32601`. **Not implemented** (neither
advertised nor handled): formatting/range/on-type formatting,
`semanticTokens`, `signatureHelp`, `rename`/`prepareRename`, `codeAction`,
`foldingRange`, `workspace/symbol`, `inlayHint`, `callHierarchy`, completion
`resolve`, `didSave`, and pull `textDocument/diagnostic` (diagnostics are
push-only).

### The KEP-0005 boundary (what the LSP does *not* own)

`lsp_diagnostic.zig` is the single serializer shared with
`kaappi --diagnostics=json` (#1505). Its header states the intent: one
implementation, two surfaces, "the LSP must not grow a second one to drift
against." Everything in it is the **Diagnostic Contract** (KEP-0005) and is
consumed unchanged:

- the `Diagnostic` object (`range`, `severity`, `code`, `source`,
  `message`, and `data.suggestions`);
- the stable `KP` codes (e.g. `KP3001`) via `diagnostics.Code`;
- the `Severity` mapping (registry err/warning → LSP 1/2/3/4);
- the `source = "kaappi"` field;
- `writeJsonString`, the byte-identical JSON escaper also used by
  `kaappi explain --json` and `kaappi features --json`.

This KEP re-specifies none of that. It references KEP-0005 as `Requires`.

### What the LSP *adds* on top of the contract

Three deliberate LSP-only choices sit above the shared serializer:

1. **Whole-line ranges.** `addDiagnostic` (`kaappi_lsp.zig:1018`) builds the
   `Diagnostic` from a `diagnostics.Code` using `code.render()`,
   `code.info().severity`, and `code.message()`, but **hard-codes the range
   to the entire line** (character `0..999`, `:1021`) rather than the
   span-accurate `spanRange` the CLI can emit. The comment marks this
   intentional — a whole-line highlight for editors.
2. **No suggestions in the editor path.** The LSP never populates
   `data.suggestions`, though the shared object supports it and the CLI
   emits it.
3. **First-error-only publishing.** `runDiagnostics` stops at the first
   failing form (`:789`; `diagnoseTopLevelForm` returns `stop`, #1980),
   unlike the CLI which reports all. This is a known limitation with
   disabled-but-tracked test assertions.

### Document and analysis model

Documents are held in `documents: StringHashMap([]const u8)` (`:241`),
keyed by URI, text duped on store. Sync is **full-text only**
(`textDocumentSync: 1`): every didOpen/didChange replaces the whole buffer
and re-analyzes — no incremental parsing.

Analysis runs the **real reader and compiler**, mirroring `kaappi check`'s
`checkForm` and sharing the `TopLevelHead` machinery so LSP, `check`, and
the CLI cannot drift (#2114). `runDiagnostics` (`:694`) reads form by form;
`diagnoseTopLevelForm` (`:931`) splices top-level `begin`/selected
`cond-expand`, **executes** env-setup heads
(`import`/`define-library`/`include`/`define-record-type`) via
`vm.runTopLevelHead` so later forms see their bindings and macros (needed so
imported macros like SRFI-42 `list-ec` expand), and compiles-but-discards
everything else via `compiler.compileExpressionWithMacrosAt`. Error codes
come from `diagnostics.readErrorCode` / `compileErrorCode` /
`runtimeErrorCode`.

**State isolation in one shared VM** is the subtle part. Because a single
long-lived VM analyzes every document, each run:

- resets `vm.macros` to a startup `baseline_macros` snapshot so one
  document's top-level `define-syntax` does not leak into another (#1979);
- prunes imported globals back to `baseline_global_keys`
  (`pruneImportedGlobals`, `:817`);
- redirects output from executed forms to a discard sink port
  (`beginOutputRedirect`, `:890`) so a stray `(display …)` cannot corrupt
  JSON-RPC framing.

Library paths mirror `main.zig` (the document's own directory, then
`~/.kaappi/lib`, then `<exe>/../lib`); `file://` URIs are percent-decoded by
`fileUriToPath` (`:839`).

### Navigation features (lightweight, not the compiler)

Unlike diagnostics, the navigation features use shallow datum parsing:

- **documentSymbol** (`:415`) re-reads datums and matches
  `define`/`define-syntax`/`define-record-type`/`define-library` heads,
  emitting SymbolKind 13/12/14/23/4 at line granularity (character always
  0).
- **definition** (`:499`, `findDefineLocation` `:542`) scans top-level
  `define`* for a matching name — **same document only**, no cross-file or
  import resolution; returns line, character 0.
- **references** (`:573`) is a pure lexical token scan of the document text
  (skipping strings and `;` comments), matching whole symbols with precise
  columns — **current document only, no scope analysis** (every lexical
  occurrence).

### Completion and hover data source

- **Completion** (`:329`) iterates the **live `vm.globals`** — built-in
  procedures and syntax plus whatever the document's executed `import`s
  added this run — filtered by the prefix under the cursor, with
  CompletionItemKind by type (procedure→Function, syntax→Keyword,
  else→Variable). It does **not** complete the document's own local/lexical
  bindings, and it is not a static `primitives_list.zig` list.
- **Hover** (`:369`) looks the full symbol up in `vm.globals`; if absent,
  returns `null`. It renders `**<typeName>** ` `` `<symbol>` `` plus
  `Arity: N`/`N+` from the live value. There is **no docstring/description
  database** — hover is type + arity only.

### Editor integration and formatting

The VS Code extension (`vscode-kaappi`, `kaappi-scheme` v0.1.0) launches the
server via `vscode-languageclient` with `command: kaappi.lspPath` (default
`kaappi-lsp`), `transport: stdio`, for language id `scheme` (`.scm .sld .ss
.sls`). Syntax highlighting is a separate TextMate grammar
(`source.scheme`); the LSP supplies semantics. **Formatting is not an LSP
feature** — `kaappi fmt` is wired as an editor filter (Vim `:%!kaappi fmt`,
Helix `formatter`, VS Code run-on-save); there is no LSP↔`fmt` code path.

### Tests

`tests/scheme/lsp/lsp.sh` is an end-to-end driver: it spawns the real
`kaappi-lsp`, feeds framed JSON-RPC, and asserts on framed responses —
covering the advertised capability set, framing correctness, a full session,
protocol edges (pre-initialize requests, unknown methods, malformed
framing), and — importantly — **cross-checks diagnostics against
`kaappi check --diagnostics=json`** to verify the shared serializer. Some
assertions are disabled and tagged `#1980` (first-error-only). Inline unit
tests in `kaappi_lsp.zig` cover the JSON field accessors and id formatting;
those in `lsp_diagnostic.zig` cover the shared serializer (belonging to
KEP-0005).

## Drawbacks

Documenting a young, deliberately-minimal server risks the KEP reading as an
endorsement of its current limits (whole-line ranges, first-error-only,
same-file navigation). Mitigation: the KEP frames each as a *current scoping
choice* with a matching Unresolved question, so expanding one is a visible
amendment, not a contradiction.

There is also overlap risk with KEP-0005: an as-built LSP KEP could
accidentally re-specify the diagnostic shape and create exactly the "second
implementation to drift against" the code warns about. Mitigation: this KEP
declares `Requires: KEP-0005` and explicitly disclaims ownership of the
diagnostic payload, owning only the transport, capability surface, analysis
pipeline, and the three LSP-only additions.

## Alternatives considered

- **Leave it to the site guide `editors.md`.** Rejected: that guide is
  user-facing and currently *overstates* the server (completion scope,
  cross-file navigation, all-errors diagnostics). An internal KEP both
  records the real contract and gives a checklist to correct the guide.
- **Fold the LSP into KEP-0005 (Diagnostic Contract).** Tempting, since
  diagnostics are the LSP's main output. Rejected: KEP-0005 is a
  cross-surface *data contract*; the LSP is a *protocol server* with
  completion, hover, navigation, a document store, and shared-VM isolation
  that have nothing to do with diagnostics. The clean split is "KEP-0005
  owns the payload, KEP-0015 owns the server," expressed via `Requires`.
- **Fold it into KEP-0004** (Discoverable Deviations) or a future `check`/`fmt`
  tooling KEP. Rejected: `kaappi check` shares the LSP's `TopLevelHead`
  analysis path and is a natural sibling, but `fmt` has no LSP relationship
  at all, and bundling three tools would blur three distinct surfaces. A
  separate `check`/`fmt` KEP can cross-reference this one.
- **Wait until the server is more capable.** Rejected: the value now is
  precisely to pin the *boundary* with KEP-0005 and to make the current
  simplifications explicit before the guide's overstatements calcify into
  assumed behaviour.

## Cross-platform / compatibility impact

Documentation only; no behavioural change. Recorded facts:

- `kaappi-lsp` is built for every platform kaappi targets (including a
  cross-compiled `kaappi-lsp.exe`); Windows stream init and the OpenBSD
  stack-limit bump are platform accommodations for stdio framing and
  main-thread compilation.
- The wire protocol is standard JSON-RPC 2.0 / LSP over stdio, so any
  conformant client (VS Code, Neovim, Emacs, Helix) interoperates; the
  advertised capability set is the six providers above.
- The LSP consumes the KEP-0005 diagnostic serializer unchanged; the only
  editor-path divergences are whole-line ranges, absent suggestions, and
  first-error-only publishing.
- The server is not affected by `--sandbox` (it is its own binary, not a
  `kaappi` run) and is not built for WASM.

## Unresolved questions

1. **Span-accurate diagnostics in the editor path**: should the LSP adopt
   the `spanRange` precision the CLI already emits, instead of whole-line
   ranges? (Purely an LSP-side change; the KEP-0005 payload already carries
   spans.)
2. **All-errors publishing**: is first-error-only (#1980) a permanent
   scoping choice or a tracked limitation to lift? The disabled test
   assertions suggest the latter.
3. **Cross-file navigation and imports**: should definition/references
   follow `import`s and span files, and should references gain scope
   analysis rather than lexical matching?
4. **Completion of local bindings and richer hover**: should completion
   include document-local lexical bindings, and should hover gain a
   docstring/description source beyond type + arity?
5. **`didSave`, `codeAction` (to surface the `data.suggestions` the
   contract already carries), and `semanticTokens`**: which, if any, are
   in scope, and does exposing suggestions as code actions belong here or in
   KEP-0005?
6. **Version decoupling**: the server advertises a hardcoded `0.1.0`
   independent of the kaappi release. Should the server and the VS Code
   extension version track the core release, or stay independent?

## Implementation plan

Retroactive; no code changes. Process and documentation steps:

1. **Land this KEP as Draft** for review against pinned `395e9d6e`, with
   `Requires: KEP-0005` recorded in the index.
2. **Correct `editors.md`** to match the shipped server: completion scope
   (globals + imports, not local lexical bindings), same-file lexical
   navigation, and first-error-only whole-line diagnostics — or, if any of
   those are slated to change soon, note them as forthcoming.
3. **Write the first `docs/dev/lsp.md`** seeded from this KEP's reference
   section (the LSP currently has no dev doc), and link it back here.
4. **Decide the diagnostic-precision and all-errors questions**
   (Unresolved 1–2), since both are LSP-side only and already have partial
   test scaffolding.
5. **Cross-link KEP-0005** from `lsp_diagnostic.zig` and this KEP so the
   shared-serializer boundary is discoverable from code.
6. **On acceptance**, triage the navigation, completion/hover, and
   capability-expansion questions (Unresolved 3–6) into tracked issues so
   future LSP growth amends this KEP rather than the guide alone.
