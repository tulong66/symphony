# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

Symphony is an engineering preview for orchestrating coding agents from issue-tracker work. The language-agnostic contract lives in `SPEC.md`; the reference implementation is the Elixir/OTP service under `elixir/`.

The Elixir implementation polls Linear, creates one workspace per issue, launches Codex in app-server mode inside that workspace, streams Codex events into orchestrator state, and exposes terminal/Phoenix observability surfaces.

## Common commands

Run commands from `elixir/` unless noted otherwise.

```bash
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

Quality and tests:

```bash
make all                    # CI gate: setup, build, format check, lint, coverage, dialyzer
make test                   # mix test
mix test                    # full ExUnit suite
mix test path/to/test.exs   # single test file
mix test path/to/test.exs:LINE
make fmt                    # mix format
make fmt-check              # mix format --check-formatted
make lint                   # mix specs.check + credo --strict
mix specs.check             # enforce @spec on public lib/ functions
make coverage               # mix test --cover; coverage threshold is 100%
make dialyzer               # mix dialyzer --format short
```

Live external E2E creates disposable Linear resources and launches a real Codex app-server session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional E2E env vars: `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`; `SYMPHONY_LIVE_SSH_WORKER_HOSTS` can point SSH scenarios at real worker hosts, otherwise Docker Compose starts disposable localhost SSH workers.

PR body validation:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Architecture map

- `elixir/lib/symphony_elixir.ex` defines the public entrypoint and OTP application. The supervision tree starts PubSub, `Task.Supervisor`, `WorkflowStore`, `Orchestrator`, `HttpServer`, and `StatusDashboard`.
- `elixir/lib/symphony_elixir/cli.ex` is the escript entrypoint. It requires the long guardrails acknowledgement flag, accepts an optional workflow path, `--logs-root`, and `--port`, then starts the OTP app.
- `elixir/lib/symphony_elixir/workflow.ex` parses `WORKFLOW.md` YAML front matter plus Markdown prompt body. `WorkflowStore` caches the last known good workflow and polls for changes, keeping the previous good config if reload fails.
- `elixir/lib/symphony_elixir/config.ex` and `config/schema.ex` provide the typed runtime config. Add new config access here instead of reading environment variables ad hoc. `tracker.api_key` and `tracker.assignee` resolve from `LINEAR_API_KEY` / `LINEAR_ASSIGNEE`; path values such as `workspace.root` support `~` and `$VAR` expansion.
- `elixir/lib/symphony_elixir/orchestrator.ex` owns polling, runtime state, dispatch limits, reconciliation, terminal-state cleanup, retry/backoff, worker-host selection, and token/rate-limit accounting.
- `elixir/lib/symphony_elixir/tracker.ex` is the tracker boundary. It selects `Tracker.Memory` for `tracker.kind: memory`; otherwise it uses `Linear.Adapter` and `Linear.Client` for Linear GraphQL reads/writes.
- `elixir/lib/symphony_elixir/workspace.ex` creates/removes local or SSH workspaces under the configured workspace root, validates path safety, and runs `after_create`, `before_run`, `after_run`, and `before_remove` hooks.
- `elixir/lib/symphony_elixir/agent_runner.ex` executes one issue: select worker, create workspace, run workspace hooks, build the prompt, start a Codex app-server session, and continue turns while the issue remains active up to `agent.max_turns`.
- `elixir/lib/symphony_elixir/codex/app_server.ex` is the JSON-RPC stdio client for `codex app-server`. It starts threads/turns with configured approval and sandbox policy, injects dynamic tools, handles non-interactive approval/tool input, and streams events back to the orchestrator.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` exposes the client-side `linear_graphql` tool used by workflow skills.
- `elixir/lib/symphony_elixir/http_server.ex` conditionally starts the Phoenix endpoint when `server.port` or CLI `--port` is set. Routes are in `elixir/lib/symphony_elixir_web/router.ex`: LiveView dashboard at `/`, JSON API at `/api/v1/state`, `/api/v1/:issue_identifier`, and refresh at `/api/v1/refresh`.
- `elixir/lib/symphony_elixir/status_dashboard.ex` renders the terminal dashboard and broadcasts observability updates through PubSub.

## Workflow/config contract

`elixir/WORKFLOW.md` is both sample runtime config and the Codex prompt template. Its front matter covers:

- `tracker`: kind, Linear project slug, active/terminal states, token indirection.
- `polling.interval_ms`.
- `workspace.root`.
- `hooks`: workspace lifecycle shell snippets and `timeout_ms`.
- `agent`: concurrency, state-specific concurrency, retry backoff, max continuation turns.
- `worker`: optional SSH hosts and per-host concurrency.
- `codex`: command, approval policy, thread sandbox, turn sandbox policy, timeouts.
- `observability` and `server` settings for terminal/Phoenix surfaces.

Keep behavior aligned with `SPEC.md`. If implementation behavior or config meaning changes materially, update `SPEC.md`, `elixir/README.md`, and/or `elixir/WORKFLOW.md` in the same change where practical.

## Codebase-specific rules

- Public `def` functions in `elixir/lib/` must have adjacent `@spec`; `defp` specs are optional, and `@impl` callback implementations are exempt. Validate with `mix specs.check`.
- Workspace safety is critical: Codex turn `cwd` must not be the source repo, and workspaces must remain under the configured workspace root. Preserve `PathSafety` checks when changing workspace or app-server code.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve dispatch, retry, reconciliation, cleanup, and continuation semantics when editing `Orchestrator` or `AgentRunner`.
- Follow `elixir/docs/logging.md`: issue-related logs include `issue_id` and `issue_identifier`; Codex lifecycle logs include `session_id`; prefer stable `key=value` fields.
- Token accounting semantics are documented in `elixir/docs/token_accounting.md`; classify usage by event type and payload path, not by field name alone.
- Elixir formatting uses `.formatter.exs` with `line_length: 200`.

## Tests and fixtures

- Unit/integration tests are under `elixir/test/`; support helpers are under `elixir/test/support/`.
- Snapshot tests for the terminal dashboard live in `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs` with fixtures under `elixir/test/fixtures/status_dashboard_snapshots/`.
- To update dashboard snapshots, use:

```bash
cd elixir
UPDATE_SNAPSHOTS=1 mix test test/symphony_elixir/status_dashboard_snapshot_test.exs
```

## CI and PR expectations

GitHub Actions run `make all` from `elixir/` and validate PR descriptions against `.github/pull_request_template.md`. The template expects `Context`, `TL;DR`, `Summary`, `Alternatives`, and `Test Plan`; include `make -C elixir all` or equivalent `make all` evidence for Elixir changes.
