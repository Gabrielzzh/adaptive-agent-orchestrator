# Release validation receipt

Release: `0.7.17`
Policy version: `0.7.6` (unchanged)
Date: `2026-08-01`

## Scope

v0.7.17 repairs a same-milestone cumulative-inventory deadlock. A valid new
checkpoint result/disposition could list only current open findings and omit
previous source occurrences that still had to be conserved. The old immutable
selection then rejected the new checkpoint even though its lifecycle was valid.

The fix is deliberately narrow: one pre-bound, all-source, non-state
supersession may mechanically restore omitted occurrences from the previous
selected inventory. It cannot change source, canonical ID, severity, exact
text/hash, status, or evidence; it cannot overwrite old receipts or lifecycle
events; and it can be consumed by selection only once.

The standalone inventory-supersession contract remains separate. When the run
also has a lifecycle-evidence correction, the dedicated cumulative receipt
uses its own schema 1.0 fields/event, and schema 1.6 selection revalidates both
receipts. Legacy fields, paths, and events are rejected before journal write.
Completion still blocks on open P0/P1 and missing final main acceptance.

## Fixed candidate

- Parent commit: `a0a79b3af960d7a471920e2cedb50210e5cfac11`
- Fixed commit: `ef6d619fecc26bfe0556261ef46b2808a51d81d4`
- Independently accepted functional archive: `adaptive-agent-orchestrator-dedicated-cumulative-correction-ef6d619.zip`
- Independently accepted functional archive SHA-256: recorded after final archive build
- v0.7.17 release archive: `adaptive-agent-orchestrator-v0.7.17.zip` (built from the final release commit)
- v0.7.17 release archive SHA-256: recorded with the final archive asset
- Installable Skill files: 76
- Archive versus Git blobs: 76/76 after Windows CRLF normalization

## Repository and archive gates

- PowerShell scripts parsed: 57/57
- Durable milestone assertions: 273 passed
- Recovery assertions: 91 passed
- Materialization assertions: 45 passed; 13 negative cases passed
- Run-policy assertions: 15 passed
- Self-test assertions: 1014 passed
- Intentional invalid cases: 60 rejected
- Reference JSON files: 8/8 parsed
- Skill Creator: `Skill is valid!`
- Independent high-value mutation review: 11/11 passed, P0/P1/P2=0/0/0
- Performance evidence: supersession 15.067s, selection 16.420s, standalone
  reader 10.767s, completion 29.562s; all within the agreed limits
- Symbolic-link fixture: skipped because this Windows session denied link
  creation

The copied-run `source-rotation adoption run identity changed` message is a
known fixture limitation: the adoption receipt is bound to the original
absolute run path. The path check remains fail closed and was not relaxed.

## Real adoption

Run: `multi-divination-liuyao-p1-source-rotation-checkpoint14-v1`

- Cumulative correction receipt hash:
  `e79d67c2288b09c0beabae9f4c83eb7fe02c62b678fb0d738163d2e46b942eeb`
- Cumulative correction file SHA-256:
  `b9f2bfed5474ff199da189f425f6a7f3201a0a3a7da5551597bee3fb0deeb39c`
- Cumulative correction event: sequence `127`, hash
  `02dc1419247340b625015dc0bab407a56f2007746659a2eb9ce29b13d052b0fd`
- Selection schema 1.6 receipt hash:
  `ea720650dc3d6c4d768155357cb8d948f668d60742c61a5909aa1f3a8a4f0672`
- Selection file SHA-256:
  `f757960c936b86a37c84735eaa8f625cf272128f66f54eb5e572c97ed4782f44`
- Selection event: sequence `128`, hash
  `9a97d6dda29df9b8653a65d857482c5f7752e01bc1860e91e3d85363997a5078`
- Journal: 127 -> 129 events; final file SHA-256
  `6503f853dcde54c0beef9168b9e76fdb29e7b43460e97939e32eca520cf4b2b7`
- Original 127-event prefix SHA-256:
  `6d1d9d26a059f76baef429427eb9e0d8fd0c0aa836c68b020a125d4f9fdc65a2`

Completion exited non-zero and remained safely `BLOCKED`. It reported only
missing main validation/evidence, missing main-owner acceptance, and
`LY-TR-P1-09` still open. The adversarial deferred P2 did not block, and
resolved occurrences did not reappear. The product repository remained at
`d1353024cf260e8aedabd71abb35fac1325edec2`, with the checkpoint's 96 files
unchanged.

## Installed copy

- Install path: `C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`
- Backup: `C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-ef6d619-20260801-194248`
- Source/install comparison: 76/76; missing/extra/different = 0/0/0
- Installed parse57, Milestone273, Recovery91, Materialization45/negative13,
  Policy15, Self1014/invalid60, JSON8, and Skill Creator all passed.

## Boundaries

- This release does not repair platform `systemError` or missing-final behavior.
- It does not judge or repair multi-divination findings and did not modify its
  product files, handoffs, or review artifacts.
- It does not claim measured production Token savings or business accuracy.
- It does not add a new path for non-blocking P2 findings.
- Linux/macOS were not dynamically validated.
