# Release validation receipt

Release: `0.7.10`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.10 closes two fail-closed gaps in repeated durable review.

First, a source that adopted an earlier checkpoint may enter `result_pending`
for a different checkpoint/input only through an unused schema 1.2 attempt-1
recovery cycle bound to the same run, source, role, thread, and active
milestone. Ordinary `adopted` remains terminal.

Second, before the first declared milestone advances, a pre-authorized revision
may re-arm every required read-only source once and select one exact set of
fresh cumulative results. Authorization fixes the only selection identity
before results exist. Selection conserves each prior source finding occurrence
by source ID, severity, exact text/hash, and canonical ID. Completion reads only
the terminal valid selection; open P0/P1 and missing main acceptance remain
blockers.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, or journal.

## Fixed functional candidate

Functional commit:
`cbf98d4ab1bfc48fb65008a2f13ca0aa492d8e5a`

Parent:
`9321bd414469f60a60558716cae98e3dd46a1e36`

The fixed Skill contains 66 files.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 47
- Recovery-protocol focused assertions: 66 passed
- Durable-milestone/revision focused assertions: 79 passed
- Self-test assertions: 787 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 60
- `git diff --check`: passed
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same read-only Noether reviewer dynamically re-attacked fixed functional
commit `cbf98d4` and candidate archive SHA-256
`413888a0e5b628401fdfbb62dac9fb9817058d2521f1f2c40915fc8ca4f0d4dd`.
The final disposition was GREEN with no blocking finding.

The reviewer confirmed that authorization pre-binds the only permitted
selection identity; a caller cannot choose or re-sign another identity after
results exist. Missing, empty, case/prefix-mutated, cross-run, or cross-revision
selection keys fail closed. Existing recovery, milestone, completion, and
history-tamper boundaries remain in force.

## Real adoption

The installed candidate was exercised against the real multi-divination
control run without modifying product files:

`C:\Users\Administrator\Documents\主task\orchestration-control\multi-divination-v072\runs\multi-divination-liuyao-p1-successor-v076-checkpoint07`

The original 27-event run created revision
`a19386b09506bb173ba3656524f09a3edc3beabbfd765c907c104903bfe75474`,
then re-armed the original traditional and adversarial read-only sources. Both
returned fresh formal PASS results with no new P0/P1/P2, and each produced
source-specific schema 1.3 result/disposition evidence followed by
`completed -> validated -> adopted`.

One selection chose checkpoint10 SHA-256
`22e0e6c86b90d273d3d7929c764eafdbc72c92f570f49ef22eed8dc474ae966c`:

- selection internal/event hash:
  `e969fe49bd02588d9ca9d6abcd6882e0a3935d7a15309c3700161dd0f28e7ca9`
- selection file SHA-256:
  `ba8431b466715cb57b4d5e2065d05b653610d6731c1120f060959c0104f5c7be`
- final event count: 37
- final journal file SHA-256:
  `412a0e68bc55697d232411ff766a5e4b5035c76f7e71cf8036cc06b28517bdf3`

Completion intentionally exited 1 because fresh main-owner acceptance was still
absent and 11 later P1 source occurrences remained open. It reported zero P0,
did not revive resolved older findings, and did not treat either source as a
substitute for the other. Product development then advanced to the next group.
No new Orchestrator P0/P1 was found.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.10.zip`

Archive SHA-256:
`413888a0e5b628401fdfbb62dac9fb9817058d2521f1f2c40915fc8ca4f0d4dd`

The archive was generated from fixed functional commit `cbf98d4` with
`git archive` and contains 66 Skill files. After line-ending normalization,
archive content matched the 66 Git blobs 66/66. From a fresh extraction:

- PowerShell parse: 47/47
- recovery-protocol assertions: 66
- durable-milestone/revision assertions: 79
- self-test assertions: 787
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed

Root README files, changelog, release notes, and this receipt are repository
documentation and are intentionally outside the installable Skill archive.

## Installed copy

Installed path:
`C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`

Backup:
`C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-cbf98d4-20260730-232957`

The fixed ZIP and installed Skill copies matched 66/66 files by exact SHA-256
with zero missing, extra, or different files. The Windows working tree differed
in raw bytes for 36 text files because of CRLF checkout conversion; after
stripping trailing CR, all 66 files matched the fixed ZIP. The installed copy
passed 47-script parse, 66 focused recovery assertions, 79 milestone/revision
assertions, 787 self-test assertions, 59 rejected invalid cases, strict parsing
of 8 reference JSON files, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- The 11 open multi-divination P1 source occurrences are product work, not
  Orchestrator defects.
- Recovery cycles do not permit replacement-of-replacement or relax P0/P1
  completion gates.
- A first-milestone revision cannot advance or impersonate a later milestone,
  replace one required source with another, or substitute selection for fresh
  main-owner acceptance.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite every retained anchor. That threat requires an
  external WORM, signature, or remote log anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
