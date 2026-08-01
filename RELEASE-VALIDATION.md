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

Schema 1.4 selection revalidates the supersession, authorization/selection key,
journal head, checkpoint/input, both source identities, and both
result/disposition lifecycle chains. Completion still blocks on open P0/P1 and
missing final main acceptance.

## Fixed candidate

- Parent commit: `61d5ab9cd00e3298a5fb466c9fcc2f8e97188596`
- Fixed commit: `d5c99b3bec9bab865ee67388770d8c043b27df89`
- Independently accepted functional archive: `adaptive-agent-orchestrator-same-revision-inventory-d5c99b3.zip`
- Independently accepted functional archive SHA-256: `45b00cb7200b45b502c9602b14e732a14b2d07eed936af9fac7efb2dc210f2de`
- v0.7.17 release archive: `adaptive-agent-orchestrator-v0.7.17.zip`
- v0.7.17 release archive SHA-256: `dc7805ae4102dcbf3289f5f28bdfe35efd60adaf40888ac70cf7237be4d2f558`
- Installable Skill files: 74
- Archive versus Git blobs: 74/74 after Windows CRLF normalization

## Repository and archive gates

- PowerShell scripts parsed: 55/55
- Durable milestone assertions: 191 passed
- Recovery assertions: 91 passed
- Materialization assertions: 45 passed; 13 negative cases passed
- Run-policy assertions: 15 passed
- Self-test assertions: 932 passed
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

- Supersession schema 1.0 internal hash:
  `607fed782a49e55589a6837846ce2f77d87aec7a82941fd2986994378515c49a`
- Supersession file SHA-256:
  `a9ffce32602d435980c42740b8b520256ed449493d5690f746c9e501d4429fa8`
- Supersession event: sequence `109`, hash
  `7ca1077f8820970851e188c343889e0c4ec9df8e59961d7f16342d9f4f2257f2`
- Selection schema 1.4 internal hash:
  `709dca7feb3adbef1b14ab6f76df185d55a97f9a1fd61f211e90201c923e50a6`
- Selection file SHA-256:
  `5094fe522efbfc21d0a6681e7ac343fa28df0f7442aae7bac658db60acd43b61`
- Selection event: sequence `110`, hash
  `633ca09707247af3a610a08143166982872601936f825a59827de6facc156b14`
- Journal: 109 -> 111 events; final file SHA-256
  `6c7b29ed7238e45078f32192aaeb0d02cd55861e5ba9cfb5f1fa9f2c664e1690` as recorded by the source task
- Original 109-event prefix SHA-256:
  `0d18215f5ff76b6def8cc289b691ab0f68cd2f7ad765ae7530392245e4ae2c7f`

Completion exited non-zero and remained safely `BLOCKED`. It reported only
missing main validation/evidence, missing main-owner acceptance, and
`LY-TR-P1-09` still open. The adversarial deferred P2 did not block, and
resolved occurrences did not reappear. The product repository remained at
`d1353024cf260e8aedabd71abb35fac1325edec2`, with the checkpoint's 96 files
unchanged.

## Installed copy

- Install path: `C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`
- Backup: `C:\Users\Administrator\.codex\skill-backups\adaptive-agent-orchestrator-before-d5c99b3-20260801-094115`
- Source/install comparison: 74/74; missing/extra/different = 0/0/0
- Installed parse55, Milestone191, Recovery91, Materialization45/negative13,
  Policy15, Self932/invalid60, JSON8, and Skill Creator all passed.

## Boundaries

- This release does not repair platform `systemError` or missing-final behavior.
- It does not judge or repair multi-divination findings and did not modify its
  product files, handoffs, or review artifacts.
- It does not claim measured production Token savings or business accuracy.
- It does not add a new path for non-blocking P2 findings.
- Linux/macOS were not dynamically validated.
