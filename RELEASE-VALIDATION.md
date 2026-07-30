# Release validation receipt

Release: `0.7.8`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.8 adds one strict append-only recovery path for a first-generation
durable-review successor that was cancelled before its first durable milestone
and before any review message or result lifecycle.

The old run remains terminal and immutable. A controller first creates an
append-once authorization receipt, then one abandonment export, and finally a
fresh successor adoption. The chain binds the old successor adoption, journal
head/count, cancellation and no-dispatch evidence, checkpoint, ordered
source/role/thread identities, consumed attempts, all inherited and newly added
P1 occurrences, the target plan/run/milestones, and unactivated evidence marked
as ineligible for completion.

The orchestration policy remains `0.7.6`. This patch adds commands under the
existing policy; it does not rewrite an older plan, run, genesis, or journal.

## Fixed functional candidate

Functional commit:
`5a00cb8e97fc23edff3a3d6da0113932dbc5756e`

Parents:

- `e1d0c07` re-derives abandoned-run evidence instead of trusting restated
  caller fields;
- `41ee839` introduces authorization/export/fresh-adoption and attempt carry.

The fixed Skill contains 64 files.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 45
- Abandoned-successor focused assertions: 52 passed
- Self-test assertions: 739 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 100
- `git diff --check`: passed
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same read-only Noether reviewer re-attacked the fixed functional commit and
its 64-file candidate archive:

- P0: 0
- P1: 0
- P2: 0
- PowerShell parse: 45/45
- focused assertions: 52
- self-test assertions: 739
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- Git content comparison: 64/64

The reviewer confirmed that export cannot replace the pre-bound authorization,
source attempts cannot reset, obligations cannot be omitted, downgraded,
merged, or replayed across identity boundaries, and fresh genesis/adoption
cannot satisfy completion.

## Real adoption

The installed candidate was exercised against the real multi-divination
control run without modifying product files or dispatching a review message.

Fresh plan:
`C:\Users\Administrator\Documents\主task\orchestration-control\multi-divination-v072\liuyao-p1-successor-checkpoint07-plan.json`

Plan SHA-256:
`eaaff36420ad76da1b3943cfff1450c91f0ca7494508af78a03fbd1df349db8b`

The authorization, export, and fresh adoption all exited 0:

- authorization internal hash:
  `04224c0cc333046b6843d2de98134792d17a13f37cb8a34ca536d8f80c6ea914`
- abandonment export internal hash:
  `10e602ef1592c717ca8635ed56797e71f1eeff9484f5fde07dc124e783bea9cb`
- fresh adoption internal hash:
  `0a600e698f73a6c96d53366a057366ea563c9a588e546494d7f31b76de603836`

The abandoned journal advanced append-only from 7 events/head
`a786f43221231e58dd98ef28e311d0c2a02abf3e632143548904829e5b59862f`
to 9 events/head
`aa7091dd1417bd10737c3cdf885c42cedc285f26e42056decc3966616294f7e6`.
The old plan and run hashes did not change.

The fresh run has four journal events and head
`15ed372c634a8048347c8760e07e22a1ed13d6e542ccea90107c97c77c47158d`.
Traditional carried attempt 1 and may next launch only as attempt 2;
adversarial carried 0 and may next launch as attempt 1.

Readback preserved exactly 18 P1 source occurrences and zero P0:

- traditional: 12
- adversarial: 6, including distinct finding `LY-ADV-R06-P1-001`

Completion exited 1 and remained `BLOCKED`: three required nodes were not
validated, main evidence was absent, baseline dispositions did not exist, and
all 18 inherited P1 items lacked a current same-source disposition. Old P0 and
old-checkpoint receipts did not re-enter the active chain.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.8.zip`

Archive SHA-256:
`815ea0b03f71bc0d9e88d5646a1c02244736c81cf72d90a63fbfeda7dc74b050`

The archive was generated from the fixed functional commit with `git archive`
and contains 64 Skill files. Windows archive output uses CRLF for text files;
after line-ending normalization, archive content matched the 64 Git blobs
64/64. From a fresh extraction:

- PowerShell parse: 45/45
- abandoned-successor assertions: 52
- self-test assertions: 739
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed

Root README files, changelog, release notes, and this receipt are repository
documentation and are intentionally outside the installable Skill archive.

## Installed copy

Installed path:
`C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`

Backup:
`C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-abandoned-successor-20260730-183858`

The source and installed Skill copies matched 64/64 files by exact SHA-256 with
zero missing or extra files. The installed copy passed 45-script parse, 52
focused assertions, 739 self-test assertions, 59 rejected invalid cases, and
Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- Abandoned-successor recovery is unavailable after a durable milestone,
  acceptance, review dispatch, or result lifecycle has begun.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite the authorization, journal, and every later
  retained anchor. That threat requires an external WORM, signature, or remote
  log anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
