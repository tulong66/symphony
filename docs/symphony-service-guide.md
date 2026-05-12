# Symphony Service Guide

This repository can act as a local command center for project orchestration. Symphony itself remains a CLI-started long-running service: one running service instance reads one `WORKFLOW.md`, polls one Linear project, and creates per-issue workspaces for one target project workflow.

Multiple projects are supported by running multiple local service instances from the same Symphony checkout.

## Model

```text
symphony/
  .env
  workflows/
    mirofish-quant-engine.WORKFLOW.md
    another-project.WORKFLOW.md
  bin/
    run-symphony
    symphony-service
```

Each service instance has its own:

- service name, such as `mirofish`
- workflow file
- dashboard port
- logs root
- workspace root, configured inside the workflow
- launchd label, such as `com.deepzen.symphony.mirofish`

## Prerequisites

From the repository root:

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

The build creates:

```text
elixir/bin/symphony
```

The root `.env` file must contain:

```bash
LINEAR_API_KEY=...
```

Do not commit `.env`. To use a different env file, pass `--env /path/to/file` to `bin/run-symphony` or `bin/symphony-service install`.

## Foreground debug run

Use foreground mode before installing a daemon. It keeps logs visible in the terminal and exits when you press `Ctrl+C`.

```bash
./bin/run-symphony \
  --name mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001

# Optional custom env file:
./bin/run-symphony \
  --name mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001 \
  --env /path/to/.env
```

Open the dashboard:

```text
http://127.0.0.1:4001/
```

If `elixir/bin/symphony` is missing, rebuild with:

```bash
cd elixir
mise exec -- mix build
```

## Install a launchd service

Use `--dry-run` first to inspect the generated plist without installing it:

```bash
./bin/symphony-service install mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001 \
  --dry-run > /tmp/mirofish-symphony.plist

plutil -lint /tmp/mirofish-symphony.plist
```

Install the service:

```bash
./bin/symphony-service install mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001

# Optional custom env file:
./bin/symphony-service install mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001 \
  --env /path/to/.env
```

This writes:

```text
~/Library/LaunchAgents/com.deepzen.symphony.mirofish.plist
```

## Manage services

```bash
./bin/symphony-service start mirofish
./bin/symphony-service status mirofish
./bin/symphony-service logs mirofish
./bin/symphony-service logs mirofish --follow
./bin/symphony-service restart mirofish
./bin/symphony-service stop mirofish
./bin/symphony-service uninstall mirofish
```

List installed Symphony services:

```bash
./bin/symphony-service list
```

## Multiple projects

Install each project with a unique name and port:

```bash
./bin/symphony-service install mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001

./bin/symphony-service install research \
  --workflow workflows/research.WORKFLOW.md \
  --port 4002
```

Then run both:

```bash
./bin/symphony-service start mirofish
./bin/symphony-service start research
```

Each service runs the same `elixir/bin/symphony` executable, but with a different workflow, logs root, and dashboard port.

## Workflow requirements

A workflow needs a real Linear project slug:

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "your-linear-project-slug"
```

The slug comes from the Linear project URL. Do not use an arbitrary placeholder for a real service run; Symphony filters Linear issues by this slug.

The workflow should also set a dedicated workspace root:

```yaml
workspace:
  root: ~/code/symphony-workspaces/mirofish-quant-engine
```

The `hooks.after_create` command bootstraps each issue workspace. For `mirofish-quant-engine`:

```yaml
hooks:
  after_create: |
    git clone --depth 1 https://github.com/tulong66/mirofish-quant-engine.git .
```

## Agent command profiles

`symphony/bin/agent-commands/` hosts per-provider/model wrapper scripts used by workflow profile routing. The current `mirofish-quant-engine` workflow uses explicit difficulty-tier routing:

- `codex-max` — high-capability `heihei/gpt-5.5` profile for `difficulty/high` issues.
- `codex-mimo` — `opgo/mimo-v2.5-pro` profile for `difficulty/medium` issues.
- `codex-low` — `opgo/minimax-m2.7` profile for `difficulty/low` issues.

Every Symphony-managed Linear issue in a multi-profile workflow must have exactly one of `difficulty/high`, `difficulty/medium`, or `difficulty/low`. Missing or conflicting difficulty labels are rejected before a worker is spawned.

These wrappers are distinct from Claude Code aliases; each script must launch a Codex-compatible app-server command. Keep wrapper commands executable and use absolute paths for daemon reliability when a command is not guaranteed to be on launchd's `PATH`.

A workflow references profiles by repo-local absolute path:

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

When adding support for a new provider, model, or channel, add a new script under `bin/agent-commands/` following the same naming convention and add it to the workflow's `codex.profiles`.

## Troubleshooting

### Missing Linear token

Symptom:

```text
LINEAR_API_KEY is not set
```

Fix: add `LINEAR_API_KEY` to the root `.env` or export it before running.

### Missing Symphony executable

Symptom:

```text
Symphony executable not found: .../elixir/bin/symphony
```

Fix:

```bash
cd elixir
mise exec -- mix build
```

### Invalid workflow or placeholder Linear slug

If the workflow has invalid YAML, Symphony will not boot. If `project_slug` is still `REPLACE_WITH_LINEAR_PROJECT_SLUG`, the service may start but cannot poll the intended Linear project.

### Port conflict

Use a different port per service instance:

```bash
./bin/symphony-service install mirofish --workflow workflows/mirofish-quant-engine.WORKFLOW.md --port 4001
./bin/symphony-service install another --workflow workflows/another.WORKFLOW.md --port 4002
```

### launchd service exits quickly

Check logs:

```bash
./bin/symphony-service logs mirofish
```

The stderr log usually shows missing env, missing build artifact, workflow parse errors, or port binding errors.
