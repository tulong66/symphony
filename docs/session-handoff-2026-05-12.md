# Symphony Session Handoff — 2026-05-12

## Restart instruction

After reopening Claude Code, start from the system-disk project directory:

```bash
cd ~/works/symphony
claude
```

Then ask Claude to read this file:

```text
请读取 docs/session-handoff-2026-05-12.md，并根据里面的状态继续推进。
```

Do not continue development from the old external-volume checkout unless explicitly needed for comparison:

```text
/Volumes/HY2TB/projects/symphony
```

Use this as the main working copy from now on:

```text
/Users/deepzen/works/symphony
```

## Repository / remote state

The Symphony repository was forked from OpenAI to the user's GitHub account.

Current intended remotes for both the external checkout and the system-disk checkout:

```text
origin   https://github.com/tulong66/symphony.git
upstream https://github.com/openai/symphony.git
```

The reason for the fork: we cannot push directly to `openai/symphony`, so future commits should go to `tulong66/symphony`.

## Directory migration state

A full working copy was copied from:

```text
/Volumes/HY2TB/projects/symphony
```

to:

```text
/Users/deepzen/works/symphony
```

The macOS launchd service now points to the system-disk copy through a local shim:

```text
~/Library/Application Support/Symphony/shims/run-symphony-mirofish
```

The shim currently references:

```text
/Users/deepzen/works/symphony/.env
/Users/deepzen/works/symphony/elixir
/Users/deepzen/works/symphony/elixir/bin/symphony
/Users/deepzen/works/symphony/workflows/mirofish-quant-engine.WORKFLOW.md
```

The previous external-volume launchd issue was:

```text
Operation not permitted
```

Root cause: launchd could not reliably execute/read scripts and env files from `/Volumes/HY2TB/...`. User preference recorded in memory: when macOS permission/TCC/launchd/external-volume errors appear, stop and ask the user before attempting workarounds.

## Running service state

Service label:

```text
com.deepzen.symphony.mirofish
```

LaunchAgent plist:

```text
~/Library/LaunchAgents/com.deepzen.symphony.mirofish.plist
```

Logs:

```text
~/Library/Logs/symphony/mirofish/stdout.log
~/Library/Logs/symphony/mirofish/stderr.log
```

Dashboard:

```text
http://127.0.0.1:4002/
```

Last verified before handoff:

```text
launchd state = running
beam.smp listening on 127.0.0.1:4002
HTTP dashboard returned 200 text/html; charset=utf-8
```

Useful commands after restart:

```bash
~/works/symphony/bin/symphony-service status mirofish
~/works/symphony/bin/symphony-service logs mirofish
~/works/symphony/bin/symphony-service restart mirofish
~/works/symphony/bin/symphony-service stop mirofish
```

If `mise` complains about trust after path changes, run:

```bash
mise trust ~/works/symphony/elixir/mise.toml
```

## Existing uncommitted work already present

The system-disk copy currently has uncommitted work copied over from the external checkout. It includes earlier work for:

1. Multi-project launchd service management.
2. Centralized `mirofish-quant-engine` workflow.
3. Single-service multi-profile Codex routing.
4. Service docs and command wrappers.
5. Newly written difficulty-tier routing spec and plan.

Known changed/untracked areas seen before handoff:

```text
CLAUDE.md
.gitignore
bin/
docs/
workflows/
elixir/lib/symphony_elixir/agent_runner.ex
elixir/lib/symphony_elixir/codex/app_server.ex
elixir/lib/symphony_elixir/config.ex
elixir/lib/symphony_elixir/config/schema.ex
elixir/test/support/test_support.exs
elixir/test/symphony_elixir/app_server_test.exs
elixir/test/symphony_elixir/core_test.exs
elixir/docs/business-logic-flow.md
```

Important: before committing, inspect `git status --short` and `git diff --stat` from `~/works/symphony`. Stage only intended files. Do not stage `.env`, logs, or temporary files.

## Current requested feature

User wants Symphony routing labels refactored from two-level/default behavior into explicit three-level difficulty scheduling.

Desired label contract:

```text
difficulty/high
difficulty/medium
difficulty/low
```

Rules:

- Every Symphony-managed Linear issue must have exactly one difficulty label.
- Missing difficulty label is invalid.
- Multiple difficulty labels are invalid.
- Invalid labels must not spawn worker process.
- Invalid labels must not create workspace.
- Invalid labels must not run hooks.
- Invalid labels must not start Codex / future Claude Code worker.
- Invalid labels should be visible in logs/dashboard/backoff queue.
- No `codex.default_profile` fallback in multi-profile workflows.
- Legacy single-command `codex.command` workflows should continue working.

The user's accepted design direction:

- Linear labels are not mutually exclusive by default.
- Symphony should enforce mutual exclusivity.
- First version should not auto-edit Linear labels.
- Human/project manager fixes missing/conflicting labels.

## Design and plan files

Design spec written and then revised after deeper investigation:

```text
docs/superpowers/specs/2026-05-12-difficulty-tier-routing-design.md
```

Implementation plan written:

```text
docs/superpowers/plans/2026-05-12-difficulty-tier-routing-plan.md
```

Both files are in the system-disk copy at:

```text
/Users/deepzen/works/symphony
```

The plan has no known `TBD` / `TODO` placeholders.

## Important investigation finding

Initial design said AgentRunner should validate before workspace creation. Deeper investigation found that is not enough.

Current production dispatch path:

```text
Orchestrator.dispatch_issue
  -> Task.Supervisor.start_child
    -> AgentRunner.run
      -> Workspace.create_for_issue
      -> Config.codex_runtime_settings_for_issue
      -> AppServer.start_session
```

If validation only happens in AgentRunner, then a worker process has already been spawned. That violates the requirement.

Correct implementation requirement:

```text
Orchestrator must resolve difficulty routing before Task.Supervisor.start_child/2.
```

If routing fails:

- do not spawn AgentRunner;
- do not mark issue as claimed/running;
- record visible retry/backoff error, reusing `retry_attempts` for first version.

Expected error text examples:

```text
missing difficulty label: expected exactly one of difficulty/high,difficulty/medium,difficulty/low
ambiguous difficulty labels: difficulty/high,difficulty/low
```

## Relevant current code locations

Profile fallback currently lives in:

```text
elixir/lib/symphony_elixir/config.ex
```

Around the resolver:

```elixir
selected_profile = select_codex_profile(codex.routes || [], issue) || codex.default_profile
```

Schema currently requires `default_profile` for multi-profile mode in:

```text
elixir/lib/symphony_elixir/config/schema.ex
```

Around:

```elixir
if map_size(profiles) > 0 do
  validate_required(changeset, [:default_profile])
else
  validate_required(changeset, [:command])
end
```

AgentRunner currently resolves runtime settings after workspace creation in:

```text
elixir/lib/symphony_elixir/agent_runner.ex
```

Orchestrator currently spawns AgentRunner in:

```text
elixir/lib/symphony_elixir/orchestrator.ex
```

Relevant sections:

```text
maybe_dispatch / should_dispatch_issue? / dispatch_issue / do_dispatch_issue / spawn_issue_on_worker_host
schedule_issue_retry
handle_call(:snapshot)
```

Backoff display currently lives in:

```text
elixir/lib/symphony_elixir/status_dashboard.ex
```

Relevant functions:

```text
format_retry_rows
format_retry_summary
format_retry_error
```

Linear labels are defined and parsed in:

```text
elixir/lib/symphony_elixir/linear/issue.ex
elixir/lib/symphony_elixir/linear/client.ex
```

`Linear.Client.extract_labels/1` lowercases label names. `Config` also trims/downcases labels.

## Implementation plan summary

Use the plan file as source of truth, but the task sequence is:

1. Config schema accepts complete high/medium/low routes without `default_profile`.
2. Config schema requires exactly high/medium/low difficulty route coverage.
3. Runtime resolver requires exactly one difficulty label on each issue.
4. Orchestrator records routing errors before spawning AgentRunner.
5. AgentRunner direct-call fallback fails before workspace creation.
6. Update AppServer tests and workflow fixtures.
7. Update real workflow and add `bin/agent-commands/codex-low`.
8. Run focused tests, format check, specs check, full tests.
9. Sync changes to `~/works/symphony` runtime copy if implementation is done elsewhere.
10. Commit and optionally push to `origin` (`tulong66/symphony`).

Because the next Claude session should start in `~/works/symphony`, implement there directly and skip any external-volume sync step unless comparing old files.

## Open operational point

`codex-low` has no distinct cheaper model yet. Accepted temporary approach:

```text
codex-low can initially use the same command as codex-mimo.
```

Wrapper content proposed:

```bash
#!/usr/bin/env bash
set -euo pipefail

exec /opt/homebrew/bin/codex -m mimo/mimo-v2.5-pro app-server "$@"
```

## Commit / GitHub guidance

User authorized:

```text
必要时提交并同步到 GitHub 上
```

Before committing:

```bash
cd ~/works/symphony
git status --short
git diff --stat
```

Do not commit secrets or logs.

Suggested implementation commit after tests pass:

```text
feat(elixir): require difficulty-tier routing
```

Push target:

```bash
git push origin main
```

If direct push fails due branch policy, stop and report exact error; create PR only if user asks.

## Recommended first action after restart

Run:

```bash
cd ~/works/symphony
pwd -P
git status --short
git remote -v
~/works/symphony/bin/symphony-service status mirofish
```

Then continue implementing from:

```text
docs/superpowers/plans/2026-05-12-difficulty-tier-routing-plan.md
```
