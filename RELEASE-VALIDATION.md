# Release validation receipt

Release: `0.7.15`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.15 repairs one exact durable-review lifecycle evidence error. Both
required sources had a correct `completed` result pointer and a correct
`adopted` disposition pointer, but each `validated` event repeated the result
pointer. Immutable history could not be edited, completed reviewers should not
be rerun, and selection correctly failed closed.

The patch adds one whole-source, append-only lifecycle correction receipt and
journal event. It binds the run, plan, genesis, pending revision, pre-bound
selection key, source journal head/count, checkpoint/input, exact source,
role/task identities, exact completed/validated/adopted sequence and hash, and
the selected result/disposition path, internal hash, and file hash.

Correction changes no node state, finding decision, reviewer task, or original
event. Selection and completion must validate both the old events and the
correction.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, recovery receipt, or journal.

## Fixed functional candidate

Series base:
`1f166efa4aacc04117747a89345dfaf32f852a75`

Functional commit:
`7cba32babbc95cc095065468dee0cb486c09842a`

The fixed installable Skill contains 73 files.

Independently reviewed archive:
`adaptive-agent-orchestrator-revision-lifecycle-correction-7cba32b.zip`

Release asset:
`adaptive-agent-orchestrator-v0.7.15.zip`

Archive SHA-256:
`e29eb5676b835a0baa6259aecf4b44272297fb98b499a7be2aa289d1bc8cad3f`

The release asset is a byte-for-byte copy of the independently reviewed
functional archive. Root README files, changelog, release notes, version marker,
and this receipt are repository documentation outside the installable Skill.

## Repository and archive results

- Exit code: 0
- PowerShell scripts parsed: 54/54
- Durable-milestone/revision focused assertions: 128 passed
- Self-test assertions: 862 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8/8
- Skill Creator validation: `Skill is valid!`
- Markdown links checked: 115 total, including 68 local targets with none
  missing
- Fixed archive versus functional commit: 73/73 files, zero missing, extra, or
  different files
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same independent read-only Noether acceptance role extracted the fixed ZIP
to a fresh temporary directory and verified:

- commit `7cba32babbc95cc095065468dee0cb486c09842a`;
- parent `1f166efa4aacc04117747a89345dfaf32f852a75`;
- ZIP SHA-256
  `e29eb5676b835a0baa6259aecf4b44272297fb98b499a7be2aa289d1bc8cad3f`;
- 73/73 archive files matching the Git tree;
- the same 54-script parse, 128 focused assertions, 862 self-test assertions,
  59 rejected invalid cases, 8 JSON parses, and Skill Creator validation; and
- 39/39 independent dynamic attacks with P0=0, P1=0, and P2=0.

The attack matrix covered the exact positive correction/selection chain and
rejected duplicate, forked, partial-source, wrong-evidence-shape,
cross-run/source/role/task/revision/checkpoint/input, selection-key,
journal-head/count, controller-authorization, result/disposition path/hash, and
correction-event mismatch cases. Every rejected attempt left `events.jsonl`
byte-for-byte unchanged.

Temporary acceptance-harness failures were separated from product findings.
After the temporary harness was corrected, all attacks passed without changing
the candidate.

## Real adoption

The installed candidate was exercised in the real multi-divination
checkpoint15 control run without modifying product files or creating, resending,
or replacing any reviewer task.

Before correction:

- event count: 35
- journal SHA-256:
  `66265c0a49aa3bdb5cc80195db2108f944c7bfc1eaaf4cb2526c25fe6c8b77ea`
- pending revision:
  `f273fa1b7a6f5e2732ad115b4cf176c2e566fa2ba593afe9fe67a211965ab7df`

Correction appended sequence 35 and bound the exact adversarial events
27/28/29 plus traditional events 32/33/34:

- correction internal hash:
  `8871309e651daf28dc0130215551740e22300ea1d510ec25a0298646b2987185`
- correction file SHA-256:
  `c5979a9abdf5d3dee3a7bb8dfb691940620dd44c41c706eb479e3bf197219434`
- correction event hash:
  `08b5f85c41107293808bd6502e8086968c119d85f5281c9ecb4891a60674aebf`

Schema 1.2 selection appended sequence 36:

- selection internal hash:
  `33f787c714fba6f3ecd90a03789b99aa093e17d5acdcd51acfeab4663b21df8a`
- selection file SHA-256:
  `94a4287bd2a541161f5a28bbe4763b85543550210acc571e84dd582ed849ac6f`
- selection event/head hash:
  `9bfe6266057c00751520927333c793bba3a61d8732198da82812aa5f9a7f5909`

After selection:

- event count: 37
- journal file SHA-256:
  `61d4c9c76ae7417be7465fe9bfd11d2da2a5ab29e15fa81d1d947fe82e6f4f74`
- original 35-line prefix SHA-256: unchanged
- both durable sources: still `adopted`
- main node: still `planned`

Completion returned exit 1 and correctly remained `BLOCKED` by:

- adversarial P0 `LY-ADV-CP14-P0-001`;
- traditional P1 `LY-TR-P1-07`, `LY-TR-P1-09`, `LY-TR-P1-10`, and
  `LY-TR-RR-P1-12`;
- adversarial P1 `LY-ADV-A5` and `LY-ADV-A6`; and
- missing main validation, evidence, and checkpoint15 main acceptance.

Resolved P1-08 did not reappear. All 90 multi-divination product snapshot
hashes remained unchanged. This is a successful Orchestrator adoption test,
not a multi-divination product PASS.

## Installed copy

Installed path:
`C:\\Users\\Administrator\\.codex\\skills\\adaptive-agent-orchestrator`

Backup retained before installation:
`C:\\Users\\Administrator\\.codex\\skill-backups\\adaptive-agent-orchestrator-before-revision-lifecycle-20260731-153739`

The fixed archive and installed Skill match exactly across all 73 files with
zero missing, extra, or different files. The installed copy passes the same
54-script parse, 128 focused assertions, 862 self-test assertions, 59 rejected
invalid cases, 8 strict reference JSON parses, and Skill Creator validation.

The first installation attempt was automatically rolled back when a local
relative-path comparison helper falsely reported two disjoint 73-file key sets.
A standard relative-path comparison then proved the copied candidate was
73/73 identical; the fixed archive was re-extracted, installed, and verified.
This was an installation verification-harness error, not a Skill defect.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not judge or repair multi-divination product findings and did not
  modify multi-divination product files.
- It does not claim measured production Token savings or business accuracy.
- Lifecycle correction accepts only the exact whole-source error shape described
  above. It is not a general journal-editing or lifecycle-repair mechanism.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite earlier authorization and every later retained
  entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
