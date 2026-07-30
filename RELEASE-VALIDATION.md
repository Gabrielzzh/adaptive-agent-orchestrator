# Release validation receipt

Release: `0.7.9`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.9 separates original durable-source result recovery by review cycle.
Every new checkpoint/input under the active milestone gets a deterministic
cycle binding the run, source, role, thread, milestone activation, checkpoint,
and input manifest.

Each cycle starts at attempt 1 and permits at most three same-thread,
same-role attempts. A receipt from another checkpoint, input, milestone,
source, role, or thread cannot start, extend, reset, or authorize the cycle.
Historical schema 1.0 original and schema 1.1 replacement receipts remain
readable; new original-source cycles use schema 1.2.

The orchestration policy remains `0.7.6`. This patch changes the recovery
receipt namespace and validation under that policy; it does not rewrite an
older plan, run, genesis, or journal.

## Fixed functional candidate

Functional commit:
`38a5c8e67dc90fce7204df3a2d4fea6d6a3515a5`

Parent:
`63fb6155088ab2ff222161841d739a40f8b75235`

The fixed Skill contains 64 files.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 45
- Recovery-protocol focused assertions: 56 passed
- Self-test assertions: 750 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 101
- `git diff --check`: passed
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The same read-only Noether reviewer dynamically re-attacked the fixed
functional commit and its 64-file candidate archive:

- P0: 0
- P1: 0
- P2: 0
- independent attack-harness assertions: 61 passed
- PowerShell parse: 45/45
- focused recovery assertions: 56
- self-test assertions: 750
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- Git/archive content comparison: 64/64

The reviewer confirmed that a new checkpoint/input can begin attempt 1 after a
completed earlier recovery cycle, while replay, mixed-cycle chaining, attempt
reset, milestone/input changes, and cross-source/thread reuse fail closed.
`result_pending` and incomplete review obligations never satisfy completion.

## Real adoption

The installed candidate was exercised against the real multi-divination
control run without modifying product files:

Run:
`C:\Users\Administrator\Documents\主task\orchestration-control\multi-divination-v072\runs\multi-divination-liuyao-p1-successor-v076-checkpoint07`

Source/thread:
`liuyao-adversarial-source` /
`019fb0df-5792-70f1-901b-3ce0a49dabe9`.

The checkpoint08 cycle bound:

- checkpoint SHA-256:
  `4a8024120b30febdf51d7b5c367c00d4ebfb861052c190ded87fcb85ee162d7d`
- input manifest SHA-256:
  `beb6eda4869448faa7afd509ca72971ade38cc3b092ccb31cb5fb8e3339bf880`
- progress capture SHA-256:
  `e0ed6ef18f0ec74b5da4e29ecddd17c0ff4da76761198c63335090b62ee3f597`
- recovery cycle:
  `7705aa4b9619e63a0fb0c3d98e2ef1bf14e3c20cf0c77f6315f9f69f3d05cc6b`
- attempt: 1
- recovery receipt internal hash:
  `888f2e5acee78825bd4aca320b9a37fa0da83d33b26a80b750ede34cafdad563`
- recovery receipt file SHA-256:
  `ddd9ee1fe117132c43cb1b22c02c187e28fb2864a0701636a34d54b273d4e80f`

Receipt creation did not change the journal. The controller then appended
`result_pending` sequence 14 and `running` sequence 15. Same-source recovery
returned a formal final in turn
`019fb2e9-5ad5-7ee0-ad3b-4c8b513f85c0`; the raw capture SHA-256 is
`9a0d26df5c3eaedc1561bb4a308eeae0355d4777d58eec0b0d4d99056ad73a92`.

The canonical schema 1.3 result receipt bound:

- internal hash:
  `0145511b4065d2f72987c2617a15f899fc6c2594aedddc89b80a9ca602a95f95`
- file SHA-256:
  `b1f7ac2030d83c878ccdc0d8079fa58b2638a9a1b3faaebae75939452a4859a6`

The source-specific disposition bound:

- internal hash:
  `75a5cc3d73c54e885b5306b1ed26841b8702f7d4e3e6a8c8a897bdbce6cb2928`
- file SHA-256:
  `b8fad6401d909319947fb54c49aa77d81072d4c1080de9ce9c93fd43b5b42e9f`

The journal appended `completed` sequence 16, `validated` sequence 17, and
`adopted` sequence 18. It ended with 19 lines and head
`22401c2403a1f45a53c9c70b72cc5a4b8a269addf9e2b2385c61334fc24a4211`.
No replacement was created and no historical event was edited.

Completion exited 1 and remained `BLOCKED` because traditional/main were
unfinished, main evidence was absent, and one P1 remained open. That P1 is the
multi-divination int/string-key `input_hash` collision; it is a business-product
finding, not an Orchestrator defect. The recovery cycle and completion gate
behaved as designed.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.9.zip`

Archive SHA-256:
`2fe97a587dc8b3d68f3339b182782724d3f2e7cd4a4c97bd4185b89cc9cdb0c7`

The archive was generated from fixed functional commit `38a5c8e` with
`git archive` and contains 64 Skill files. After line-ending normalization,
archive content matched the 64 Git blobs 64/64. From a fresh extraction:

- PowerShell parse: 45/45
- recovery-protocol assertions: 56
- self-test assertions: 750
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed

Root README files, changelog, release notes, and this receipt are repository
documentation and are intentionally outside the installable Skill archive.

## Installed copy

Installed path:
`C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`

Backup:
`C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-v0.7.9-20260730-202733`

The source and installed Skill copies matched 64/64 files by exact SHA-256
with zero missing or extra files. The installed copy passed 45-script parse,
56 focused recovery assertions, 750 self-test assertions, 59 rejected invalid
cases, strict parsing of 8 reference JSON files, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- The open multi-divination hash-collision P1 is not an Orchestrator defect.
- Recovery cycles do not permit replacement-of-replacement or relax P0/P1
  completion gates.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite every retained anchor. That threat requires an
  external WORM, signature, or remote log anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
