---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "mirofish-quant-engine-d86dd76535ce"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces/mirofish-quant-engine
hooks:
  after_create: |
    git clone --depth 1 https://github.com/tulong66/mirofish-quant-engine.git .
  before_remove: |
    true
agent:
  max_concurrent_agents: 2
  max_turns: 20
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
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Linear ticket for the `mirofish-quant-engine` project: `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Work only in the provided workspace copy of `mirofish-quant-engine`.
3. Treat ticket-provided `Acceptance Criteria`, `Validation`, `Test Plan`, or `Testing` sections as required.
4. Start by inspecting the current repository state and writing a concise execution checklist in the persistent Linear workpad if Linear tools are available.
5. Keep implementation narrowly scoped to the ticket.
6. Prefer targeted validation first, then broader checks when the change warrants it.
7. Final message must report completed actions and blockers only. Do not include generic next steps for the user.

Status map:

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> transition to `In Progress` before active work when Linear tools permit.
- `In Progress` -> implementation actively underway.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; complete the merge workflow if tooling and permissions allow.
- `Rework` -> reviewer requested changes; re-read feedback, plan, implement, and revalidate.
- `Done` -> terminal state; no further action required.

Validation guidance for `mirofish-quant-engine`:

- If the ticket touches documentation or research notes, verify links and referenced files exist.
- If the ticket adds executable code later, run the project-specific test/build command documented in that repository's `CLAUDE.md` or README.
- If no project-specific validation exists yet, record that clearly in the workpad and perform the narrowest deterministic check available.
