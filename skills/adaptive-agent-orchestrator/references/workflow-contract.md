# Workflow contract

## Plan structure

A durable plan is a JSON object with:

- `schema_version`: currently `"1.0"`;
- `policy_version`: currently `"0.7.6"`, used to validate and replay the run;
- `run_id`: unique, stable identifier;
- `orchestrator`: the single controller identity and delegation authority;
- `goal`: concrete outcome;
- optional `constraints`: stable task constraints referenced by Worker packets;
- `mode`: `auto`, `quick`, `team`, or `workflow`;
- `risk`: `low`, `medium`, or `high`;
- `limits`: bounded concurrency, total nodes, attempts, reserves, depth, and
  Ultra allocation;
- `efficiency`: reference-first context, progressive dispatch, delta retry,
  risk-based review, overlap ceiling, and main-only fallback;
- `roles`: validated behavioral contracts referenced by nodes;
- `nodes`: work items;
- `completion`: global success and stopping criteria.

Every agent node declares a positive `wave`. A durable run that contains agent
nodes also contains at least one substantive `main` node unless its goal is
explicitly coordination-only or review-only. Read
[context-efficiency.md](context-efficiency.md) before dispatch. A structurally
valid graph is still rejected when it repeats context, front-loads multiple
workers, or bypasses progressive dispatch.

### Immutable predecessor policy activation

Do not rewrite an older run's `plan.json`, `run.json`, or `events.jsonl`.
Activate a supported immutable predecessor only with:

```powershell
pwsh -File scripts/New-RunPolicyActivationReceipt.ps1 `
  -RunDirectory <existing-run> `
  -AuthorizationMaterialPath <existing-run>/materials/policy-migration-authorization.md `
  -ActivationKey "controller:<stable-authority-reference>"

pwsh -File scripts/Test-OrchestrationPlan.ps1 `
  -PlanPath <existing-run>/plan.json -WorkspaceRoot <project-root> `
  -ExistingRunDirectory <existing-run>
```

The append-once receipt binds the predecessor plan hash, run identity,
journal head and event count, controller authorization, every existing
run-local evidence artifact, and the derived source-node/role/thread/checkpoint/
input/recovery/replacement obligations. A changed or substituted binding fails
closed. Post-activation events retain the predecessor `policy_version` and add
the effective runtime policy plus the activation receipt path and hash.
Activation never satisfies a source result, disposition, independent re-review,
or completion gate.

Each node contains:

```json
{
  "id": "review-architecture",
  "kind": "agent",
  "wave": 1,
  "topology": "native-subagent",
  "workflow": "parallel",
  "depends_on": [],
  "role_id": "adversarial-reviewer",
  "purpose": "verification",
  "task": "Find control-plane and recovery failures",
  "capability": "strong",
  "model": "gpt-5.6-sol",
  "model_reason": "Architecture review requires high-ambiguity judgment.",
  "model_authorization": "not-required",
  "effort": "high",
  "read_only": true,
  "write_scope": [],
  "acceptance": ["Every finding includes a reproducible failure scenario"],
  "max_attempts": 1,
  "allow_delegation": false,
  "context": {
    "session_policy": "fresh",
    "continuity_key": "architecture-review",
    "max_prior_turns": 0,
    "inputs": [
      "artifact:artifacts/proposal.md",
      "ref:plan.completion"
    ],
    "excluded": ["Unrelated project conversations"],
    "handoff_required": false,
    "rotate_on": ["system-error", "scope-change", "version-boundary"]
  }
}
```

Allowed node kinds:

- `agent`: work executed by an agent;
- `main`: work retained by the main agent;
- `human-gate`: a decision that requires user input;
- `join`: deterministic dependency barrier.

Allowed topology for agent nodes:

- `native-subagent`;
- `background-thread`.

Workflow values describe behavior, not execution products:

- `direct`;
- `parallel`;
- `pipeline`;
- `dag`;
- `loop`;
- `race`.

Resolve `auto` before materializing a durable plan. `quick` has at most one
fresh native subagent, no handoff, no human gate, and no session reuse. `team`
has at least two independent agent workstreams. `workflow` requires at least
one durable reason: recovery/reuse, a handoff, an agent dependency, multiple
writable agents, a human gate, loop, or race.

## Thread and context contract

Treat the project, role, workstream, and execution thread as different objects:

- the project is the durable container;
- the role is the durable behavioral identity;
- the workstream is the bounded line of responsibility;
- the thread is one execution session that may be rotated.

Every agent node declares:

- `role_activation`: `necessity`, `omission_impact`, `user_disposition`
  (`approved` or `auto-authorized`), and typed `authorization_evidence`
  (`user:` or `policy:path:`) recorded after the pre-creation preview;

`authorization_evidence` is an auditable pointer, not a self-authorizing
credential. The controller verifies a `user:` pointer against current user
context before materialization; deterministic scripts cannot prove that
conversation authority cryptographically. Scripts do verify that a
`policy:path:` pointer names an existing safe project-relative file.

Every agent node also declares the model resolved at dispatch:

- `model`: a Worker model available on the selected platform;
- `model_reason`: a short task-specific reason;
- `model_authorization`: `not-required`, `user-confirmed`,
  `policy-confirmed`, or `experimental-user-request`.
- `model_authorization_evidence`: required for every non-default authorization;
  use `user:<message-or-request>` or a verified
  `policy:path:<project-relative-policy-file>`.

The default automatic Codex pool is defined in
[platform-codex.md](platform-codex.md). Terra requires
`experimental-user-request`. Model or effort escalation requires
`user-confirmed` or a verified bounded `policy-confirmed` authorization.
Creation reports the actual model; it never treats the planned model as proof
of materialization. When the platform omits the actual model, the materialized
event records `model_verification_state=unverified`, leaves `model_id` empty,
and binds source or observation evidence for that limitation. Completion and
task receipts preserve the unverified state instead of claiming the requested
route was observed. Retry routing derives the prior actual model and planned
effort from the validated prior run; callers cannot restate those values.

## Optional manuscript profile

Use `manuscript_profile` only when specialist roles are being activated for a
paper. Omit it for ordinary work and for a simple main-agent draft with no
specialist Worker.

```json
{
  "manuscript_profile": {
    "mode": "coauthoring",
    "lead_author_node_id": "integrate",
    "lead_author_owns": [
      "argument-spine",
      "abstract",
      "conclusion",
      "final-merge"
    ]
  }
}
```

Every agent node in this profile declares `manuscript_contribution.mode` as
`co-author`, `independent-review`, or `research`. A co-author also declares an
exact `section_scope` and uses a `proposal-only` or `scoped-write` role. An
independent reviewer is read-only with `purpose: verification`. `coauthoring`
requires at least one co-author; use `review-only` when specialists truly are
only an independent quality gate.

## Optional durable review profile

Use `durable_review_profile` only for long-running research or Skill
development where domain evidence and independent dissent recur across at
least two named milestones. Omit it for one-off work, ordinary implementation,
or a single final review.

```json
{
  "durable_review_profile": {
    "mode": "domain-dissent",
    "main_owner_node_id": "integrate",
    "domain_node_ids": ["domain-research"],
    "dissent_node_ids": ["adversarial-review"],
    "milestone_ids": ["method-1", "method-2"],
    "consumer_output": "result-only"
  }
}
```

Every listed domain or dissent node must be a read-only
`background-thread` agent with delegation disabled, and its role lifetime must
be `project` or `user-owned`. Domain and dissent node sets must be distinct.
The profile does not authorize automatic seat filling: each role still needs
the normal activation explanation and user authorization.

The main owner collects results and answers findings one by one. It creates an
immutable thread-result receipt whose `pending_findings` binds extracted
findings to the complete captured report before adoption decisions. It then
uses `New-ReviewDispositionReceipt.ps1` to bind each decision to that source
receipt. Every decision records the exact finding, P0/P1/P2 severity,
adopted/partially-adopted/rejected/deferred disposition, rationale,
open/resolved status, typed evidence, a stable `canonical_finding_id`, and
re-review status bound to the original source node. Adopted or
partially adopted P0/P1 revisions require completed re-review by the original
role before resolution. Workers do not message one another or write project
files; the main owner routes accepted changes and requests re-review.

For multiple durable review roles, keep separate capture, result, disposition,
and re-review evidence chains. The same `canonical_finding_id` may group
multiple distinct `source_finding_id` occurrences, including repeated
observations from one source across checkpoints. Canonical grouping never
deletes or substitutes a source occurrence. Unique findings use new IDs.
Receipt paths must be unique per source, and every
profile node requires its own completion check; another role's PASS cannot
satisfy it.
Schema 1.3 durable source findings bind `finding_id`, original `severity`,
exact `text`, and `text_hash`. A disposition repeats and exactly matches that
source identity before adding its canonical cross-source ID. Schema 1.1 and
1.2 receipts remain readable as history but fail closed for durable
disposition and completion. Durable completion always blocks both P0 and P1;
the plan may add P2 but cannot narrow the required set.

The immutable plan disposition paths define the first milestone baseline. For
every later `milestone_id`, create each result with `-MilestoneId` and one
shared run-local `-CheckpointMaterialPath`, then create the matching
source-specific disposition. Record the exact set in a run-local selection
file:

If the first milestone needs another checkpoint before the next declared
milestone, do not overwrite its baseline aliases or select files by mtime.
Create an append-only revision authorization first:

```powershell
pwsh -File scripts/New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1 `
  -RunDirectory <run> -MilestoneId method-1 `
  -CheckpointMaterialPath <run>/materials/method-1-checkpoint-02.json `
  -InputManifestPath <run>/materials/method-1-checkpoint-02-input.json `
  -ReviewMaterialManifestPath <run>/materials/method-1-review-materials.json `
  -ExcludedEvidenceManifestPath <run>/materials/method-1-excluded.json `
  -AuthorizationMaterialPath <run>/materials/method-1-authorization.md `
  -AcceptanceAuthorizationMaterialPath `
    <run>/materials/method-1-acceptance-authorization.json `
  -SelectionKey "controller:<prebound-selection-reference>" `
  -ActivationKey "controller:<stable-authority-reference>"
```

`-SelectionKey` is the stable authority seed. The authorization derives and
records the only permitted key as
`<user-or-controller>:milestone-revision-selection:<revision_id>`, so the same
seed cannot be replayed across runs or revisions.

The authorization is valid only while plan index 0 is active. It binds the
current journal head, shared checkpoint/input, exact source/role/thread set,
read-only/no-delegation contracts, review inputs, main-acceptance constraint,
the one permitted selection key, and a complete excluded-evidence inventory.
The selection caller cannot replace that pre-bound key. The inventory enumerates every
related pre-authorization event sequence/hash plus capture, recovery, result,
and disposition path/file/internal hashes. Omitting or rewriting one fails
before source re-arm.

Each required source then uses `Add-OrchestrationEvent.ps1 -Status running`
with `-MilestoneRevisionAuthorizationReceiptPath`; this is the sole narrow
`adopted -> running` exception and is single-use per source. After all sources
produce fresh post-anchor `completed -> validated -> adopted` chains, select
them once with
`New-DurableReviewMilestoneRevisionSelectionReceipt.ps1`.

Selection rejects partial source sets, excluded chains, cross-source/thread or
cross-checkpoint substitutions, and any prior occurrence that disappears or
changes `source_finding_id`, severity, exact text/hash, or canonical ID.
Resolved and open occurrences are both conserved; new occurrences may be
appended. Completion overlays only the terminal valid first-milestone revision
bindings. Open P0/P1 still block overall completion. A selected revision does
not itself provide final main-owner acceptance.

```json
[
  {
    "source_node_id": "domain-research",
    "result_receipt_path": "receipts/domain.method-2.thread-result-receipt.json",
    "disposition_receipt_path": "receipts/domain.method-2.disposition.json"
  },
  {
    "source_node_id": "adversarial-review",
    "result_receipt_path": "receipts/review.method-2.thread-result-receipt.json",
    "disposition_receipt_path": "receipts/review.method-2.disposition.json"
  }
]
```

Activate only the next declared milestone:

```json
{
  "schema_version": "1.0",
  "milestone_id": "method-2",
  "main_node_id": "integrate",
  "acceptance_key": "controller:method-2-main-acceptance",
  "evidence_material_path": "materials/method-2-main-acceptance.md",
  "evidence_material_hash": "<sha256>"
}
```

```powershell
pwsh -File scripts/New-DurableReviewMilestoneActivationReceipt.ps1 `
  -RunDirectory <run> -MilestoneId method-2 `
  -SelectionPath <run>/materials/method-2-selection.json `
  -AuthorizationMaterialPath <run>/materials/method-2-authorization.md `
  -AcceptanceAuthorizationMaterialPath `
    <run>/materials/method-2-acceptance-authorization.json `
  -ActivationKey "controller:<stable-authority-reference>"
```

Activation is append-only and binds the immutable plan/run identity, journal
head, previous milestone chain, current source result/disposition paths and
hashes, source/thread identity, shared checkpoint, selection, and controller
authorization. It also appends one hash-bound journal event. Completion uses
the terminal valid activation chain, never a filename timestamp or unactivated
"latest" receipt. Missing, duplicated, skipped, changed, cross-run,
cross-source, or cross-checkpoint bindings fail closed. Policy activation is a
different protocol and cannot select a milestone. Activation also anchors the
only permitted main-owner acceptance key and the exact evidence path and hash;
the later acceptance receipt cannot choose replacements.

When an active milestone intentionally leaves P0/P1 occurrences for a later
declared milestone, final main-owner acceptance is correctly unavailable. To
avoid deadlocking the declared sequence, the next activation may use the
strict scoped carry-forward gate:

```powershell
pwsh -File `
  scripts/New-DurableReviewScopeTransitionAuthorizationReceipt.ps1 `
  -RunDirectory <run> -MilestoneId method-3 `
  -SelectionPath <run>/materials/method-3-selection.json `
  -ScopeTransitionAuthorizationMaterialPath `
    <run>/materials/method-2-to-method-3-scope-transition.md `
  -ScopeTransitionKey "controller:<stable-scope-transition-reference>" `
  -ActivationKey "controller:<stable-scope-authorization-reference>"

pwsh -File scripts/New-DurableReviewMilestoneActivationReceipt.ps1 `
  -RunDirectory <run> -MilestoneId method-3 `
  -SelectionPath <run>/materials/method-3-selection.json `
  -AuthorizationMaterialPath <run>/materials/method-3-authorization.md `
  -AcceptanceAuthorizationMaterialPath `
    <run>/materials/method-3-acceptance-authorization.json `
  -ScopeTransitionAuthorizationReceiptPath `
    <run>/receipts/durable-review-milestone.method-3.scope-transition-authorization.json `
  -ActivationKey "controller:<stable-activation-reference>"
```

The first command appends one authorization receipt/event before activation and
pre-binds the run, previous activation, exact next milestone, selection
path/hash, checkpoint, controller material path/hash, scope key, and conserved
occurrence counts. The second command produces activation schema 1.2 and must
consume that exact receipt. Replacing only the later activation's scope key or
controller material cannot replace the earlier authorization.

This route is permitted only when the previous active chain has no final
acceptance and still has at least one open P0/P1 occurrence after the selected
next-stage review. Every prior open occurrence must reappear under the same
source, durable thread, source finding ID, canonical ID, severity, exact text,
and text hash. The next source-specific disposition may resolve it only with
same-source re-review, or carry it forward as open. Omission, downgrade, text
drift, cross-source transfer, mixed checkpoint selection, missing
authorization, or a fully resolved prior inventory fails before activation
journal write. The activation receipt and event record the exact prior count,
resolved count, remaining count, occurrence inventory, and authorization
receipt.

Scoped carry-forward means only that the current milestone boundary was
reviewed and the remaining work was conserved into the next declared scope. It
is not `milestone-accepted`, does not validate the main node, never satisfies
completion, and cannot hide an open P0/P1. If no prior blocker remains, use
`New-DurableReviewMilestoneAcceptanceReceipt.ps1` instead.

After every active non-baseline milestone has resolved all P0/P1 findings, the
main integration owner must record a new acceptance:

```powershell
pwsh -File scripts/New-DurableReviewMilestoneAcceptanceReceipt.ps1 `
  -RunDirectory <run> -MilestoneId method-2
```

The acceptance receipt and its append-only journal event bind the exact
activation receipt, source-binding hash, shared checkpoint, main-owner node,
and run-local evidence. Its event sequence must be later than activation.
Completion never reuses a main node's `validated` state from the baseline or an
earlier milestone. Missing, duplicated, changed, or pre-activation acceptance
fails closed. The event directly repeats the anchored key and evidence
path/hash; coherently re-signing only the acceptance receipt and chain-tail
event cannot replace the earlier activation authorization anchor.

When a durable source has no final answer, its node enters `result_pending`.
An original source recovery is namespaced by a deterministic cycle binding the
run, source, role, thread, active milestone and activation epoch, checkpoint,
and input manifest. A new checkpoint/input starts at attempt 1 and has its own
three-attempt ceiling; receipts cannot chain, replay, or reset across cycles.
When the preceding checkpoint has a verified
`completed -> validated -> adopted` result and source-specific disposition,
an unused schema 1.2 attempt-1 receipt for a different checkpoint/input may
authorize exactly one `adopted -> result_pending` re-entry. The new event binds
the preceding adopted sequence/hash and the new cycle, milestone activation,
checkpoint, and input hashes. This is not a general reopening of `adopted`.
When a later milestone activation selected a newer source-specific result and
disposition without appending another node lifecycle chain, that terminal,
fully verified activation binding is the preceding checkpoint for this narrow
gate. Re-entry additionally binds its exact result/disposition paths and hashes
plus the activation receipt and journal event. The source, role, durable task,
milestone, activation epoch, checkpoint, and input must all match; an older
lifecycle receipt, unselected file, changed activation, or another source
cannot substitute.
The only legal continuations are a bounded same-source recovery or, after a
verified 3/3 same-cycle recovery chain, `replacement_pending` followed by the
bound replacement thread. Neither pending state satisfies a dependency or completion
gate. A replacement result uses the same logical `source_node_id`, declares
`source_kind=replacement`, and binds its replacement-continuity receipt.
If the replacement has no final answer, its recovery receipts use a separate
`replacement` stage and namespace, bind the parent replacement-continuity hash,
and remain limited to three attempts on that replacement thread. Exhaustion
stays blocked and cannot create a replacement-of-replacement.

For legacy sources, `New-LegacySourceAdoptionReceipt.ps1` captures observable
material and explicitly lists unavailable machine fields. This migration path
does not backfill or infer old hashes. The adoption receipt is single-use and
only permits a replacement at the captured checkpoint; a checkpoint change
requires new authorization and a new source contract.

When the final declared milestone still has open P1 obligations and more
review milestones are required, create a successor run. Never edit the old
plan, repeat its last milestone, copy its directory, or start an unrelated run.
The successor plan declares:

```json
{
  "successor_review_profile": {
    "predecessor_run_id": "old-run-id",
    "predecessor_active_milestone_id": "old-final-milestone",
    "predecessor_checkpoint_material_hash": "<sha256>",
    "source_node_ids": ["domain-research", "adversarial-review"]
  }
}
```

Its ordered source set must exactly match the predecessor durable profile.
Every source remains read-only, keeps the same role contract, and explicitly
reuses the same durable thread. First export the immutable predecessor state:

```powershell
pwsh -File scripts/New-DurableReviewSuccessorExportReceipt.ps1 `
  -PredecessorRunDirectory <old-run> `
  -SuccessorPlanPath <new-plan> `
  -SuccessorRunDirectory <new-run> `
  -AuthorizationMaterialPath <old-run>/materials/successor-authorization.md `
  -ActivationKey "controller:<stable-authority-reference>"
```

The append-only export binds the old plan/run/genesis, effective policy, final
journal head and count, terminal milestone activation, shared checkpoint,
every source/role/thread/result/disposition identity, every unresolved P1's
source and canonical IDs, exact text/hash, original severity and status, the
new run path/ID/plan hash/milestones, and controller authorization. One
predecessor has one export; a changed plan, journal, source, checkpoint,
obligation, target plan, or target directory fails closed.

Then create the successor:

```powershell
pwsh -File scripts/New-OrchestrationSuccessorRun.ps1 `
  -PlanPath <new-plan> -RunDirectory <new-run> `
  -WorkspaceRoot <workspace> `
  -PredecessorRunDirectory <old-run> `
  -PredecessorExportReceiptPath `
    <old-run>/receipts/durable-review-successor.export.json
```

This creates a new run/genesis and one append-only adoption receipt/event. A
bare genesis or copied directory cannot complete. Completion re-derives the
export from the predecessor, validates both run identities, and treats every
inherited P1 as a baseline obligation. Each must reappear under the same source
with unchanged ID, canonical ID, severity and exact text/hash, then be resolved
and re-reviewed by that source. The successor may add findings, but it cannot
omit, downgrade, merge across sources, or claim completion from adoption alone.

If a successor is cancelled before its first durable milestone because the
controller changed the checkpoint, do not restart the cancelled node, reset its
attempt, edit the journal, or reuse the ordinary final-milestone export. A
strict abandoned-successor roll-forward is allowed only when:

- the run is already a valid first-generation successor;
- no durable milestone or main acceptance was activated;
- at least one durable source is terminal `cancelled`;
- its cancellation binds `observation:no-review-message-dispatched`;
- no source has a result lifecycle or dispatched-review evidence.

Capture the next checkpoint, every newly discovered P1, any unactivated
result/disposition receipts as explicitly non-completion evidence, and the
controller authorization inside the abandoned run. The fresh plan uses the
same ordered source/role/thread set, declares
`predecessor_active_milestone_id = abandoned-before-first-milestone`, and gives
each source enough `max_attempts` to preserve already consumed attempts.

```powershell
pwsh -File scripts/New-AbandonedSuccessorAuthorizationReceipt.ps1 `
  -AbandonedRunDirectory <abandoned-run> `
  -SuccessorPlanPath <fresh-plan> -SuccessorRunDirectory <fresh-run> `
  -CheckpointMaterialPath <abandoned-run>/materials/<checkpoint>.json `
  -AdditionalFindingRecordsPath <abandoned-run>/materials/<findings>.json `
  -UnactivatedEvidenceManifestPath <abandoned-run>/materials/<manifest>.json `
  -AuthorizationMaterialPath <abandoned-run>/materials/<authorization>.md `
  -ActivationKey "controller:<stable-authority-reference>"

pwsh -File scripts/New-AbandonedSuccessorExportReceipt.ps1 `
  -AbandonedRunDirectory <abandoned-run> `
  -SuccessorPlanPath <fresh-plan> -SuccessorRunDirectory <fresh-run> `
  -CheckpointMaterialPath <abandoned-run>/materials/<checkpoint>.json `
  -AdditionalFindingRecordsPath <abandoned-run>/materials/<findings>.json `
  -UnactivatedEvidenceManifestPath <abandoned-run>/materials/<manifest>.json `
  -AuthorizationReceiptPath `
    <abandoned-run>/receipts/durable-review-abandoned-successor.authorization.json

pwsh -File scripts/New-AbandonedSuccessorRun.ps1 `
  -PlanPath <fresh-plan> -RunDirectory <fresh-run> `
  -WorkspaceRoot <workspace> -AbandonedRunDirectory <abandoned-run> `
  -AbandonedExportReceiptPath `
    <abandoned-run>/receipts/durable-review-abandoned-successor.export.json
```

The authorization, export, and adoption are single-use and append-only. Export
cannot generate or replace controller authorization: it consumes the earlier
authorization receipt/event and must preserve its material hash and activation
key. Together they bind the original successor adoption chain, journal
head/count, cancelled event, source
identities, checkpoint, authorization, all inherited and added P1 occurrences,
target plan/run/milestones, and the non-completion evidence manifest. The fresh
genesis carries consumed attempt counts in `source-attempt-carried` events.
Completion stays blocked until every inherited occurrence has a current,
same-source disposition and re-review. This path cannot create a replacement
source, revive the old run, merge duplicate findings, or turn an unactivated
receipt into completion evidence.

- `session_policy`: `fresh` by default, or explicitly justified `reuse`;
- `continuity_key`: stable workstream identity;
- optional `selection_reason`: controller-only diagnostic justification for
  borderline discovery or overlap cases; never render it into a worker packet;
- `inputs`: typed `ref:`, `path:`, `source:`, or `artifact:` references that
  the worker may open on demand. `New-WorkerPacket.ps1` validates local plan,
  path, and artifact references before rendering; `source:` identifiers remain
  subject to the source tool's own lookup;
- `excluded`: nearby context that must not be inherited;
- `handoff_required`: whether a later session must resume or reuse this work;
- when `handoff_required` is true, `handoff_path` is a unique compact state
  artifact and `handoff_max_chars` is 500–8000 characters for the complete
  serialized handoff, not only its summary;
- `rotate_on`: at least `system-error`, `scope-change`, and
  `version-boundary`;
- `max_prior_turns`: `0` for fresh sessions and `1..6` for reuse.

Only a background thread may use `reuse`. Reuse also requires
`prior_thread_id`, `prior_handoff`, `prior_handoff_hash`, and `reuse_reason`.
`prior_handoff_hash` is the SHA-256 digest of the exact stored handoff file.
Handoffs are append-once artifacts: never overwrite a prior execution's
handoff. Before dispatch, the controller must verify the file hash, read the
actual thread, and reject reuse when either is missing or changed, the thread
is unhealthy or over the turn limit, or it no longer represents the same
workstream. Never fork a long thread merely to preserve identity; that copies
the context problem.

Do not generate a handoff when `handoff_required` is false. Every required
handoff includes an exact `next_action` and an explicit
`risk_disposition` of `none`, `open`, or `mitigated`; do not substitute a
generic default. Its evidence list contains only relevant pointers selected
from the node's machine-recorded evidence. A fresh context must not carry any
reuse-only field.

## Dependency and cycle rules

- Every dependency must reference an existing node.
- A later node becomes ready only after each dependency is explicitly
  `adopted`, not merely completed or validated. Validation proves a result;
  adoption records that the controller will use it.
- Node IDs must be unique.
- The dependency graph must be acyclic.
- A loop is represented by one bounded `loop` node with explicit
  `max_iterations` and `stop_condition`; never create a graph cycle.
- A race must define `winner_condition` and `cancel_losers: true`.
- A human gate must define the default safe action for timeout or absence.
- An Ultra node sets both `capability` and `effort` to `ultra`, remains
  read-only, and records `ultra_authorization` as `user-requested`. The
  controller never upgrades to Ultra automatically: a failed cheaper attempt
  is evidence, not authority to spend more.

## Ownership rules

- The main agent owns at least one substantive production node in a durable
  run unless the goal explicitly states coordination-only or review-only.
- A Worker owns one bounded artifact, investigation, section, module, dataset,
  design surface, or verification result.
- The main agent continues dependency-ready production while Workers run.
- `read_only: true` requires an empty `write_scope`.
- A `read-only` or `proposal-only` role may bind only to a read-only node.
- A node may be more restrictive than its role, never less restrictive.
- Every writable node lists exact files or directories.
- Write scopes are project-relative, canonical, free of traversal and wildcard
  syntax, and resolved against real paths before dispatch to detect links.
- Concurrent writable nodes may not overlap scopes.
- The main agent owns final integration even when workers write disjoint files.
- Return a defect to the original producer when possible; do not create a new
  integrator Worker to restate or merge results.

## Completion contract

Global completion must define:

- required nodes;
- structured artifact checks with a project-relative `path`, `type`, and
  optional minimum size or item count;
- structured evidence checks naming a node and minimum evidence entries;
- unresolved-risk threshold;
- termination conditions for exhausted execution slots, repeated failure, unavailable tools, and
  rejected approvals.

When `durable_review_profile` is present, completion also defines one
`review_disposition_checks` entry for every listed domain and dissent node:

```json
{
  "source_node_id": "adversarial-review",
  "path": "receipts/adversarial-review.disposition.json",
  "blocking_severities": ["P0", "P1"]
}
```

The disposition receipt must answer every finding in the bound thread-result
receipt exactly once. Completion fails when a configured blocking severity is
still open, when a finding is omitted, when the source result changes, or when
the receipt hash is invalid. P2 may remain open or deferred with rationale and
evidence. A resolved adopted or partially adopted P0/P1 decision also requires
typed evidence that the original role completed re-review.
The configured paths remain the first milestone baseline. A validated
milestone activation chain replaces them only for its exact active milestone;
historical paths and receipts remain unchanged and replayable.
Completion reports both source-decision count and canonical-finding count so
the controller can deduplicate overlap without losing source provenance.

Finishing all nodes is not success if acceptance checks fail.
Every agent or main node completion event includes at least one typed evidence
pointer using `artifact:`, `test:`, `source:`, or `observation:`. A generic
success claim without a type is rejected. Typed pointers improve auditability
but do not prove provenance; the main agent still verifies the referenced
material before marking the node `validated`. Pass each pointer as a separate
`Evidence` array item. A shell-collapsed value such as
`artifact:path,observation:note` is rejected before journal append; an ordinary
comma inside one value remains valid when it does not introduce another typed
pointer.
