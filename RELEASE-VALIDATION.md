# Release validation receipt

Release: `0.7.14`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.14 combines three independently reviewed controls that were validated in
one real long-lived review workflow.

First, an adopted replacement reviewer can continue to a later checkpoint only
through a one-time append-only roll-forward bound to the same run, logical
source, role, task, active milestone, checkpoint, and input. The original
continuity record remains immutable, and replacement-of-replacement remains
forbidden.

Second, when both active durable reviewers can no longer provide independent
results, an active-mid-run source rotation exports every open source occurrence
to one fresh successor run with two new read-only, nondelegating seats. The
rotation conserves source, severity, exact text/hash, canonical identity,
checkpoint, input, role contract, and consumed attempts. Old original or
replacement tasks cannot be reused.

Third, a fresh task that was actually created can be reconciled when its ID was
recorded one lifecycle step early. Only the immediate same-node
`materializing -> materialized` transition may reuse that exact ID, and only
with an activation reservation, unique task-list reconciliation, exact
`MATERIALIZED_WAITING_FOR_CONTINUITY` handshake, matching role/attempt, and no
earlier or cross-node use. Conflicting `thread_id`, `id`, or `threadId` values
fail closed.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, recovery receipt, or journal.

## Fixed functional candidate

Series base:
`38b30b2df834d81150b31a6d37d673bf7f294008`

Functional commits:

- `9a6c7288a7aa90f41ac2b6cfd07a10783649baa8` — roll an adopted
  replacement seat to a later checkpoint without widening its logical source
  or creating another replacement;
- `62082e981cec490fe8aa021244aa7f50afe0a710` — export an active failed
  review team and adopt two fresh, independently bounded reviewer seats;
- `69b55a05c45124b9b5ea9e9597781ea80a1e68f9` — reconcile an immediately
  adjacent same-ID fresh materialization;
- `35e72835c272f8a8eb53fded374684d84db00adc` — reject conflicting task
  identity fields and aliases.

The fixed installable Skill contains 72 files.

Candidate archive:
`adaptive-agent-orchestrator-materialization-continuity-35e7283.zip`

Candidate archive SHA-256:
`914fb7efb2a2c0dfa0522f8c30b4dcf7a329b110e4eb5e24cce6e355068775a4`

The versioned release asset is a byte-for-byte copy of this independently
reviewed archive:
`adaptive-agent-orchestrator-v0.7.14.zip`.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 53
- Materialization-continuity assertions: 45 passed
- Materialization-continuity invalid cases: 13 correctly rejected
- Recovery-protocol focused assertions: 91 passed
- Durable-milestone/revision/successor focused assertions: 106 passed
- Run-policy activation focused assertions: 15 passed
- Self-test assertions: 840 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Markdown links checked: 111 total, including 66 local targets with none
  missing
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

### Replacement checkpoint roll-forward

The checkpoint-scoped replacement roll-forward was exercised in the real
durable-review run. Both replacement seats advanced to the new checkpoint
without overwriting their original continuity, reusing an original task, or
creating replacement-of-replacement. Completion remained fail closed until
fresh source results existed.

### Active source rotation

The source-rotation fixed package at `62082e9` was evaluated by the same
independent read-only acceptance role. The fixed 71-file package matched its
Git archive and received GREEN with P0=0, P1=0, and P2=0.

Dynamic coverage included the real 74-event predecessor fixture (12/12 focused
checks) plus adjacent attacks on independence/exhaustion evidence, source and
role identities, threads, checkpoints, input hashes, recovery ordering,
cross-cycle replay, finding conservation, old-task reuse, repeated or forked
export, and successor adoption.

### Fresh materialization continuity

The combined 72-file candidate at `35e7283` received independent GREEN with
P0=0, P1=0, and P2=0. The reviewer completed 17/17 dynamic attacks covering:

- immediate same-ID continuation with the exact reservation, task-list
  reconciliation, and handshake;
- cross-node, historical, different-ID, non-adjacent, repeated, and missing
  evidence cases;
- duplicate task-list matches and alias conflicts; and
- conflicting, empty, case-different, or nested `thread_id` / `id` /
  `threadId` values.

The candidate, installation, and Git tree were frozen during both reviews.

## Real adoption

The installed candidate was exercised in the multi-divination long-lived review
control run without modifying product files or old history.

### Source rotation and fresh materialization

The active predecessor exported all 7/7 open P1 source occurrences into one
fresh successor run, split as five traditional-source and two
adversarial-source occurrences, with zero P0. Completion correctly remained
`BLOCKED`.

The existing fresh traditional task:

`019fb64b-c879-7620-8b4f-9362931050bd`

was uniquely reconciled after its ID had been written on `materializing`.
The guarded adjacent event adopted that same entity without recreating it.
Exactly one additional fresh adversarial task was then created:

`019fb68f-03e5-73a2-b6e5-8d95351addae`

Both tasks were read-only, nondelegating, and entered running state with actual
model recorded as unverified because the platform did not expose it. No old
original or replacement task was reused.

### Formal results and completion behavior

Both fresh reviews initially encountered platform missing-final behavior. Each
source used its own same-thread bounded recovery; no extra task was created.
Both formal results were captured and followed by source-specific result,
disposition, completed, validated, and adopted lifecycle evidence.

The adversarial formal result identified one new multi-divination product P0.
That business finding remained open alongside seven P1 source occurrences.
Completion returned exit 1 and remained correctly `BLOCKED` by that product P0,
the open P1 occurrences, and missing main acceptance. No new Orchestrator P0/P1
was found.

This is a successful Orchestrator adoption test, not a multi-divination product
PASS.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.14.zip`

Archive SHA-256:
`914fb7efb2a2c0dfa0522f8c30b4dcf7a329b110e4eb5e24cce6e355068775a4`

The archive is the exact independently reviewed 72-file Skill tree from
functional commit `35e7283`. Root README files, changelog, release notes, and
this validation receipt are repository documentation and intentionally remain
outside the installable Skill archive.

Fresh-extraction checks:

- PowerShell parse: 53/53
- materialization-continuity assertions: 45, including 13 invalid cases
- recovery-protocol assertions: 91
- durable-milestone/revision/successor assertions: 106
- self-test assertions: 840
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- archive content versus commit Git blobs: 72/72 after CRLF/LF normalization

## Installed copy

Installed path:
`C:\\Users\\Administrator\\.codex\\skills\\adaptive-agent-orchestrator`

Backup retained before this candidate was installed:
`C:\\Users\\Administrator\\.codex\\skill-backups\\adaptive-agent-orchestrator-before-materialization-20260731-124511`

The fixed archive and installed Skill match exactly across all 72 files with
zero missing, extra, or different files. The Windows source tree matches the
archive 72/72 after CRLF/LF normalization; raw source bytes are not claimed
identical. The installed copy passes the same 53-script parse, 45
materialization-continuity assertions, 91 recovery assertions, 106
milestone/revision/successor assertions, 840 self-test assertions, 59 rejected
invalid cases, 8 strict reference JSON parses, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not judge or repair the multi-divination product P0 and did not modify
  multi-divination product files.
- Source rotation carries review obligations and reviewer seats, not business
  artifacts.
- Replacement-of-replacement remains forbidden.
- After source rotation, old original and replacement tasks cannot be reused as
  current review seats.
- A materializing task ID is reusable only by the exact adjacent, evidence-bound
  materialized transition; it is not a general task-ID recovery mechanism.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite earlier authorization and every later retained
  entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
