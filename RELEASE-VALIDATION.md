# Release validation receipt

Release: `0.7.7`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.7 is a backward-compatible capture and receipt patch. Current Codex
`read_thread` JSON uses `thread.id`; the prior parser accepted only historical
`thread.threadId` or top-level `threadId`.

The patch accepts all three shapes, requires every concurrently present value
to match exactly, and rejects empty, conflicting, or case-different identities
before a receipt is written. It also prevents PowerShell from scalarizing a
single legacy finding before schema 1.2 receipt generation.

The orchestration policy remains `0.7.6`. No plan, run, journal, lifecycle, or
completion contract changed, so an existing `0.7.6` run requires no policy
activation for this patch.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 42
- Capture-compatibility assertions: 13 passed
- Self-test assertions: 724 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- `git diff --check`: passed
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Real adoption

The production multi-divination project files were not modified by the
Orchestrator repair. Two saved raw Codex captures were read without identity
conversion:

- traditional capture SHA-256:
  `ac9b003ea8ae13aa43e77142d521e2b8461093a7ca4288ea55c85279184adec8`
- adversarial capture SHA-256:
  `b72e9afc0d80a9101bee9c44a40abd37f4e4e10fdbc8fc3c89fe9e9f85a8ccb8`

They generated separate schema 1.3 result receipts:

- traditional:
  `821af271652e4c62d3160a248cc2d6609cd3054249d4c021893c0eb49bc2a4ce`
- adversarial:
  `5c7a40caac3fd252e9a0827628186647677c2f4e6ef57a04d72bc3de3a280e50`

They also generated source-specific disposition receipts:

- traditional:
  `ad7a10925d613ea434c7464b82451e001ee90c19f57f81102c1fc7f5d9028958`
- adversarial:
  `a87172a913c3f9c251914d388b1003592329721ce7a523cc6905825d8f1a38aa`

One misspelled milestone ID was rejected before output and then corrected. It
was classified as caller error, not an Orchestrator defect.

The adoption also confirmed that receipts do not authorize retroactive
lifecycle history. Work performed before a journaled launch/running sequence
cannot be backfilled as if the events had occurred earlier.

## Independent acceptance

The first fixed candidate, `d95f48b`, passed all thread-identity attacks but
received RED because the reviewer independently reproduced the single-finding
scalarization defect. The minimal follow-up commit `628929a` fixed that defect.

The same independent Noether reviewer re-attacked the fixed archive and
returned GREEN:

- P0: 0
- P1: 0
- P2: 0
- dynamic identity attacks: 27/27 passed
- real captures: 2
- valid identity shapes: 7
- rejected conflict/empty/mismatch attacks: 16
- single-finding schema 1.2 receipt: generated, parsed as a one-element array,
  and hash-verified

## Fixed Skill archive

Functional commit:
`628929a52b343885dc154dbdd81380430e3fca40`

Parent thread-identity fix:
`d95f48bec986965a2d3d139e47312603bd3df5cb`

Archive:
`adaptive-agent-orchestrator-v0.7.7.zip`

Archive SHA-256:
`9aad68389517e9284235f9fafd00c0e3433ba3f9ab1dc91636ce6e2729fd2480`

The archive contains 61 Skill files. The reviewer confirmed 61/61 files against
the fixed commit. The installed copy also matched the source 61/61 by SHA-256
and passed the same parser, self-test, JSON, and Skill Creator gates.

Root README files, changelog, release notes, and this receipt are repository
documentation and are intentionally outside the installable Skill archive.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not permit retroactive lifecycle records or reopen a cancelled node.
- It does not migrate business artifacts or claim measured Token savings.
- The local hash chain does not resist an attacker who can rewrite every
  retained anchor and later record.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
