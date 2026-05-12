# Single-Service Model Routing Design

## Goal

Run one Symphony launchd service for `mirofish-quant-engine` while routing each Linear issue to one of multiple Codex command profiles based on dedicated complexity labels.

## Approved business rule

- Default profile: `codex-mimo`
  - Command-line profile for `mimo/mimo-v2.5-pro`.
  - Handles ordinary and medium-or-lower complexity work.
- High-complexity profile: `codex-max`
  - Command-line profile for the heihei GPT-5.5 channel.
  - Handles issues explicitly labeled `complexity/high`.
- Global concurrency: `agent.max_concurrent_agents: 2`.
  - Profile-level concurrency limits are not part of the first version.
  - If two high-complexity issues are dispatched and two global slots are free, both may use `codex-max`.

## Architecture

```text
macOS launchd
  │
  ▼
Symphony service: mirofish
  │
  ▼
workflows/mirofish-quant-engine.WORKFLOW.md
  │
  ├─ agent.max_concurrent_agents = 2
  ├─ codex.default_profile = codex-mimo
  ├─ codex.profiles.codex-mimo.command
  ├─ codex.profiles.codex-max.command
  └─ codex.routes by Linear labels
        │
        ▼
Linear issue labels
  │
  ├─ complexity/high → codex-max
  └─ otherwise       → codex-mimo
```

Only the Symphony service is long-running. Codex command profiles are not resident worker daemons; each agent run starts the selected app-server command as a child process and stops it when the run completes.

## Proposed workflow configuration

```yaml
agent:
  max_concurrent_agents: 2
  max_turns: 20

codex:
  default_profile: codex-mimo
  profiles:
    codex-max:
      command: /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-max
    codex-mimo:
      command: /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-mimo
  routes:
    - profile: codex-max
      labels:
        any:
          - complexity/high
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
```

`codex.command` remains useful as a backward-compatible single-profile form, but new multi-profile workflows should use `default_profile`, `profiles`, and `routes`.

## Routing semantics

1. Read `issue.labels` from the normalized Linear issue.
2. Evaluate `codex.routes` in order.
3. A route matches when any configured `labels.any` value equals one of the issue labels after trimming and case-insensitive comparison.
4. The first matching route selects its `profile`.
5. If no route matches, use `codex.default_profile`.
6. Resolve the selected profile to `codex.profiles[profile].command`.
7. Launch that command for the current app-server session.

## Validation rules

Configuration validation should reject:

- missing `default_profile` when `profiles` is present;
- `default_profile` not found under `profiles`;
- route `profile` values not found under `profiles`;
- profiles without a non-empty `command`;
- route entries without labels.

For backward compatibility, an existing config with only `codex.command` remains valid and behaves exactly as before.

## Error behavior

If the selected command fails to start or the app-server session fails, use the existing worker failure and retry path. Do not automatically fall back from `codex-max` to `codex-mimo`, because that could allow a high-complexity task to be attempted by the wrong model.

## Implementation boundary

Likely code changes:

- `elixir/lib/symphony_elixir/config/schema.ex`
  - Add Codex profile and route parsing.
- `elixir/lib/symphony_elixir/config.ex`
  - Add a resolver that selects runtime Codex settings from an issue.
- `elixir/lib/symphony_elixir/agent_runner.ex`
  - Resolve the selected profile before starting the app-server session.
- `elixir/lib/symphony_elixir/codex/app_server.ex`
  - Accept the selected command through opts/session state instead of reading only `Config.settings!().codex.command`.
- `workflows/mirofish-quant-engine.WORKFLOW.md`
  - Switch to `codex-max`/`codex-mimo` profiles and `complexity/high` routing.
- `bin/agent-commands/`
  - Add repo-local wrappers for `codex-max` and `codex-mimo`.

## Testing strategy

- Config parsing tests:
  - legacy `codex.command` remains valid;
  - multi-profile config validates;
  - invalid default or route profile is rejected.
- Routing tests:
  - `complexity/high` selects `codex-max`;
  - missing labels select `codex-mimo`;
  - unrelated labels select `codex-mimo`;
  - label matching is case-insensitive and trims whitespace.
- Agent launch tests:
  - app-server start receives the selected command for the issue.
- Workflow validation:
  - `workflows/mirofish-quant-engine.WORKFLOW.md` parses and resolves both profiles.

## Out of scope for first version

- Profile-level concurrency limits.
- Automatic model fallback.
- Multiple labels such as `complexity/medium` or explicit `model/*` overrides.
- Dashboard controls for switching profiles at runtime.
- Multiple launchd services for the same project.
