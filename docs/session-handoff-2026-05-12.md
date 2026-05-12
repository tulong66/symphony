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

## Channel smoke validation update

After difficulty-tier routing was implemented and pushed, the next operational validation step changed from Linear issue creation to local channel smoke tests.

Current task status:

- Symphony mirofish service is running on `127.0.0.1:4002`.
- Linear active candidate query for `mirofish-quant-engine-d86dd76535ce` returned `candidate_count=0`, so there are no current active issues to validate against.
- Wrapper/channel inventory:
  - `bin/agent-commands/codex-max` -> `/Users/deepzen/bin/codex-max app-server`
  - `bin/agent-commands/codex-mimo` -> `/opt/homebrew/bin/codex -m mimo/mimo-v2.5-pro app-server`
  - `bin/agent-commands/codex-low` -> `/opt/homebrew/bin/codex -m mimo/mimo-v2.5-pro app-server`
- Local command availability:
  - `/opt/homebrew/bin/codex --version` -> `codex-cli 0.130.0`
  - `/Users/deepzen/bin/codex-max --version` -> `codex-cli 0.130.0`
  - `claude --version` -> `2.1.139 (Claude Code)`

Smoke test results:

- `difficulty/medium` resolved to `codex-mimo` and completed a simple Chinese greeting turn via Codex app-server.
- `difficulty/low` resolved to `codex-low` and completed a simple Chinese greeting turn via Codex app-server.
- `difficulty/high` resolved to `codex-max` and completed a simple Chinese greeting turn via Codex app-server.
- Claude Code CLI non-interactive prompt completed successfully with `你好，Claude Code smoke test。`

Observation:

- Each Codex app-server smoke run emitted a `Codex notification: "error"` debug line near the end, but `AppServer.run/4` returned `{:ok, %{result: :turn_completed, session_id: ..., thread_id: ..., turn_id: ...}}`. Treat this as a non-blocking observation to inspect later if it appears in real worker runs.

Recommended next actions:

1. Commit this smoke validation record if desired.
2. Create or select low-risk Linear validation issues only after channel smoke tests are considered sufficient.
3. Resume true end-to-end validation by creating/labeling high, medium, low, missing difficulty, and conflicting difficulty issues.

## Linear operational validation update

Validation issues created in project `mirofish-quant-engine-d86dd76535ce`:

- `DEE-19` `difficulty/high` + `symphony/validation`
- `DEE-20` `difficulty/medium` + `symphony/validation`
- `DEE-21` `difficulty/low` + `symphony/validation`
- `DEE-22` `symphony/validation` only
- `DEE-23` `difficulty/high` + `difficulty/low` + `symphony/validation`

All five validation issues were restored to `Backlog` after testing. Final dashboard state after restoration: `running=[]`, `retrying=[]`.

Results:

- `DEE-19` high route started worker/workspace/hook/Codex through `codex-max`; workspace exists at `~/code/symphony-workspaces/mirofish-quant-engine/DEE-19`.
- `DEE-20` medium route started worker/workspace/hook/Codex through `codex-mimo`; workspace exists at `~/code/symphony-workspaces/mirofish-quant-engine/DEE-20`.
- `DEE-21` low route started worker/workspace/hook/Codex through `codex-low`; workspace exists at `~/code/symphony-workspaces/mirofish-quant-engine/DEE-21`.
- `DEE-22` missing difficulty label was blocked before worker/workspace creation with `missing difficulty label: expected exactly one of difficulty/high,difficulty/medium,difficulty/low`; no `DEE-22` workspace exists.
- `DEE-23` conflicting difficulty labels were blocked before worker/workspace creation with `ambiguous difficulty labels: difficulty/high,difficulty/low`; no `DEE-23` workspace exists.

Operational fixes/findings during validation:

- The launchd service initially failed high-route Codex with `Missing environment variable: CLIPROXY_API_KEY`; with user approval, the current shell `CLIPROXY_API_KEY` was added to the local ignored `.env` and the `mirofish` service was restarted.
- `AppServer` was fixed so `turn/completed` payloads with `turn.status == "failed"` return `{:error, {:turn_failed, params}}` instead of false success. Regression test added in `elixir/test/symphony_elixir/app_server_test.exs`.
- After the env and AppServer fix, high/medium/low routes all reached Codex and failed with upstream `429 Too Many Requests`, not routing/config/workspace errors.

Verification run after the AppServer fix:

```text
mise exec -- mix test test/symphony_elixir/app_server_test.exs:1133
mise exec -- mix format --check-formatted lib/symphony_elixir/codex/app_server.ex test/symphony_elixir/app_server_test.exs
mise exec -- mix test test/symphony_elixir/app_server_test.exs
mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs
mise exec -- mix specs.check
mise exec -- mix build
git diff --check
```

All listed checks passed.

Next operational task:

- Investigate Codex upstream `429 Too Many Requests` / CLIPROXY quota or rate-limit behavior, then rerun one real high/medium/low issue to full turn success.

## Codex quota/rate-limit investigation update

Follow-up probing showed the current Codex blockage is upstream quota/rate-limit, not Symphony routing:

- `/Users/deepzen/bin/codex-max exec --skip-git-repo-check "请只回复：codex-max quota probe"` uses provider `cliproxyapi`, model `gpt-5.5`, and returns `429 Too Many Requests`.
- `/opt/homebrew/bin/codex -m mimo/mimo-v2.5-pro exec --skip-git-repo-check "请只回复：codex-mimo quota probe"` also uses provider `cliproxyapi` and returns `429 Too Many Requests`.
- `~/.codex/config.toml` currently has one configured provider, `cliproxyapi`, with base URL `http://127.0.0.1:8317/v1` and env key `CLIPROXY_API_KEY`.
- `/opt/homebrew/bin/codex exec --ignore-user-config --skip-git-repo-check "请只回复：codex default provider probe"` switches to provider `openai`, but returns the ChatGPT/Codex usage-limit message: `You've hit your usage limit... try again at May 18th, 2026 8:14 AM.`

Conclusion: all currently available Codex paths are quota/rate-limit blocked. Do not keep triggering Linear validation issues until quota/provider capacity is restored or an alternate provider is configured.

## Codex quota/rate-limit resolution update

Later probing showed the earlier conclusion was too broad:

- Direct CLIPROXY `/v1/responses` calls with model `heihei/gpt-5.5` succeeded.
- Direct CLIPROXY calls with model `gpt-5.5` returned `model_cooldown` for provider `codex`.
- Direct CLIPROXY calls with model `mimo/mimo-v2.5-pro` returned `quota exhausted`.
- `codex exec -m heihei/gpt-5.5 ...` succeeded.
- `codex exec -m opgo/mimo-v2.5-pro ...` succeeded.
- `codex app-server` did not honor the wrapper's top-level `-m ...` as expected for these app-server runs; `codex app-server -c 'model="..."'` did work.

Wrapper changes made:

- `bin/agent-commands/codex-max` now runs `/opt/homebrew/bin/codex --dangerously-bypass-approvals-and-sandbox app-server -c 'model="heihei/gpt-5.5"' "$@"`.
- `bin/agent-commands/codex-mimo` now runs `/opt/homebrew/bin/codex app-server -c 'model="opgo/mimo-v2.5-pro"' "$@"`.
- `bin/agent-commands/codex-low` now runs `/opt/homebrew/bin/codex app-server -c 'model="opgo/mimo-v2.5-pro"' "$@"`.

Local AppServer smoke after the wrapper change showed all three routes completed successfully:

```text
difficulty/high   -> {:ok, %{result: :turn_completed, ...}}
difficulty/medium -> {:ok, %{result: :turn_completed, ...}}
difficulty/low    -> {:ok, %{result: :turn_completed, ...}}
```

Remaining validation: restart the `mirofish` launchd service so it picks up the wrapper changes, then rerun one real Linear validation issue to confirm service-run success.

Service validation after restart:

- `mirofish` launchd service was restarted and dashboard returned HTTP 200.
- Triggered real `DEE-19` high route after wrapper changes.
- The service-run worker no longer failed with 429; it started a Codex session and continued reasoning with token usage visible in the dashboard (`input_tokens` and `output_tokens` increasing).
- `DEE-19` was restored to `Backlog`; final dashboard state after restoration was `running=[]`, `retrying=[]`.
- The real `DEE-19` validation did not complete within the 120-second observation window because the full workflow prompt made Codex continue real ticket-style reasoning. For future quick service smoke, use a smaller dedicated validation issue/prompt that forces immediate completion.

## Low-tier DeepSeek validation update

`codex-low` was first switched to `opgo/deepseek-v4-pro`, but real `DEE-21` service validation failed during tool-call continuation with DeepSeek's `reasoning_content` requirement. Adding `model_reasoning_effort="none"` did not resolve that real worker failure.

Follow-up CLIPROXY model probing showed `opgo/deepseek-v4-pro` and `ccr/opgo-deepseek-v4-pro` responses include reasoning output, while `nv/deepseek-v4-pro` returned message-only output for the probe. `codex-low` was therefore switched to `nv/deepseek-v4-pro`.

Real `DEE-21` validation after restarting the `mirofish` service:

- `DEE-21` started through the `difficulty/low` route and used the `codex-low` wrapper.
- The worker created/reused the expected workspace at `~/code/symphony-workspaces/mirofish-quant-engine/DEE-21`.
- The service started a Codex session, streamed agent messages, executed commands, called dynamic tools, and accumulated token usage.
- No 429, no retry entry, and no DeepSeek `reasoning_content` failure appeared during the observation window.
- `DEE-21` was restored to `Backlog`; final dashboard state was `running=[]`, `retrying=[]`.

## Short-link Linear E2E smoke update

Created dedicated short smoke issues in Linear project `mirofish-quant-engine-d86dd76535ce`:

- `DEE-24` `difficulty/high` + `symphony/validation`
- `DEE-25` `difficulty/medium` + `symphony/validation`
- `DEE-26` `difficulty/low` + `symphony/validation`

Results:

- `DEE-24` high route completed end-to-end and moved itself to `Done`.
- `DEE-25` medium route completed end-to-end and moved itself to `Done`.
- `DEE-26` low route started correctly through `codex-low`, executed commands/dynamic tools, moved to `In Progress`, then failed the Codex turn with upstream `429 Too Many Requests`. It was restored to `Backlog` after observation.
- Final dashboard state after cleanup was `running=[]`, `retrying=[]`.

Low-tier root-cause check:

- Direct CLIPROXY `/v1/responses` call with model `nv/deepseek-v4-pro` also returned HTTP 429.
- Alternate DeepSeek/Mimo route probes (`opgo/deepseek-v4-pro`, `ccr/opgo-deepseek-v4-pro`, `ds/v4-pro`, `opgo/mimo-v2.5-pro`) did not 429 in a minimal direct probe, but returned reasoning-only output for that probe.
- `opgo/deepseek-v4-pro` remains unsuitable for real Codex app-server tool continuation because it previously failed with DeepSeek's `reasoning_content` requirement.

Conclusion: high and medium short-link E2E smoke are clear; low routing reached the configured worker path, but `nv/deepseek-v4-pro` was later identified as an invalid/fake low-tier choice and returned upstream 429 during smoke. `codex-low` was moved to the ModelScope route `ms/DeepSeek-V4-Pro[1m]`. Local verification after the switch: `codex exec -m 'ms/DeepSeek-V4-Pro[1m]'` returned `MS_DEEPSEEK_PROBE_OK`, and a direct `AppServer.run/4` smoke through `bin/agent-commands/codex-low` returned `{:ok, %{result: :turn_completed, ...}}`.
