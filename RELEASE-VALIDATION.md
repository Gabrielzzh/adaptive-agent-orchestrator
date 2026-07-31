# Release validation receipt

Release: `0.7.16`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.16 repairs one durable-review progression deadlock. A complete and
selected first-milestone revision could correctly retain open P0/P1 findings
and therefore lack final main-owner acceptance. The same missing final
acceptance then incorrectly prevented authorizing the next checkpoint revision
of that same milestone.

The patch permits a consecutive revision only at plan index 0 and binds it to
the preceding selection receipt/event, exact journal head/count, unchanged
source/role/task identities, a different checkpoint/input, and every still-open
P0/P1 source occurrence with exact identity, severity, text/hash, canonical
identity, and status. Missing, downgraded, rewritten, cross-source, replayed,
forked, stale, pending, later-milestone, final-accepted, or post-authorization
drift fails before journal write.

Schema 1.0 remains valid for the first revision. Schema 1.1 records revision
index 2 and later. Ordinary `adopted` remains terminal and completion remains
blocked by open P0/P1 findings and missing final main acceptance.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, selection, result, disposition, recovery receipt, or
journal.

## Fixed functional candidate

Series base:
`07d9c945b2e433c83113722e99bb316ed14d6b3f`

Rebased functional commit:
`4a592e755d60cad497d815c7d2b8a693b4db88b2`

Independently reviewed equivalent functional commit:
`1b8ee761d0f908975f45ae27c7913fa0ab3c54dc`

The pre-rebase and post-rebase full trees were identical:
`71f5f4322c7c2ef981654c07d422ff8eda3e6530`

The installable Skill tree was identical:
`4935de2744bbbd16630849756ec2c1aceabf5568`

The fixed installable Skill contains 73 files.

Independently reviewed archive:
`adaptive-agent-orchestrator-same-milestone-revision-1b8ee76.zip`

Release asset:
`adaptive-agent-orchestrator-v0.7.16.zip`

Archive SHA-256:
`75afca4651b40f118351ec8f7e2f223d5e96f7a493a3bce064da95418ce4f6f3`

The release asset is a byte-for-byte copy of the independently reviewed fixed
archive. Rebase changed only commit ancestry; both full-tree and Skill-tree
identities remained unchanged. Root README files, changelog, release notes,
version marker, and this receipt are repository documentation outside the
installable Skill.

## Repository and archive results

- Exit code: 0
- PowerShell scripts parsed: 54/54
- Durable-milestone/revision focused assertions: 149 passed
- Recovery-protocol assertions: 91 passed
- Materialization-continuity assertions: 45 passed
- Run-policy activation assertions: 15 passed
- Self-test assertions: 883 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8/8
- Skill Creator validation: `Skill is valid!`
- Markdown links checked: 118 total, including 69 local targets with none
  missing
- Fixed archive versus functional Skill tree: 73/73 files, zero missing, extra,
  or different files
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same independent read-only Noether acceptance role extracted the fixed ZIP
to a fresh temporary directory and verified:

- reviewed commit `1b8ee761d0f908975f45ae27c7913fa0ab3c54dc`;
- parent `bc98e3a871dda2632b7bdc49134faa6b2bb58439`;
- ZIP SHA-256
  `75afca4651b40f118351ec8f7e2f223d5e96f7a493a3bce064da95418ce4f6f3`;
- 73/73 archive files matching the reviewed Git tree;
- the same 54-script parse, 149 focused assertions, 883 self-test assertions,
  59 rejected invalid cases, 8 JSON parses, and Skill Creator validation; and
- 50/50 independent dynamic cases plus 9/9 real-run-shape checks with
  P0=0/P1=0/P2=0.

The attack matrix covered checkpoint/input reuse, same-content different paths,
pending/partial/later/final states, preceding selection path/hash/sequence/event,
journal head/count, run/milestone/source/role/thread identity, finding ID,
severity, exact text/hash, canonical identity, cross-source movement,
canonical-only collapse, ordinary adopted restart, repeated re-arm, partial
selection, double consumption, revision jumps, non-latest selection, schema 1.0
compatibility, schema 1.1 downgrade, post-authorization disposition/material
drift, and resolved-finding reappearance. Every rejected attempt left the
journal byte-for-byte unchanged.

The symlink/path-alias case could not be dynamically exercised because this
Windows session did not permit symbolic-link creation. Same-content
different-path cases were dynamically rejected.

## Real adoption

The installed candidate was exercised in the real multi-divination checkpoint16
control run without modifying product files or replacing reviewer tasks.

Authorization:

- schema: `1.1`
- revision index: `2`
- revision ID:
  `726210f9fb45b5c204b99c09423da80d1ac4fcefda494b2e32dfb833d042a2c8`
- internal hash:
  `ae0b531e08996d1d8826ecf497397e7c9012c355b2aaf6ee63a466eb034a6d14`
- file SHA-256:
  `859812c7e7d65321652f260365a87959d501ec5768ae423f34d7b4724d1cd86e`
- authorization event sequence/hash:
  `37` /
  `219f8b46effa0c4c8f1b3facef63424b2ee51af62367d8d55b0b687434bcda50`

Both existing durable sources were re-armed and returned fresh formal results.
Their schema 1.3 results and source-specific dispositions were recorded through
correct `completed -> validated -> adopted` evidence without correction.

Selection:

- schema: `1.1`
- revision index: `2`
- internal hash:
  `d462d78af857f1a806c280ea6de91b11335d8004751a504c83bb39eae849d2f1`
- file SHA-256:
  `4cf01e0e8216bf0822039925d2b806bd836529ef03eaa75dd8ff5b77785626da`
- selection event sequence/hash:
  `46` /
  `98f89f2881e7135efe0662fb1adb7baf1178ccae10bfab98907259bd27c70242`

After selection:

- event count: 47
- journal head: sequence 46, hash above
- journal file SHA-256:
  `165712be13b1a70f02f1670ca80173c5e2166e27343ee72b0212f86d98d8c0ed`
- original 37-event prefix SHA-256:
  `61d4c9c76ae7417be7465fe9bfd11d2da2a5ab29e15fa81d1d947fe82e6f4f74`
  (unchanged)

Completion returned exit 1 and correctly remained `BLOCKED` by:

- adversarial P0 `LY-ADV-CP14-P0-001`;
- traditional P1 `LY-TR-P1-07`, `LY-TR-P1-09`, `LY-TR-P1-10`, and
  `LY-TR-RR-P1-12`;
- adversarial P1 `LY-ADV-A6`; and
- missing final main-owner acceptance.

Same-source resolutions for traditional P1-08 and adversarial A5 did not
reappear. All 90 multi-divination product snapshot hashes remained stable.
Traditional and adversarial business reviews still reported FAIL/incomplete
evidence; those results were preserved and are not Orchestrator defects. This
is a successful Orchestrator adoption test, not a multi-divination product PASS.

## Installed copy

Installed path:
`C:\\Users\\Administrator\\.codex\\skills\\adaptive-agent-orchestrator`

Backup retained before installation:
`C:\\Users\\Administrator\\.codex\\skill-backups\\adaptive-agent-orchestrator-before-same-milestone-revision-20260731-174036`

The fixed archive and installed Skill match exactly across all 73 files with
zero missing, extra, or different files. The installed copy passed the same
54-script parse, 149 focused assertions, 91 recovery, 45 materialization,
15 policy-activation, 883 self-test, 59 rejected invalid, 8 strict reference
JSON, and Skill Creator gates.

An initial installation command had a local PowerShell nested-quoting parser
error before any filesystem write. The corrected command completed normally.
This was a command-harness error, not a Skill defect.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not judge or repair multi-divination product findings and did not
  modify multi-divination product files.
- It does not claim measured production Token savings or business accuracy.
- Consecutive same-milestone authorization is limited to plan index 0 and
  requires a complete, terminal preceding revision. It is not a general
  journal, milestone, or history restart mechanism.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite earlier authorization and every later retained
  entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
