# Release validation receipt

Release: `0.7.13`
Policy version: `0.7.6` (unchanged)
Date: `2026-07-31`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.13 fixes two fail-closed historical-binding defects in a long-lived
durable-review run.

First, creation of a current-milestone recovery cycle enumerated historical
same-source cycles but revalidated each receipt against the currently active
milestone. A valid older cycle from an earlier milestone could therefore block
a new checkpoint. The fix validates each historical receipt against its own
recorded milestone and activation epoch while preserving canonical-path,
cycle-identity, source, role, thread, checkpoint, input, and attempt checks.

Second, a retained first-milestone revision selection re-read each source's most
recent completed, validated, and adopted events. Later valid same-source work
could therefore make the old immutable selection appear changed. The fix reads
the exact sequence/hash pre-bound in the selection's
`source_lifecycle_bindings` and verifies the complete recorded lifecycle object.

The orchestration policy remains `0.7.6`. This patch does not rewrite an older
plan, run, genesis, result, disposition, selection, recovery receipt, or
journal.

## Fixed functional candidate

Series base:
`1498e46ba52e8f6f98fc405461ccac7ba9589c8b`

Functional commits:

- `5953a3227f15b8cc45c88393a2320d8136afe960` — validate historical recovery
  receipts against their own milestone activation epoch;
- `b6cdf8ed9f0630e1d9f0ba2734648b1cbd3c8eb0` — reject recovery receipts copied
  outside the canonical run receipt namespace;
- `7ac92844648fc5a561188d6ef70e0f2bbe74d17f` — bind revision-selection reads to
  the recorded lifecycle sequence and hash.

The fixed Skill contains 67 files.

Candidate archive:
`adaptive-agent-orchestrator-7ac9284.zip`

Candidate archive SHA-256:
`4478e66388e8ca2efd3534359250540544ba5f07f20a64a0cfc27a549daa5787`

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 48
- Recovery-protocol focused assertions: 69 passed
- Durable-milestone/revision focused assertions: 106 passed
- Self-test assertions: 817 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Local Markdown links checked: 106
- `git diff --check`: passed with line-ending warnings only
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

The original acceptance execution thread was stopped three times by the
platform content filter before it ran the requested tests and produced no
product verdict. Those attempts were not counted as GREEN or RED.

The controller then explicitly authorized exactly one equivalent read-only
replacement reviewer for the same acceptance obligation. The replacement could
not modify the candidate, install, publish, or delegate another Agent.

It dynamically re-attacked functional commit
`7ac92844648fc5a561188d6ef70e0f2bbe74d17f` and candidate archive SHA-256
`4478e66388e8ca2efd3534359250540544ba5f07f20a64a0cfc27a549daa5787`.
The final disposition was GREEN with P0=0, P1=0, and P2=0.

The reviewer ran 2 positive paths and 22 negative attacks. All 22 invalid paths
failed before journal write and preserved journal bytes, length, and SHA-256.
Coverage included historical Group1 recovery plus a current Group2 cycle,
noncanonical receipt copies, cross-milestone/source/thread/checkpoint/
activation/attempt replay, attempt reset, lifecycle sequence/hash/status/source/
thread/evidence changes, excluded-evidence changes, and later same-source
lifecycle events.

The retained revision selection continued to return the exact original
completed/validated/adopted sequences 30/31/32 despite later same-source
sequences 46/47/48.

Independent results file:
`C:\\Users\\Administrator\\AppData\\Local\\Temp\\aao-7ac9284-independent-results-2.json`

Independent results SHA-256:
`b4a3a1ad16cf559dd3fa417c7bb9d6acadfb2179d2f6676d45af5093d01254f8`

## Real adoption

The installed candidate was exercised against the real multi-divination
long-lived durable-review run without modifying product files or old history:

`C:\\Users\\Administrator\\Documents\\主task\\orchestration-control\\multi-divination-v072\\runs\\multi-divination-liuyao-p1-successor-v076-checkpoint07`

### Historical recovery under the active milestone

The checkpoint13 current Group2 cycle was created while valid historical Group1
cycles remained in the same run:

- cycle:
  `508e2fb31e9d85e0644db7e3bd033dd70cf3a491cf8c0c6a2dc583d5d6989ae5`
- recovery receipt internal hash:
  `20bf121de83df69c0b3538069dec599b3ef8afa88ad9cbe76b07c12ed8772545`
- recovery receipt file SHA-256:
  `046cec6fa9e10675cb2f51590b1c01c22bdc5ccd0578d4f1d479347108b158c0`

The journal remained unchanged while the receipt was generated. The old
first-milestone selection then revalidated by its recorded lifecycle
sequence/hash, allowing the current recovery to enter `result_pending` and
continue without reinterpreting later lifecycle events.

### Bounded replacement recovery

The original adversarial source formally exhausted its checkpoint13 recovery
cycle at 3/3. The controller authorized exactly one same-role, read-only
replacement:

`019fb54d-b4ac-7411-937d-b12d191711f8`

The replacement preserved source, role, checkpoint, input, and original recovery
continuity. It used its own recovery namespace and returned a formal final on
attempt 2 without creating a replacement-of-replacement:

- continuity internal hash:
  `67d196c40276ae8e5c49872d109a374f1c396dc3a3363c7184772a6e502775af`
- attempt-1 internal/file SHA-256:
  `35fd4c8a5180c416a5db0cb53d71cebfbe599f2f5b3ad7c309a1dd35091c0da6` /
  `fc47a457a69171ef0061cb1d92fbce0380b6f01c2b3e4e5ee851e85ed2d57408`
- attempt-2 internal/file SHA-256:
  `7a5ffdd16cf5ecdaa168b6eb36e11004d218bb4370cab26cbc27026037b2a7c2` /
  `d0843a8d5cc37cfc8df48052802d153e0443c0e5f1ffbefbd86a84013fb010dd`
- exact final capture SHA-256:
  `8accb1165dc1cc6d617bc1518ba51fdf2ee3bb4fb6ae7537178b758332d92c3d`
- schema 1.3 replacement result internal/file SHA-256:
  `2b0175f413397dc728e710cb3698e937e00ad82ecff92332a401f90544c5616e` /
  `c9fae1af59ad0e19acc8f95ed640cc176066b15e44a1dd52b020e00812fcddf5`
- source disposition internal/file SHA-256:
  `96cff07b707a7102aefe06d500cb47b8786b945071a52d58a2f8ce114b915782` /
  `ee821dba5b9d4c19a7ad62977ed03a06f7fa3b4b7f6eb3db333478d91dc77aca`

The replacement lifecycle reached completed, validated, and adopted. The final
journal contained 63 lines with head:

`b61bd454e7166c7996eddf16d683346803f18182d5e52362dcd759b7974f80b1`

Journal file SHA-256:
`5397598a53a7d27441a4128776a47b5b95736d26328062bc7bb75b5224b45483`

The formal domain outcome remained `FAIL/UNKNOWN` because the evidence set was
incomplete. It reported no new P0/P1/P2, but all nine existing occurrences
remained open rather than being falsely resolved. Completion returned exit 1
and stayed `BLOCKED` by open P1, current-source constraints, and missing main
acceptance. This is a successful Orchestrator adoption test, not a business
PASS.

## Release archive

Archive:
`adaptive-agent-orchestrator-v0.7.13.zip`

Archive SHA-256:
`4478e66388e8ca2efd3534359250540544ba5f07f20a64a0cfc27a549daa5787`

The archive is the 67-file Skill tree from fixed functional commit `7ac9284`.
Root README files, changelog, release notes, and this validation receipt are
repository documentation and are intentionally outside the installable Skill
archive.

From a fresh extraction:

- PowerShell parse: 48/48
- recovery-protocol assertions: 69
- durable-milestone/revision assertions: 106
- self-test assertions: 817
- invalid cases rejected: 59/59
- strict reference JSON: 8/8
- Skill Creator validation: passed
- archive content versus commit Git blobs after CRLF/LF normalization: 67/67;
  raw ZIP-to-blob byte identity is not claimed
- Windows working-tree content versus archive after CRLF/LF normalization:
  67/67; raw working-tree bytes are not claimed identical

## Installed copy

Installed path:
`C:\\Users\\Administrator\\.codex\\skills\\adaptive-agent-orchestrator`

Backup:
`C:\\Users\\Administrator\\.codex\\skill-backups\\adaptive-agent-orchestrator-before-7ac9284-20260731-064634`

The fixed archive and installed Skill copies matched 67/67 files by exact
SHA-256 with zero missing, extra, or different files. The Windows repository
working tree matched the archive 67/67 after CRLF/LF normalization; raw
working-tree byte identity is not claimed. The installed copy passed 48-script
parse, 69 focused recovery assertions, 106 milestone/revision assertions, 817
self-test assertions, 59 rejected invalid cases, strict parsing of 8 reference
JSON files, and Skill Creator validation.

## Boundaries

- The Skill does not repair platform `systemError` or missing-final behavior.
- It does not claim measured production Token savings or business accuracy.
- It does not migrate or modify multi-divination product files.
- `FAIL/UNKNOWN` from incomplete domain evidence is neither an Orchestrator
  defect nor a business PASS.
- An original recovery cycle remains limited to three same-thread attempts.
- A replacement requires explicit authorization and exact continuity, receives
  one separate bounded recovery epoch, and cannot create another replacement.
- Historical receipts and immutable selections remain bound to their recorded
  milestone, activation, paths, events, sequences, and hashes.
- The local hash chain detects in-chain changes but does not resist an attacker
  who can coherently rewrite the earlier authorization and every later retained
  entry. That threat requires an external immutable anchor.
- Windows symbolic-link creation was unavailable. Linux and macOS were not
  dynamically validated.
