# Changelog

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
