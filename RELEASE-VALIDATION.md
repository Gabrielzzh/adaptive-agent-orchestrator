# Release validation receipt

Release: `0.7.12`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.12 removes a fail-closed block in long-lived durable-source recovery. A
later milestone activation could select a newer same-source result and
disposition without appending another node lifecycle. If that source then lost
its final at a new checkpoint, a valid schema 1.2 cycle could be created, but
`adopted -> result_pending` still inspected the older preceding-milestone node
lifecycle and rejected the recovery.

The fix keeps ordinary `adopted` terminal. The narrow fallback is allowed only
for an unused attempt-1 cycle at a different checkpoint/input after the complete
active milestone chain verifies the same source, role, thread, selected result,
source-specific disposition, activation receipt, and activation journal event.
The appended event binds all of those identities plus the preceding adopted
sequence/hash.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, or journal.

## Fixed functional candidate

Functional commit:
`8e08a2c40d78de9fb2d5a44966ebe0cb9b47b2c4`

Parent:
`ac230fdee1b8ca3d9c862d2e1b80fe2fbc6b930f`

The fixed Skill contains 67 files.

Candidate archive:
`adaptive-agent-orchestrator-8e08a2c40d78de9fb2d5a44966ebe0cb9b47b2c4.zip`

Candidate archive SHA-256:
`963bb1caa3320f8666297815ca14dfcbac59964244a6c94aa28795a5314c87c1`

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 48
- Recovery-protocol focused assertions: 66 passed
- Durable-milestone/revision focused assertions: 102 passed
- Self-test assertions: 810 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 105
- `git diff --check`: passed with line-ending warnings only
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same read-only Noether reviewer dynamically re-attacked fixed functional
commit `8e08a2c40d78de9fb2d5a44966ebe0cb9b47b2c4` and candidate archive SHA-256
`963bb1caa3320f8666297815ca14dfcbac59964244a6c94aa28795a5314c87c1`.
The final disposition was GREEN with P0=0, P1=0, and P2=0.

The reviewer verified the legal active-milestone recovery path and 19 adjacent
attacks. Old milestones or activations, unselected result/disposition files,
cross-source/role/thread substitution, consumed cycles, same-checkpoint replay,
direct attempt 2/3 entry, and selection, activation, checkpoint, or input
tampering were rejected before journal write. Every rejection preserved the
journal length and SHA-256.

The review did not claim resistance to coherent rewriting of the earlier
authorization event and every later history entry. That remains outside the
local append-only threat model.

## Real adoption

The installed candidate was exercised against the real multi-divination
39-event control run without modifying product files or old history:

`C:\Users\Administrator\Documents\主task\orchestration-control\multi-divination-v072\runs\multi-divination-liuyao-p1-successor-v076-checkpoint07`

The exact 39-event prefix remained unchanged at SHA-256:

`aeb0bccd788239d1c5ce579a34e927995198f2ad7b62547ba8419a51096b725d`

The traditional source appended sequence 39,
`adopted -> result_pending`, with event hash:

`ba2d5a30bf235c9adb17303fda43a8caecaae1768e57a1c5e99d8b8a7127b5a4`

It bound the active Group2 source chain:

- result:
  `fce1c8180be5e37173d3fa45b864b75b4dc0bd16073c84ff9e92b73edc07eced`
- disposition:
  `eda01ccdf73fd546d1a2b870c9edf40fd3855c079be55271a1af5d5b90920936`
- activation:
  `2dc7bd36e331ad0a950028088e7e8e1e97c32685edff169c09b25c355e0601c6`
- checkpoint:
  `b2b242c3794ff6822c231a7833838d012813b2277c49b94195242ef1258e2c62`
- input:
  `0e9c211bfca8f085550e7fc596fbf5b8f7544f8900a0d972e109edceb67e248f`

Sequence 40 advanced `result_pending -> running` with hash:

`308b387ff5ca3bdd22b5e82f30585b227443556d1d256af155b36abc727125ab`

The original traditional durable task then returned a formal final, proving the
same-thread recovery entry was usable. Its overall `FAIL` stated that the domain
review itself had not completed its negative cases, regression, and final
rehash; it reported no new product finding. That is unfinished review work, not
an Orchestrator regression or product PASS. Later missing-final observations
remained governed by the existing bounded cycle. Once the attempt-3 receipt
marked that cycle exhausted, no fourth same-thread send was authorized.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.12.zip`

Archive SHA-256:
`963bb1caa3320f8666297815ca14dfcbac59964244a6c94aa28795a5314c87c1`

The archive is the 67-file Skill tree from fixed functional commit `8e08a2c`.
Root README files, changelog, release notes, and this validation receipt are
repository documentation and are intentionally outside the installable Skill
archive.

From a fresh extraction:

- PowerShell parse: 48/48
- recovery-protocol assertions: 66
- durable-milestone/revision assertions: 102
- self-test assertions: 810
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- archive content versus commit Git blobs: 67/67
- Windows working-tree content versus archive after CRLF/LF normalization:
  67/67; raw working-tree bytes are not claimed identical

## Installed copy

Installed path:
`C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`

Backup:
`C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-active-milestone-recovery-20260731-040012`

The fixed archive and installed Skill copies matched 67/67 files by exact
SHA-256 with zero missing, extra, or different files. The Windows repository
working tree matched the archive 67/67 after CRLF/LF normalization; raw
working-tree byte identity is not claimed. The installed copy passed 48-script
parse, 66 focused recovery assertions, 102 milestone/revision assertions, 810
self-test assertions, 59 rejected invalid cases, strict parsing of 8 reference
JSON files, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- The incomplete traditional review final is unfinished domain work, not an
  Orchestrator defect or business PASS.
- An attempt-3 recovery receipt closes that recovery cycle; it does not
  authorize a fourth send. Further work remains blocked or requires a separately
  authorized replacement path.
- Ordinary `adopted` remains terminal without a complete active-milestone
  same-source binding and unused new-checkpoint attempt-1 cycle.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite the activation, selection, and every later retained
  entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
