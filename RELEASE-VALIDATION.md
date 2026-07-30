# Release validation receipt

Release: `0.7.11`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.11 removes a fail-closed deadlock in staged durable review. A current
milestone could legitimately retain P0/P1 findings assigned to later declared
stages, which correctly prevented final main-owner acceptance. The next
milestone also required that unavailable final acceptance, so the declared
sequence could not progress.

The fix adds an append-once scope-transition authorization before activation.
It pre-binds the run, previous milestone, exact next milestone, selection and
checkpoint, controller material, scope key, source set, and conserved finding
counts. Activation must consume that exact earlier authorization.

Every prior open occurrence remains bound to its source/thread, source finding
ID, canonical ID, severity, exact text, and text hash. Only same-source reviewed
occurrences may become resolved; the rest remain open. Scoped progression is
not final main-owner acceptance, does not validate the main node, and never
satisfies completion.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, or journal.

## Fixed functional candidate

Functional commit:
`93bcec0d1fb3088eb86c4ae98847225731ba6abe`

Parent:
`0afc97a729054215b241df85031c79356022ead6`

The fixed Skill contains 67 files.

Candidate archive:
`adaptive-agent-orchestrator-v0.7.11-candidate-93bcec0.zip`

Candidate archive SHA-256:
`9b98348b256ecee18d920d78bb0c95110178cf13cb6ba493f701132b7d7d2afc`

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 48
- Recovery-protocol focused assertions: 66 passed
- Durable-milestone/revision focused assertions: 91 passed
- Self-test assertions: 799 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 104
- `git diff --check`: passed with line-ending warnings only
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same read-only Noether reviewer dynamically re-attacked fixed functional
commit `93bcec0` and candidate archive SHA-256
`9b98348b256ecee18d920d78bb0c95110178cf13cb6ba493f701132b7d7d2afc`.
The final disposition was GREEN with P0=0, P1=0, and P2=0.

The reviewer verified the legal preauthorization-to-activation path and eight
adjacent fail-closed boundaries. Missing or empty authorization, cross-run or
cross-milestone reuse, selection path/content/hash changes, and replacing the
pre-bound scope key or controller material in the later activation were all
rejected before journal mutation.

The review did not claim resistance to coherent rewriting of the earlier
authorization event and every later history entry. That remains outside the
local append-only threat model.

## Real adoption

The installed candidate was exercised against the real multi-divination
37-event control run without modifying product files or old history:

`C:\Users\Administrator\Documents\主task\orchestration-control\multi-divination-v072\runs\multi-divination-liuyao-p1-successor-v076-checkpoint07`

The pre-transition journal head was
`9b4acf9d3cfdd8a29269388fcc7d5be8cc5bdbc92a6a5521792221110898d341`.
The declared Group2 selection and checkpoint were bound to SHA-256:

- selection:
  `ce1ff837c8055045ed4045c4e2b5fd59a4190ab130893e9bc4f06ea9fc7a95d6`
- checkpoint:
  `37d50e92a4ff03df61c7839eb876e7c5e990b91231dba4ed9a6f5b5e5204264d`

The scope-transition authorization succeeded:

- internal receipt hash:
  `63f1abc9ac24f93c2d8138479cbd501997be85b7fca7b50ecc80b23fa0a7b643`
- file SHA-256:
  `e589ec090ee1a097cc40c8ddd007e109ebf8355e94c273dc5f446235d2d35ac0`

Group2 activation succeeded with schema 1.2:

- internal receipt hash:
  `2dc7bd36e331ad0a950028088e7e8e1e97c32685edff169c09b25c355e0601c6`
- file SHA-256:
  `88b70328becf4675a00059ab13e14d7205051aa78c2217c6a3fecbfc431a792c`
- conserved counts: 11 prior, 4 resolved, 7 remaining

The journal appended from 37 to 39 events. Its new head and file SHA-256 were:

- head:
  `6b33d464f06da99494833102c1ed6c0b90f844a1cce02e3844bd989dc1c64510`
- file:
  `aeb0bccd788239d1c5ce579a34e927995198f2ad7b62547ba8419a51096b725d`

Completion intentionally exited 1. It reported five traditional and two
adversarial open P1 occurrences plus missing final main-owner acceptance.
Resolved P1-03 through P1-06 did not reappear. This is
`PASS_EXPECTED_BLOCKED`: staged progression passed while the full method
remained safely blocked by real unfinished work.

The first completion call was denied only because the sandbox could not update
derived `state.json`; the immutable journal did not change. An authorized retry
produced the formal completion result above. No new Orchestrator P0/P1 was
found.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.11.zip`

Archive SHA-256:
`9b98348b256ecee18d920d78bb0c95110178cf13cb6ba493f701132b7d7d2afc`

The archive is the 67-file Skill tree from fixed functional commit `93bcec0`.
Root README files, changelog, release notes, and this validation receipt are
repository documentation and are intentionally outside the installable Skill
archive.

From a fresh extraction:

- PowerShell parse: 48/48
- recovery-protocol assertions: 66
- durable-milestone/revision assertions: 91
- self-test assertions: 799
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- archive content versus commit Git blobs: 67/67

## Installed copy

Installed path:
`C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`

Backup:
`C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-v0.7.11-20260731-021049`

The fixed archive and installed Skill copies matched 67/67 files by exact
SHA-256 with zero missing, extra, or different files. The installed copy passed
48-script parse, 66 focused recovery assertions, 91 milestone/revision
assertions, 799 self-test assertions, 59 rejected invalid cases, strict parsing
of 8 reference JSON files, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- The seven open multi-divination P1 source occurrences are product work, not
  Orchestrator defects.
- Scoped progression cannot replace final main-owner acceptance, validate the
  main node, skip a declared milestone, or make an open P0/P1 disappear.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite the scope authorization event and every later
  retained entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
