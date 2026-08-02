# Changelog

## 0.7.18 - 2026-08-02

Durable-review recovery and exact correction-identity release.

- Allow an invalid, still-unselected same-milestone revision to be abandoned
  append-only, then authorize fresh review work without rewriting prior history.
- Preserve revision ordinals across selected and legally abandoned revisions,
  including replacement-source recovery under the current consecutive revision.
- Add narrowly bound lifecycle-evidence corrections for documented pointer
  omissions while keeping state, findings, checkpoint, input, and receipts fixed.
- Require structured correction mode and omission-source identity to match exact
  lowercase ordinal values. Case variants, surrounding whitespace, and Unicode
  lookalikes now fail before journal write.
- Describe orchestration as task-shaped company organization: simple work stays
  one layer, complex work may add leads and executors, and staffing flows upward.
- Preserve boundaries: no external model provider, SDK, API-key integration, or
  change to open-finding/main-acceptance completion gates is introduced.

## 0.7.17 - 2026-08-01

Same-revision cumulative review-inventory correction release.

- Fix a fail-closed deadlock where a new checkpoint's signed result and
  disposition listed only currently open findings, omitting earlier source
  occurrences that were already resolved or still had to remain conserved.
  The immutable revision selection could not consume the new checkpoint even
  though the review lifecycle itself was valid.
- Add one pre-bound, all-source, non-state supersession receipt. It mechanically
  restores only omitted occurrences from the previous selected inventory,
  preserves each source, canonical ID, severity, exact text/hash, status, and
  evidence, and never overwrites old receipts or lifecycle events.
- Keep the old standalone inventory-supersession contract separate from the
  new lifecycle-correction combination. The dedicated cumulative receipt uses
  its own schema 1.0 fields and event, and schema 1.6 selection binds both the
  lifecycle correction and cumulative correction. Legacy fields, paths, and
  events cannot be mixed into the dedicated protocol.
- Validate the fixed 76-file package and the real 127-event run. The run
  advanced 127 -> 128 -> 129 while the original 127-event prefix stayed
  byte-identical; completion remained correctly `BLOCKED` by missing main-owner
  acceptance and the still-open `LY-TR-P1-09` timing finding.
- Preserve the boundary: this release does not repair platform `systemError`,
  claim measured Token savings or business accuracy, change multi-divination
  product files, or add a new path for non-blocking P2 findings.

## 0.7.16 - 2026-07-31

Consecutive first-milestone durable-review revision release.

- Fix a fail-closed deadlock where a complete, selected first-milestone revision
  still had open P0/P1 findings and therefore correctly lacked final main-owner
  acceptance, but that missing final acceptance also prevented authorizing the
  next checkpoint revision of the same milestone.
- Allow the next revision only when the active milestone is plan index 0, the
  preceding revision is complete and uniquely selected, no later milestone,
  pending revision, partial revision, or final acceptance exists, and the new
  checkpoint and input differ from the preceding revision.
- Add schema 1.1 authorization that binds the preceding selection receipt and
  exact selection event, current journal head/count, the same read-only source,
  role, and durable-task identities, and every still-open P0/P1 occurrence with
  its source ID, canonical ID, severity, exact text/hash, and status.
- Reject omitted, downgraded, rewritten, cross-source, cross-task, replayed,
  forked, stale-head, same-checkpoint, later-milestone, pending, and
  post-authorization evidence-drift attempts before journal write. Schema 1.0
  remains valid for the first revision.
- Validate the fixed 73-file package through the same independent Noether role:
  50/50 dynamic cases plus 9/9 real-run-shape checks passed with
  P0=0/P1=0/P2=0.
- Exercise the installed candidate in the real checkpoint16 review. Both
  durable sources produced fresh formal results, dispositions, and lifecycle
  evidence; one unique schema 1.1 selection was appended; the original
  37-event prefix remained byte-identical; and completion stayed correctly
  `BLOCKED` by one open P0, five open P1 source occurrences, and missing final
  main acceptance.
- Preserve the boundary: this release does not repair platform `systemError`,
  judge or fix multi-divination findings, claim measured Token savings or
  business accuracy, or modify multi-divination product files.

## 0.7.15 - 2026-07-31

Append-only durable-review lifecycle evidence correction release.

- Fix a fail-closed deadlock where both durable sources had correctly recorded
  `completed` result evidence and `adopted` disposition evidence, but each
  `validated` event mistakenly repeated the result pointer. The immutable
  lifecycle could not be selected, while editing history or rerunning reviewers
  was forbidden.
- Add one whole-source, append-only lifecycle correction receipt and journal
  event for that exact error shape. It binds the pending revision
  authorization, pre-bound selection key, journal head/count, both exact source
  lifecycle chains, checkpoint/input, and result/disposition internal and file
  hashes.
- Keep source states unchanged. The correction cannot resolve findings, resend
  or create reviewers, repair any other lifecycle error, or replace an original
  event.
- Require revision selection and completion readback to validate both the
  immutable original events and the correction. Duplicate, partial, forked,
  cross-run/source/role/thread/revision/checkpoint/input, artifact-drift, and
  authority-drift attempts fail before journal write.
- Validate the fixed 73-file package through an independent 39/39 dynamic
  re-attack with P0=0/P1=0/P2=0, then exercise it in the real checkpoint15
  review run. The old 35-event prefix remained byte-identical, both sources
  remained adopted, and completion stayed correctly `BLOCKED` by one product
  P0, six open P1 occurrences, and missing main acceptance.
- Preserve the boundary: this release does not repair platform `systemError`,
  judge or fix multi-divination findings, claim measured Token savings or
  business accuracy, or modify multi-divination product files.

## 0.7.14 - 2026-07-31

Durable reviewer continuity and source-rotation patch release.

- Let an authorized replacement reviewer continue into a later checkpoint on
  the same logical source, role, and durable task through a one-time,
  append-only roll-forward. The original continuity record remains unchanged,
  and replacement-of-replacement remains forbidden.
- Add an active-mid-run source rotation for the case where the two current
  durable reviewers can no longer provide independent results. The old run
  exports every open source occurrence into one fresh successor run with two
  new read-only, nondelegating reviewer seats; old tasks are never reused.
- Preserve source, severity, exact text/hash, canonical identity, checkpoint,
  input, role contract, and attempt history across rotation. Missing,
  downgraded, merged-across-source, replayed, or forked obligations fail closed.
- Reconcile a fresh task that was actually created when its thread ID was
  recorded one lifecycle step early. Only the immediately adjacent
  `materializing -> materialized` transition may reuse that exact ID, and only
  with a unique task-list match, activation reservation, and exact
  `MATERIALIZED_WAITING_FOR_CONTINUITY` handshake.
- Reject conflicting task identities across `thread_id`, `id`, and `threadId`
  instead of selecting one field or blindly creating another task.
- Validate the combined controls in the real multi-divination review run: two
  fresh reviewers were materialized, both reviews were recovered through their
  own tasks, formal results and dispositions were recorded, and completion
  stayed correctly `BLOCKED` by a product P0, seven open P1 occurrences, and
  missing main acceptance. No new Orchestrator P0/P1 was found.
- Preserve the boundary: this release does not repair platform `systemError`,
  judge or fix the multi-divination product finding, claim measured Token
  savings or business accuracy, or modify multi-divination product files.

## 0.7.13 - 2026-07-31

Historical recovery and immutable review-selection patch release.

- Fix a fail-closed block where creating a new recovery cycle under the current
  milestone revalidated every older cycle against that current milestone. A
  legitimate earlier cycle could therefore block a new checkpoint even though
  both cycles were internally consistent.
- Validate each historical recovery receipt against the milestone and activation
  epoch recorded in that receipt. Keep canonical receipt paths, cycle identity,
  source, role, thread, checkpoint, input, and attempt limits fail closed.
- Fix old first-milestone revision selections being reinterpreted through the
  latest same-source lifecycle. Read the exact pre-bound event sequence and hash
  instead, so later valid milestone work cannot invalidate or replace the
  immutable selection.
- Validate the real long-lived review run end to end: the original source
  exhausted its bounded 3/3 recovery, one authorized same-role replacement
  recovered a formal result, all nine unresolved occurrences remained open, and
  completion stayed correctly `BLOCKED`.
- Preserve the boundary: this release does not repair platform `systemError`,
  turn incomplete domain evidence into a business PASS, claim measured Token
  savings or business accuracy, or modify multi-divination product files.

## 0.7.12 - 2026-07-31

Active-milestone durable-source recovery patch release.

- Fix a fail-closed block where a later milestone activation selected a fresh
  same-source result/disposition, but the source's latest node lifecycle still
  referenced the preceding milestone. A valid new recovery cycle could be
  created, yet `adopted -> result_pending` could not consume it.
- Allow that narrow re-entry only when the complete active milestone chain
  verifies the same source, role, durable task, result, disposition, activation
  receipt/event, new checkpoint/input, and unused schema 1.2 attempt-1 cycle.
- Record the exact prior adopted event, active result/disposition hashes, and
  milestone activation event on the new `result_pending` event.
- Keep ordinary `adopted` terminal. Reject old or unselected milestone evidence,
  cross-source/role/thread substitution, same-checkpoint replay, used cycles,
  direct attempt 2/3 entry, and selection/activation/checkpoint/input tampering.
- Validate the real multi-divination 39-event run: its immutable prefix stayed
  unchanged, the traditional source entered `result_pending` and `running`
  against checkpoint12, and the original durable task returned a formal final.
- Preserve the boundary: this release does not repair platform `systemError`,
  treat an incomplete domain review as a product PASS, claim measured Token
  savings or business accuracy, or modify multi-divination product files.

## 0.7.11 - 2026-07-31

Scoped durable-review milestone progression release.

- Remove a fail-closed deadlock where an active milestone intentionally carried
  later-stage P0/P1 findings, could not receive final main-owner acceptance, and
  therefore could not activate the next milestone already declared in the plan.
- Add an append-once scope-transition authorization before activation. It binds
  the run, previous milestone, exact next milestone, selection/checkpoint,
  controller material, scope key, source set, and conserved finding counts.
- Require the next activation to consume that exact earlier authorization.
  Replacing the scope key, controller material, selection, run, milestone, or
  source set only in the activation tail fails closed.
- Conserve every prior P0/P1 source occurrence by source/thread, finding ID,
  canonical ID, severity, exact text, and text hash. Only same-source reviewed
  occurrences may be resolved; every other occurrence remains open.
- Keep scoped progression separate from final main-owner acceptance. It cannot
  validate the main node, satisfy completion, skip a declared milestone, or
  make an open blocker disappear.
- Validate the real multi-divination 37-event control run: Group2 activation
  advanced append-only, resolved four in-scope P1 occurrences, retained seven
  later P1 occurrences, and completion remained correctly blocked by those
  seven findings plus missing final main acceptance.
- Preserve the boundary: this release does not repair platform `systemError`,
  prove Token savings or business accuracy, modify multi-divination product
  files, or protect against coherent rewriting of the authorization event and
  all later retained history.

## 0.7.10 - 2026-07-30

First-milestone review-revision and verified recovery re-entry release.

- Let an adopted durable source enter `result_pending` for a later
  checkpoint/input only when an unused schema 1.2 attempt-1 recovery cycle
  binds the same run, source, role, thread, and active milestone.
- Keep ordinary `adopted` terminal. Reject missing or replayed recovery cycles,
  same-checkpoint reuse, direct attempt 2/3 entry, and cross-source, thread, or
  milestone substitution.
- Add a pre-authorized, append-only revision path for the first declared
  durable-review milestone before any later milestone is activated.
- Bind one immutable selection identity before fresh results exist, re-arm each
  required read-only source once, and select only the complete, exact
  post-authorization source chains.
- Preserve every prior finding occurrence by source ID, severity, exact text
  hash, and canonical ID. One source cannot replace another, and open P0/P1
  findings remain blockers.
- Validate the real multi-divination control run: both fresh domain and
  adversarial reviews passed, the unique revision selected checkpoint10, all
  11 later P1 source occurrences remained open, resolved older findings did not
  reappear, and development safely advanced to the next group.
- Preserve the boundary: this release does not repair platform `systemError`,
  prove Token savings or business accuracy, modify multi-divination product
  files, or protect against coherent rewriting of the entire retained history.

## 0.7.9 - 2026-07-30

Per-review-cycle durable-source recovery release.

- Namespace original durable-source recovery by a deterministic cycle binding
  the run, source, role, thread, active milestone/activation, checkpoint, and
  input manifest.
- Let the same long-lived source begin a fresh attempt-1 cycle for a later
  checkpoint after an earlier checkpoint recovered successfully, without
  overwriting or chaining through the earlier recovery receipt.
- Keep each cycle limited to three same-thread, same-role attempts; reject
  cross-cycle replay, mixed checkpoint/input/milestone chains, attempt resets,
  and cross-source/thread reuse.
- Preserve historical schema 1.0 original and schema 1.1 replacement recovery
  receipts while emitting schema 1.2 for new original-source cycles.
- Validate the real multi-divination control run: checkpoint08 created a cycle
  isolated from checkpoint07, recovered a formal same-source final, generated
  schema 1.3 result/disposition receipts, appended lifecycle events, and
  remained correctly blocked by an open business P1 and unfinished nodes.
- Preserve the boundary: this release does not repair platform `systemError`,
  classify the multi-divination hash-collision P1 as an Orchestrator defect, or
  claim measured Token savings or business accuracy.

## 0.7.8 - 2026-07-30

Append-only abandoned-successor recovery release.

- Add a pre-bound controller authorization receipt before abandonment export;
  export cannot create, replace, or restate its own authority.
- Permit a first-generation successor cancelled before its first durable
  milestone and before any review message to roll forward into one fresh
  successor without rewriting the abandoned run.
- Bind the cancelled event, no-dispatch evidence, old successor adoption,
  journal head/count, checkpoint, ordered source/role/thread identities,
  inherited and newly added P1 occurrences, target plan/run/milestones, and
  non-completion evidence.
- Preserve consumed source attempts in the fresh run. A cancelled source cannot
  regain attempt 1, change thread or role, or be revived in the old run.
- Reject repeated or forked export, cross-run/source/thread/checkpoint replay,
  omitted or downgraded obligations, activated milestones, existing result
  lifecycles, and unactivated receipts used as completion evidence.
- Validate the real multi-divination control run: 18/18 P1 occurrences carried
  across two sources, zero P0, and completion remained correctly blocked.
- Preserve the boundary: this release does not repair platform `systemError`,
  prove Token savings or business accuracy, or resist an attacker who can
  coherently rewrite the complete retained history without an external anchor.

## 0.7.7 - 2026-07-30

Raw Codex thread-capture compatibility patch release.

- Accept the current Codex `read_thread` identity shape, `thread.id`, directly
  in read, progress, and result-receipt validation.
- Preserve historical `thread.threadId` and top-level `threadId` captures.
- Fail closed when any concurrently present identity is empty or differs,
  including case-only differences, instead of selecting one field.
- Preserve a single legacy finding as a one-element JSON array when generating
  a schema 1.2 result receipt.
- Keep orchestration policy `0.7.6`: this parser-compatible patch does not
  rewrite plans, runs, journals, or require policy activation.
- Validate against two real raw captures and real schema 1.3 result/disposition
  generation. The release does not legitimize retroactive lifecycle events.

## 0.7.6 - 2026-07-30

Auditable durable-review successor-run patch release.

- Add a predecessor export receipt that freezes the old plan, run metadata,
  genesis, final journal boundary, effective policy, active milestone,
  checkpoint, exact durable-source identities, and every unresolved P1.
- Create a new `0.7.6` run only through a successor-adoption command that binds
  the export, target plan, declared milestones, source continuity, and control
  authorization. The predecessor remains immutable.
- Carry each P1 by stable source finding ID, canonical ID, original severity,
  exact text hash, and status. Missing, changed, downgraded, or cross-source
  obligations fail closed.
- Require the same durable source and role continuity to disposition and
  re-review inherited P1 findings before the successor can complete.
- Reject P0 carry-forward, directory-copy adoption, bare genesis, replay across
  runs or checkpoints, duplicate or forked successors, and unbound thread
  reuse.
- Preserve one main writer, result-only consumer output, no Worker nesting,
  model-binding rules, and all existing recovery and milestone gates.
- Preserve the boundary: this release does not repair platform `systemError`,
  migrate business artifacts, modify multi-divination, or claim measured
  production Token savings.

## 0.7.5 - 2026-07-30

Cross-milestone durable-review roll-forward patch release.

- Add append-only milestone activation so one durable review run can advance
  through its declared milestones without rewriting the immutable plan,
  run metadata, or existing journal.
- Bind each activated source to its exact milestone, checkpoint, thread,
  result receipt, disposition receipt, paths, and hashes. Completion consumes
  only the latest valid activation, never the newest file by timestamp.
- Require a new main-owner acceptance for each activated milestone. Earlier
  `validated` state cannot approve a later checkpoint.
- Pre-bind the acceptance authority, key, and evidence path/hash in milestone
  activation so a caller cannot coherently re-sign only the acceptance tail.
- Preserve independent source obligations and immutable P0/P1 blocking. One
  source cannot substitute for another and an open blocker cannot be accepted.
- Reject comma-joined typed evidence pointers before they enter the immutable
  journal while still allowing ordinary commas inside observation text.
- Preserve the boundary: this release does not repair platform `systemError`,
  migrate business artifacts, prove Token savings, or claim resistance to an
  attacker who can rewrite the entire history without an external head anchor.

## 0.7.4 - 2026-07-30

Auditable immutable-run policy activation patch release.

- Allow a consistent `0.7.2` or `0.7.3` run to continue under the `0.7.4`
  runtime policy without rewriting its plan, run metadata, genesis event, or
  existing journal.
- Add an append-only run-policy activation receipt that binds predecessor
  hashes, the journal head, exact artifacts and source obligations,
  authorization material, and the target policy.
- Preserve the source policy on post-activation events while hash-binding the
  effective runtime policy and activation receipt.
- Adopt an existing replacement only through its exact continuity receipt and
  an explicit lifecycle-adoption action. If the platform did not expose the
  actual model, record `actual_model=null / unverified` with evidence.
- Count adopted replacements against Worker capacity and keep ordinary result,
  disposition, source-isolation, re-review, and P0/P1 completion gates.
- Reject missing or changed predecessor material, repeated or concurrent
  activation, downgrade or skipped target policy, and receipt replay.
- Preserve the boundary: this does not repair platform `systemError`, migrate
  business artifacts, or claim measured Token savings.

## 0.7.3 - 2026-07-30

Honest model materialization and replacement-recovery patch release.

- Allow a materialized Worker to record `actual model: unverified` when the
  platform returns a task identity but does not expose the runtime model.
  The requested route remains separate and cannot be relabeled as observed.
- Hash-bind model verification state and evidence in the event journal, and
  preserve unverified status in reduced state, completion output, and
  task-level receipts.
- Add a distinct three-attempt recovery epoch when an authorized replacement
  itself completes without a final answer. Bind it to the replacement
  continuity receipt, replacement thread, source, role, checkpoint, and input.
- Derive recovery stage from the immutable lifecycle instead of trusting a
  caller-supplied `original` or `replacement` label.
- Require canonical run-local recovery receipt paths, sequential single-use
  attempts, and a hard stop after attempt 3.
- Reject replacement-of-replacement, alternate-directory attempt resets, and
  requested-model-as-actual claims.
- Preserve the fail-closed boundary: the Skill does not repair platform
  `systemError` or reveal an actual model the platform never reported.

## 0.7.2 - 2026-07-30

Durable review and missing-result recovery release.

- Add an optional durable domain-and-dissent review profile for long-running
  research and Skill development. The main agent remains the only writer and
  integrator; reviewers stay read-only and consumer output stays result-only.
- Require the main owner to disposition every captured finding. Independent
  sources retain separate evidence and cannot substitute for one another.
- Make P0/P1 blocking severity immutable for durable review, bind disposition
  to the source finding ID, severity, exact text, and text hash, and require
  original-role re-review for resolved or partially adopted blocking findings.
- Treat a completed platform turn without a final answer as `result_pending`.
  Preserve visible progress as hashed evidence, never as a result, and allow at
  most three bounded recovery attempts on the same source thread.
- Permit a replacement source only after a verified 3/3 recovery chain and
  controller authorization. Bind the replacement to the same source, role,
  checkpoint, input, and continuity receipt; it cannot claim original PASS or
  satisfy another source.
- Add a fail-closed legacy adoption path for older durable tasks whose machine
  source IDs or original hashes were never exposed. Capture real available
  material, list unknown fields explicitly, and never fabricate missing
  identity evidence.
- Close two independently reproduced bypasses: replacement results cannot omit
  continuity and masquerade as original, and legacy identities cannot be
  adopted again through another run-local receipt directory.
- Retain the v0.7.1 durable-task, worktree, task-receipt, and platform-bound
  model-launch changes in this formal release.

## 0.7.1 - 2026-07-28

Unpublished engineering milestone folded into v0.7.2. Durable-task and
worktree lifecycle correction.

- Treat explicit user requests for visible Codex threads as user-owned durable
  tasks rather than silently substituting native subagents.
- Proactively recommend durable tasks for bounded, independently checkable
  workstreams that can use smaller context or a lower-cost model, while keeping
  creation subject to explicit user authority.
- Add deterministic execution-surface resolution for main-agent,
  native-subagent, durable-local, and durable-worktree paths.
- Add Git/HEAD/worktree preflight and safe local/main-agent fallbacks for
  read-only, non-Git, unborn-branch, and isolated-writer cases.
- Track queued `clientThreadId` worktree setup separately from materialized
  `threadId`; unresolved setup never authorizes blind duplicate creation.
- Make model selection capability-driven and runtime-availability checked;
  never silently inherit the main agent's model when a worker model is absent.
- Add immutable task-level outcome receipts for successful completion and
  creation, model, worktree, conflict, timeout, and review fallbacks.
- Enforce the 40-second task-list visibility floor in reconciliation generation
  and receipt verification so a caller-supplied short window cannot authorize
  a duplicate durable-task retry.
- Make the platform-bound model resolver a mandatory launch gate. Capability
  descriptions or cost rationale cannot authorize a concrete model, and Terra
  remains blocked without an explicit `user:` request.
- When a native-subagent creation response omits the runtime model, report the
  requested route separately and mark the actual model as unverified.

## 0.7.0 - 2026-07-27

Major context-efficiency, delegation, and task-reliability release.

- Keep the main agent productive while dispatching only bounded,
  independently checkable workstreams.
- Start native subagents with compact context by default; use durable
  background tasks only when independent history, recovery, or reuse matters.
- Protect a six-Worker active-capacity target as four durable tasks plus two
  reserved transient-subagent slots, clamped to the host runtime.
- Explain every Worker before creation, including its role, necessity,
  execution form, inputs, output, permissions, and model; report the actual
  identity and model after materialization.
- Reconcile every durable creation call against visible task state. A returned
  task ID remains authoritative while visibility catches up; ambiguous state
  never triggers blind retry.
- Require hash-bound result receipts before adopting required durable-task
  results, and use delta repair rather than replaying unchanged context.
- Treat Worker results, handoffs, artifacts, and project knowledge as data
  rather than control instructions; label findings as verified, inferred, or
  assumed.
- Re-verify a durable background task's result receipt and bind its hash to the
  journal before allowing archive.
- Add reference-first context ownership, compact project knowledge, optional
  handoffs, and a read-only run measurement report.
- Add non-materializing dispatch previews and an append-only reconciliation
  calibration ledger without pretending snapshot intervals are exact platform
  latency.
- Use a static GPT-5.6 routing table at runtime: Luna for bounded mechanical
  work and Sol for ordinary or difficult judgment. Terra is
  explicit-request-only; Ultra always requires per-node confirmation.
- Improve Windows/Linux PowerShell path portability and retain strict
  write-scope, reparse-point, journal, plan, and completion validation.
- Pass 515 self-test assertions, reject 50 intentional invalid cases, parse all
  25 PowerShell scripts, and pass Skill Creator validation.

The following 0.6.x entries were development candidates folded into this
stable release rather than published as separate stable versions.

## 0.6.5 - Development candidate

Cross-platform and task-materialization safety candidate.

- Make joined project, receipt, artifact, and model-cache paths portable across
  Windows and Linux PowerShell.
- Prevent a successful creation call with a returned task ID from becoming
  `no_match` merely because task-list visibility is delayed.
- Use a provisional forty-second absence-observation floor for ambiguous
  creation results; keep ambiguous evidence at `unknown`.
- Detect parent/child write-scope overlap with the current platform directory
  separator.
- Add a read-only durable-run measurement report for evaluation and diagnosis;
  it does not estimate Tokens or impose a user budget.
- Preserve calibration-advice suppression until verified observations can
  support a non-circular recommendation.

## 0.6.4 - Development candidate

Calibration and pre-materialization inspection candidate.

- Add an append-only, privacy-minimal reconciliation calibration ledger.
- Record observation-window intervals instead of presenting snapshot spans as
  exact platform visibility latency.
- Group calibration evidence by application, host, execution mode, and policy;
  use a defined nearest-rank percentile and suppress window advice because
  observation spans do not measure creation-to-visibility latency.
- Add a non-materializing durable-dispatch preview with Worker, topology,
  model, effort, scope, reference-count, and initial-packet context data.
- Distinguish structural plan eligibility from runtime readiness and defer
  reuse verification until the required handoff exists.
- Fix single-snapshot reconciliation receipts so their numeric representation
  remains stable under hash verification.
- Keep platform task waiting at the model/tool layer; no filesystem script
  pretends to call `wait_threads` or `read_thread`.

## 0.6.2 - Development candidate

Strict-format and control-plane hardening candidate. Plan policy advances to
`0.6.2`.

- Fix the example plan so it is valid RFC 8259 JSON instead of relying on
  PowerShell's tolerant parser.
- Parse every bundled reference JSON with `System.Text.Json` during self-test.
- Reject direct plan-node write scopes under `.orchestrator`; project knowledge
  changes must use the main-agent-owned management script.
- Exercise a real Windows Junction fixture and reject Worker inputs that cross
  the reparse point. Keep the symbolic-link fixture optional where privileges
  do not permit link creation.
- Scale effort from zero Workers for small work to progressive dispatch only
  for genuinely independent breadth.
- Prevent repeated carriage of adopted raw Worker output while accurately
  stating that already-read model context cannot be retroactively deleted.

## 0.6.1 - Unreleased

Context and platform-hardening candidate. Plan policy advances to `0.6.1`.

- Trigger the Skill before any Worker creation while keeping ordinary
  main-agent work on the fast path.
- Add an explicit Codex platform adapter for model bindings, native subagents,
  user-owned tasks, result collection, and failure handling.
- Use the first real low-risk workstream as a platform canary; never create a
  disposable canary Worker.
- Validate packet references, local paths, future dependency artifacts, path
  traversal, and reparse-point boundaries before dispatch.
- Permit platform visibility delays above five seconds without allowing a
  caller to weaken the duplicate-prevention floor.
- Restore orchestration state from compact project artifacts after context
  compaction instead of replaying transcripts.

## 0.6.0 - 2026-07-26

General task-efficiency release. Plan policy advances to `0.6.0`.

- Make the main agent both the sole orchestrator and a required core producer.
- Replace one-time orchestration choice with event-driven work ownership.
- Allow zero, one, or at most two context-disjoint first-wave Workers.
- Start native subagents without inherited conversation history by default.
- Generalize bounded producer ownership beyond manuscripts to every task type.
- Add an optional project-local knowledge pointer catalog with sourced
  adoption, lookup, invalidation, and supersession.
- Reject durable plans that delegate every substantive production node.
- Preserve v0.5.1 reconciliation, receipts, capacity isolation, and explicit
  model-escalation gates.

## 0.5.1 - 2026-07-20

Reliability release for Worker materialization, result collection, and
deterministic retry control. Plan policy advances to `0.5.1`.

- Atomically reserve each activation key, then reconcile every
  independent-background creation call against task-list snapshots before
  deciding whether it succeeded, failed, or may be retried.
- Bind the reservation to a saved role-activation preview and require the
  user-facing explanation before any creation call.
- Adopt one matching thread, deterministically retain one canonical thread
  when duplicates exist, and stop automatic retry while the state is unknown.
- Distinguish native-subagent lifecycle tools from independent-background
  thread tools; `wait_threads` is optional and never required for native
  subagents.
- Require a hash-bound final-result receipt tied to a captured `read_thread`
  response before a required background node can pass the completion gate.
- Derive deterministic retry premises from a canonical run-local manifest
  rather than trusting a caller-supplied fingerprint.
- Require user authorization bound to the exact prior event before launching
  another Worker after a deterministic failure.
- Keep transient failures bounded and preserve delta retry without replaying
  the original context.

## 0.5.0 - 2026-07-19

First stable-channel release. Mode, model-routing, and active-capacity rules
advance the plan policy to `0.5.0`.

- Resolve `auto` deterministically into `quick`, `team`, or `workflow`; reject
  contradictory durable plans.
- Give `lean`, `balanced`, and `quality` exact review strategies without
  exposing a user-facing mode matrix.
- Route bounded mechanical work to Luna and ordinary judgment or complex work
  to Sol. Keep Terra explicit and experimental.
- Require confirmation for model/effort escalation and per-node Ultra use.
- Target six active Workers while protecting two transient-subagent slots from
  four active persistent Workers; clamp to actual runtime capacity.
- Add an on-demand cross-domain research evidence curator and reusable source
  registry contract.
- Record planned and actual model identity in previews, packets, and durable
  run state.

## 0.4.2-beta.1 - 2026-07-18

Role-activation release. Plan policy version advances to `0.4.2`.

- Separate role selection from Worker creation: the main agent may adopt,
  defer, or skip a role instead of filling available seats.
- Require a pre-creation explanation of necessity, task, boundaries, context,
  output, evidence, permissions, dependencies, and omission impact; report the
  actual Worker identity and status after materialization.
- Bind durable explicit approval to `user:` evidence and automatic teaming to
  an existing project-relative `policy:path:` file instead of trusting a naked
  plan flag.
- Enforce a hard maximum of four Workers per root task and reject plan limits
  above four. Failed health probes do not count as created Workers.
- Permit a replacement startup after a confirmed `startup_unmaterialized`
  failure without consuming retry reserve; report materialized Worker count
  separately from launch attempts.
- Add compact on-demand role packs for supply chain, software development,
  creative production, and public equity research; each contains only three or
  four operational roles and exact-role queries do not load neighbors.
- Add a manuscript co-author pattern: the main agent owns the argument spine
  and final merge, methods and domain specialists own bounded sections, and
  one independent academic reviewer enters only at the quality gate.
- Add an optional manuscript profile that distinguishes bounded co-authors,
  research contributors, and independent reviewers without affecting ordinary
  or review-only plans.
- Add deterministic role-activation preview and role-preset query scripts,
  plus negative tests for missing authorization and excessive Worker limits.

## 0.4.1-beta.1 - 2026-07-18

Friction-reduction release. Plan policy version advances to `0.4.1`.

- Reject project-wide placeholder context references; keep selection reasons
  optional, controller-only diagnostics that never enter worker packets.
- Keep artifact catalogs optional and limited to durable projects with repeated
  reuse; ordinary work does not generate a context index.
- Classify stored roles as task, project, or user-owned. Direct temporary
  workers have no persistent role identity; user-owned roles cannot be
  silently rewritten or downgraded.
- Make handoffs opt-in through `context.handoff_required`; nodes that return
  directly no longer write a handoff artifact, and required handoffs carry
  only selected evidence pointers already present in machine state.
- Add a controller-only adoption check before later waves without adding a new
  planner, router, optimizer, score, or generated artifact.
- Enforce progressive waves at runtime and allow dependency-free later workers
  only when their context is truly disjoint and earlier waves are terminal.
- Clarify that the full lifecycle and hash journal apply only to durable work,
  not the direct temporary read-only fast path.

## 0.4.0-beta.1 - 2026-07-18

Context-efficiency release. Plan policy version advances to `0.4.0`.

- Remove user-facing Token budgets and task-total cost prediction from the
  runtime path.
- Add reference-first context, exact input-overlap checks, progressive
  one-worker-first dispatch, risk-only review, and delta-retry policy.
- Add a default short worker packet; full packets are debug-only.
- Bind delta-retry packets to the same hash-checked plan and a node recorded in
  a real failed run; initial attempts cannot self-declare delta mode.
- Add fair benchmark gates for Token use, quality, repetition, coordination,
  recovery, and latency.
- Bind benchmark comparison fingerprints to actual manifest files, reject
  duplicate cases, and prevent command-line weakening of release thresholds.
- Make lean mode and the single-agent fast path the default.
- Skip dedicated low-risk reviewers and sample medium-risk verification.
- Add model-native guidance: do not duplicate GPT-5.6 decomposition, tool
  choice, or ordinary reasoning in the Skill schema.
- Document narrowly adopted ideas from Agent Skills, OpenAI Skill Creator,
  Supabase, Superpowers, Acontext, and oh-my-codex while rejecting
  high-overhead reasoning rituals.

## 0.3.0-beta.1 - 2026-07-18

First public beta release. The plan policy version remains `0.3.0`.

- Add structured role, node, dependency, evidence, and completion contracts.
- Add bounded lifecycle and hash-chained event journal.
- Add fresh/reuse execution context policies and forced rotation boundaries.
- Add immutable compact handoffs with SHA-256 reuse binding.
- Add worker packet rendering and user-defined role generation.
- Add deterministic plan, completion, path, tamper, and self-tests.
- Add English and Simplified Chinese publication documentation.

## Planned

- Verified materialization receipts for real Codex execution surfaces.
- Reference indexes and enforceable read scopes.
- Structured unresolved-risk completion thresholds.
- Runtime adapters for join, loop, and race workflows.
- Telemetry calibration across repeated benchmark cases.
