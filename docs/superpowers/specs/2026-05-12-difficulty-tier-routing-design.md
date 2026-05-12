# Difficulty Tier Routing Design

## Goal

Replace Symphony's current default-profile Codex routing with explicit three-tier difficulty routing. A Symphony-managed Linear issue must have exactly one difficulty label before any worker is started.

## Problem

The current multi-profile routing supports a default profile. In the `mirofish-quant-engine` workflow, only `complexity/high` is explicit; every other issue falls through to `codex-mimo`. That is convenient, but it hides missing labels and makes medium/low routing ambiguous.

The desired behavior is stricter:

- `difficulty/high` routes to the high-capability worker.
- `difficulty/medium` routes to the medium/default-cost worker.
- `difficulty/low` routes to the low-cost worker.
- Missing difficulty labels are invalid.
- Multiple difficulty labels on the same issue are invalid.
- Invalid difficulty labels must prevent worker startup.

Linear labels are not a native mutually-exclusive field, so Symphony must enforce the exclusivity rule before dispatching.

## Label contract

Symphony recognizes exactly these difficulty labels, case-insensitively after trimming whitespace:

```text
difficulty/high
difficulty/medium
difficulty/low
```

For each issue:

- zero recognized difficulty labels => `{:error, {:missing_difficulty_label, issue_id_or_identifier}}`
- one recognized difficulty label => select the matching configured profile
- two or more recognized difficulty labels => `{:error, {:ambiguous_difficulty_labels, labels}}`

Unrelated labels such as `backend`, `bug`, or `area/api` do not affect difficulty selection.

## Workflow config shape

Keep the existing `codex.profiles` and `codex.routes` shape for this iteration, but change the multi-profile contract:

```yaml
codex:
  profiles:
    codex-max:
      command: /Users/deepzen/works/symphony/bin/agent-commands/codex-max
    codex-mimo:
      command: /Users/deepzen/works/symphony/bin/agent-commands/codex-mimo
    codex-low:
      command: /Users/deepzen/works/symphony/bin/agent-commands/codex-low
  routes:
    - profile: codex-max
      labels:
        any:
          - difficulty/high
    - profile: codex-mimo
      labels:
        any:
          - difficulty/medium
    - profile: codex-low
      labels:
        any:
          - difficulty/low
```

`codex.default_profile` is removed for multi-profile workflows. Legacy single-command workflows using `codex.command` remain supported and bypass difficulty routing, because they have no profile choice to make.

## Dispatch behavior

`Orchestrator` must validate difficulty routing before spawning `AgentRunner`. This is stricter than validating inside `AgentRunner`: once `Task.Supervisor.start_child/2` is called, a worker process already exists, so the system has not met the requirement that invalid labels prevent worker startup.

The dispatch path becomes:

1. Orchestrator selects an active issue as today.
2. Orchestrator resolves runtime settings for that issue before `Task.Supervisor.start_child/2`.
3. If the issue has no exactly-one difficulty route, Orchestrator records a visible dispatch error and does not spawn `AgentRunner`.
4. If the issue has exactly one difficulty route, Orchestrator spawns `AgentRunner` with resolved runtime settings.
5. AgentRunner creates the workspace and starts the selected Codex profile using the runtime settings it received.

`AgentRunner` may keep a defensive runtime-settings fallback for direct tests and legacy callers, but the production dispatch path should resolve the profile before workspace creation and before worker-process creation.

The current workspace safety checks remain unchanged.

## Status and logs

Invalid difficulty labeling must be visible:

- structured logs include `issue_id`, `issue_identifier`, and the error tuple;
- terminal/dashboard state should show the issue in the existing Backoff queue with a clear routing error rather than silently ignoring it;
- no worker PID, workspace path, or app-server session should be created for invalid labels.

For the first version, reuse `retry_attempts` and the existing Backoff queue instead of adding a separate blocked section. The retry error text must make the label problem explicit, for example:

```text
missing difficulty label: expected exactly one of difficulty/high,difficulty/medium,difficulty/low
ambiguous difficulty labels: difficulty/high,difficulty/low
```

This design intentionally does not auto-edit Linear labels. The first version should fail visibly and let the human/project manager fix the label.

## Validation rules

For multi-profile config:

- `codex.profiles` must be a non-empty map when using routes.
- `codex.default_profile` must be absent or ignored; new workflows should not set it.
- `codex.routes` must include exactly one route for each of:
  - `difficulty/high`
  - `difficulty/medium`
  - `difficulty/low`
- each difficulty route must reference an existing profile.
- each route's `labels.any` must include at least one non-empty label, as today.

If more labels are listed in `labels.any`, they are treated as aliases, but the first rollout should use one canonical label per route to keep behavior auditable.

## Tests

Add or update tests to cover:

- config accepts three difficulty routes without `default_profile`;
- config rejects a multi-profile workflow that still relies on `default_profile` without complete difficulty routes;
- `difficulty/high`, `difficulty/medium`, and `difficulty/low` select their configured profiles;
- unlabeled issues return `{:error, {:missing_difficulty_label, _}}`;
- issues with multiple recognized difficulty labels return `{:error, {:ambiguous_difficulty_labels, _}}`;
- unrelated labels do not count as difficulty labels;
- Orchestrator does not spawn AgentRunner when difficulty routing fails;
- AgentRunner does not create a workspace when difficulty routing fails in direct-call fallback tests;
- Orchestrator snapshot exposes invalid-label issues through the Backoff queue error field;
- legacy `codex.command` mode still works with any labels.

## Rollout

1. Implement resolver and schema changes behind the existing `codex.profiles/routes` config shape.
2. Update `workflows/mirofish-quant-engine.WORKFLOW.md` to three difficulty routes and no default profile.
3. Add a `codex-low` wrapper or temporarily map low to an existing low-cost command if no distinct low worker exists yet.
4. Restart the running `mirofish` service from `~/works/symphony` after tests pass.

## Open decision

The only unresolved operational decision is the actual low-tier command. The design needs a `codex-low` profile name, but the command can either be a new wrapper or point to the same command as `codex-mimo` until a cheaper low-tier worker is available.
