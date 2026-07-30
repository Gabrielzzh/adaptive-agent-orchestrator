# Workflow contract

## Plan structure

A durable plan is a JSON object with:

- `schema_version`: currently `"1.0"`;
- `policy_version`: currently `"0.7.2"`, used to validate and replay the run;
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
and re-review evidence chains. The same `canonical_finding_id` may appear once
in each source receipt to group overlap while preserving both source records.
Unique findings use new IDs. Receipt paths must be unique per source, and every
profile node requires its own completion check; another role's PASS cannot
satisfy it.
Schema 1.3 durable source findings bind `finding_id`, original `severity`,
exact `text`, and `text_hash`. A disposition repeats and exactly matches that
source identity before adding its canonical cross-source ID. Schema 1.1 and
1.2 receipts remain readable as history but fail closed for durable
disposition and completion. Durable completion always blocks both P0 and P1;
the plan may add P2 but cannot narrow the required set.

When a durable source has no final answer, its node enters `result_pending`.
The only legal continuations are a bounded same-source recovery or, after a
verified 3/3 recovery chain, `replacement_pending` followed by the bound
replacement thread. Neither pending state satisfies a dependency or completion
gate. A replacement result uses the same logical `source_node_id`, declares
`source_kind=replacement`, and binds its replacement-continuity receipt.

For legacy sources, `New-LegacySourceAdoptionReceipt.ps1` captures observable
material and explicitly lists unavailable machine fields. This migration path
does not backfill or infer old hashes. The adoption receipt is single-use and
only permits a replacement at the captured checkpoint; a checkpoint change
requires new authorization and a new source contract.

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
Completion reports both source-decision count and canonical-finding count so
the controller can deduplicate overlap without losing source provenance.

Finishing all nodes is not success if acceptance checks fail.
Every agent or main node completion event includes at least one typed evidence
pointer using `artifact:`, `test:`, `source:`, or `observation:`. A generic
success claim without a type is rejected. Typed pointers improve auditability
but do not prove provenance; the main agent still verifies the referenced
material before marking the node `validated`.
