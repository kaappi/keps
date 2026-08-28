# KEPs — Kaappi Enhancement Proposals

Design documents for substantial changes to [Kaappi Scheme](https://github.com/kaappi/kaappi)
and its ecosystem. A KEP captures the motivation, design, and trade-offs of a
proposal so the decision and its rationale are recorded in one place.

## When a KEP is needed

Open a KEP for changes that are large, cross-cutting, or hard to reverse:

- New runtime subsystems (e.g. an I/O reactor, a new GC strategy).
- Language- or library-surface changes that affect compatibility.
- New core libraries, or changes to the package manager / build model.
- Anything where the design discussion is worth more than the diff.

Routine bug fixes, small features, and docs changes do **not** need a KEP —
just open a pull request on the relevant repo.

## Process

1. **Draft** — copy [`template.md`](template.md) to
   `keps/NNNN-short-title.md`, using the next free four-digit number. Open a PR
   against this repo. Discussion happens on the PR.
2. **Accepted** — once there is consensus, the KEP is merged with status
   `Accepted` and implementation can begin (tracked in the target repo).
3. **Final** — set to `Final` when the implementation has shipped in a
   release *and the document has been reconciled with what shipped*. When
   implementation lands before ratification, the KEP is Accepted
   retroactively with dated as-built amendments, and stays `Accepted` until
   the follow-ups those amendments flag are resolved or explicitly tracked
   in the target repo.
4. **Rejected / Withdrawn / Superseded** — recorded, not deleted, so the
   reasoning survives.

A KEP is a living document until it is `Final`; keep it in sync with the
implementation as the design evolves.

## Status lifecycle

```
Draft ──▶ Accepted ──▶ Final
  │           │
  ▼           ▼
Withdrawn   Rejected / Superseded
```

## Index

| KEP | Title | Status | Target |
|----:|-------|--------|--------|
| [0001](keps/0001-event-loop-reactor.md) | Event-Loop Reactor for Fiber I/O | Final (amended 2026-08-27: as implemented in v0.15.0; Q5 native-frame residual open — see its As-implemented section) | `kaappi` core |
| [0002](keps/0002-cross-thread-channels.md) | Cross-Thread Channels and Multi-Core Fiber Scheduling | Accepted (amended 2026-07-16: §6 capacity-0 rendezvous; amended 2026-08-27: as-implemented reconciliation — channel-identity divergence kaappi#2394 and join-notify kaappi#2395 open; amended 2026-08-28: channel identity resolved via kaappi#2397, join-notify still open) | `kaappi` core, `(kaappi parallel)` |
| [0003](keps/0003-shared-flat-numeric-data.md) | Shared Flat Numeric Data | Draft (gated — evaluated Between, 2026-07-16) | `kaappi` core, `(kaappi parallel)` |
| [0004](keps/0004-discoverable-deviations.md) | Discoverable Deviations from R7RS-small | Accepted (amended 2026-08-28: Phase 2 gate cleared but identifier unshipped; naming and ship-gate questions resolved) | `kaappi` core, `kaappi.github.io` |
| [0005](keps/0005-diagnostic-contract.md) | The Diagnostic Contract | Accepted | `kaappi` core, `kaappi.github.io` |
| [0006](keps/0006-explicit-renaming-macros.md) | Explicit-Renaming Macros (er-macro-transformer) | Accepted (amended 2026-08-27: as implemented in v0.22.0; `compare`, `check`/`--sandbox`, and gc-stress follow-ups open — see its As-implemented section) | `kaappi` core |
| [0007](keps/0007-full-syntax-case-support.md) | Full syntax-case Support (Deferred) | Draft (Informational) | `kaappi` core |
| [0008](keps/0008-shared-ir-contract.md) | A Shared IR Contract for kaappi, paal, and chaaya | Draft | `kaappi` core, `paal`, `chaaya` |
| [0009](keps/0009-version-library.md) | A `(kaappi version)` Library for SemVer 2.0.0 | Draft | `kaappi` core, `kaappi.github.io` |
| [0010](keps/0010-llvm-native-backend.md) | The LLVM Native Backend | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0011](keps/0011-ffi-and-sandbox.md) | The FFI Subsystem and the Sandbox Boundary | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0012](keps/0012-thottam-package-manager.md) | thottam — The Package Manager | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0013](keps/0013-wasm-target.md) | The WebAssembly (wasm32-wasi) Target | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0014](keps/0014-sbc-bytecode-format.md) | The `.sbc` Bytecode File Format and Compile Cache | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0015](keps/0015-language-server.md) | The Language Server (kaappi-lsp) | Draft (Informational) | `kaappi` core, `vscode-kaappi`, `kaappi.github.io` |
| [0016](keps/0016-fmt-and-check.md) | The Canonical Formatter (kaappi fmt) and Static Linter (kaappi check) | Draft (Informational) | `kaappi` core, `kaappi.github.io` |
| [0017](keps/0017-gc-and-value-model.md) | The Value Representation and Per-Heap Garbage Collector | Draft (Informational) | `kaappi` core |
| [0018](keps/0018-macro-expander-hygiene.md) | The Macro Expander — Expansion Algorithm and Hygiene Mechanism | Draft (Informational) | `kaappi` core |
| [0019](keps/0019-reader.md) | The Datum Reader | Draft (Informational) | `kaappi` core |
| [0020](keps/0020-ir-and-bytecode-emission.md) | The IR Pipeline and Bytecode Emitter | Draft (Informational) | `kaappi` core |
| [0021](keps/0021-bytecode-vm.md) | The Register-Based Bytecode VM | Draft (Informational) | `kaappi` core |

## License

MIT — see [LICENSE](LICENSE).
