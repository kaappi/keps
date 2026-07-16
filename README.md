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
3. **Final** — set to `Final` when the implementation has shipped in a release.
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
| [0001](keps/0001-event-loop-reactor.md) | Event-Loop Reactor for Fiber I/O | Final | `kaappi` core |
| [0002](keps/0002-cross-thread-channels.md) | Cross-Thread Channels and Multi-Core Fiber Scheduling | Accepted | `kaappi` core, `(kaappi parallel)` |
| [0003](keps/0003-shared-flat-numeric-data.md) | Shared Flat Numeric Data | Draft (gated — evaluated Between, 2026-07-16) | `kaappi` core, `(kaappi parallel)` |
| [0004](keps/0004-discoverable-deviations.md) | Discoverable Deviations from R7RS-small | Accepted | `kaappi` core, `kaappi.github.io` |
| [0005](keps/0005-diagnostic-contract.md) | The Diagnostic Contract | Accepted | `kaappi` core, `kaappi.github.io` |

## License

MIT — see [LICENSE](LICENSE).
