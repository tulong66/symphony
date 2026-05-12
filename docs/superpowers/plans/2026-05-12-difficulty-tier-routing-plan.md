# Difficulty Tier Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require every multi-profile Symphony issue to have exactly one `difficulty/high`, `difficulty/medium`, or `difficulty/low` label before any worker is spawned.

**Architecture:** Keep the existing `codex.profiles` and `codex.routes` config shape, but remove `default_profile` as the multi-profile fallback path. Move profile resolution into the Orchestrator dispatch path so invalid labels are recorded in the Backoff queue without spawning `AgentRunner`, creating workspaces, running hooks, or starting Codex. Preserve legacy `codex.command` workflows as the single-command compatibility path.

**Tech Stack:** Elixir/OTP, Ecto embedded schemas, ExUnit, existing Symphony Orchestrator/AgentRunner/Codex AppServer modules, existing workflow YAML front matter.

---

## Current evidence

- Runtime profile fallback lives in `elixir/lib/symphony_elixir/config.ex:127-134`:

```elixir
selected_profile = select_codex_profile(codex.routes || [], issue) || codex.default_profile
```

- Multi-profile schema currently requires `default_profile` when `profiles` is non-empty in `elixir/lib/symphony_elixir/config/schema.ex:307-315`.
- Orchestrator currently spawns `AgentRunner` before profile resolution in `elixir/lib/symphony_elixir/orchestrator.ex:693-731`.
- `AgentRunner` currently resolves runtime settings after workspace creation in `elixir/lib/symphony_elixir/agent_runner.ex:29-89`.
- Backoff visibility already exists through `retry_attempts` and `StatusDashboard.format_retry_summary/1`.

## Files to modify

- `elixir/lib/symphony_elixir/config.ex`
  - Add explicit difficulty-label resolver.
  - Remove `default_profile` fallback in multi-profile mode.
  - Return typed errors for missing/ambiguous difficulty labels.

- `elixir/lib/symphony_elixir/config/schema.ex`
  - Stop requiring `codex.default_profile` for multi-profile workflows.
  - Validate that multi-profile routes cover exactly the three canonical difficulty labels.
  - Keep `codex.command` legacy mode working.

- `elixir/lib/symphony_elixir/orchestrator.ex`
  - Resolve runtime settings before `Task.Supervisor.start_child/2`.
  - On routing error, schedule a visible retry/backoff entry without spawning a worker process.
  - Pass resolved runtime settings to `AgentRunner.run/3` on success.

- `elixir/lib/symphony_elixir/agent_runner.ex`
  - Accept `:runtime_settings` from Orchestrator.
  - Keep defensive fallback for direct tests and legacy callers.
  - Ensure direct-call fallback fails before workspace creation when routing is invalid.

- `elixir/test/support/test_support.exs`
  - Adjust generated workflow YAML so tests can omit `codex_default_profile` and emit three routes.

- `elixir/test/symphony_elixir/core_test.exs`
  - Update schema/resolver tests for required high/medium/low labels and no default fallback.
  - Add AgentRunner direct-call fallback test that invalid labels do not create workspace.

- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - Add snapshot/backoff test for routing errors before worker spawn.

- `elixir/test/symphony_elixir/app_server_test.exs`
  - Update profile-selection tests to use difficulty labels and no default profile.

- `workflows/mirofish-quant-engine.WORKFLOW.md`
  - Remove `default_profile`.
  - Add three difficulty routes.
  - Add `codex-low` profile.

- `bin/agent-commands/codex-low`
  - Create low-tier wrapper. If no distinct low-tier worker exists yet, point it to the same command as `codex-mimo`.

- `docs/superpowers/specs/2026-05-12-difficulty-tier-routing-design.md`
  - Already updated with Orchestrator pre-spawn validation; do not broaden scope.

## Task 1: Config schema accepts complete difficulty routes without default profile

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`

- [ ] **Step 1: Write the failing schema acceptance test**

Replace the multi-profile acceptance half of `test "codex multi-profile config validates and preserves legacy command mode"` with this shape:

```elixir
write_workflow_file!(Workflow.workflow_file_path(),
  codex_command: nil,
  codex_default_profile: nil,
  codex_profiles: %{
    "codex-max" => %{"command" => "/tmp/codex-max app-server"},
    "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
    "codex-low" => %{"command" => "/tmp/codex-low app-server"}
  },
  codex_routes: [
    %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
    %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
    %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
  ]
)

assert :ok = Config.validate!()
assert Config.settings!().codex.default_profile == nil
assert Config.settings!().codex.profiles["codex-max"].command == "/tmp/codex-max app-server"
assert Config.settings!().codex.profiles["codex-mimo"].command == "/tmp/codex-mimo app-server"
assert Config.settings!().codex.profiles["codex-low"].command == "/tmp/codex-low app-server"
assert [
         %{profile: "codex-max", labels: %{any: ["difficulty/high"]}},
         %{profile: "codex-mimo", labels: %{any: ["difficulty/medium"]}},
         %{profile: "codex-low", labels: %{any: ["difficulty/low"]}}
       ] = Config.settings!().codex.routes
```

- [ ] **Step 2: Verify the test fails for the expected reason**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs:91
```

Expected: FAIL because `codex.default_profile` is still required when profiles exist.

- [ ] **Step 3: Update schema to not require `default_profile` in multi-profile mode**

In `Schema.Codex.validate_codex_command_or_profiles/1`, change the multi-profile branch from requiring `:default_profile` to accepting non-empty `profiles`:

```elixir
defp validate_codex_command_or_profiles(changeset) do
  profiles = get_field(changeset, :profiles, %{})

  if map_size(profiles) > 0 do
    changeset
  else
    validate_required(changeset, [:command])
  end
end
```

In `validate_profile_references/1`, remove `default_profile` validation and only validate route profile references for multi-profile mode:

```elixir
defp validate_profile_references(changeset) do
  profiles = get_field(changeset, :profiles, %{})
  routes = get_field(changeset, :routes, [])

  changeset
  |> validate_route_profiles(profiles, routes)
end
```

Delete `validate_default_profile/3` if it becomes unused.

- [ ] **Step 4: Verify the acceptance test passes**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs:91
```

Expected: PASS.

## Task 2: Config schema requires exactly high/medium/low difficulty route coverage

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`

- [ ] **Step 1: Write failing tests for missing and duplicate difficulty coverage**

Add tests near the existing profile-reference tests:

```elixir
test "codex multi-profile config requires high medium and low difficulty routes" do
  profiles = %{
    "codex-max" => %{"command" => "/tmp/codex-max app-server"},
    "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
    "codex-low" => %{"command" => "/tmp/codex-low app-server"}
  }

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: profiles,
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}}
    ]
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "codex.routes"
  assert message =~ "difficulty/low"

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: profiles,
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
      %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/high"]}}
    ]
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "codex.routes"
  assert message =~ "difficulty/high"
end
```

- [ ] **Step 2: Verify tests fail for expected reason**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"codex multi-profile config requires high medium and low difficulty routes"
```

Expected: FAIL because schema does not yet enforce complete difficulty coverage.

- [ ] **Step 3: Add difficulty route coverage validation**

In `Schema.Codex`, add module attribute and helper functions:

```elixir
@difficulty_labels MapSet.new(["difficulty/high", "difficulty/medium", "difficulty/low"])
```

Add `validate_difficulty_routes/1` after `validate_profile_references/1` in the changeset pipeline.

Implement:

```elixir
defp validate_difficulty_routes(changeset) do
  profiles = get_field(changeset, :profiles, %{})
  routes = get_field(changeset, :routes, [])

  if map_size(profiles) == 0 do
    changeset
  else
    route_labels = Enum.flat_map(routes, &difficulty_labels_for_route/1)
    present = MapSet.new(route_labels)
    missing = MapSet.difference(@difficulty_labels, present)
    duplicates = duplicate_labels(route_labels)

    cond do
      MapSet.size(missing) > 0 ->
        add_error(changeset, :routes, "must include difficulty routes for #{format_label_set(missing)}")

      duplicates != [] ->
        add_error(changeset, :routes, "must not duplicate difficulty routes for #{Enum.join(duplicates, ",")}")

      true ->
        changeset
    end
  end
end

defp difficulty_labels_for_route(%{labels: %{any: labels}}) when is_list(labels) do
  labels
  |> Enum.map(&normalize_route_label/1)
  |> Enum.filter(&MapSet.member?(@difficulty_labels, &1))
end

defp difficulty_labels_for_route(_route), do: []

defp normalize_route_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
defp normalize_route_label(_label), do: ""

defp duplicate_labels(labels) do
  labels
  |> Enum.frequencies()
  |> Enum.filter(fn {_label, count} -> count > 1 end)
  |> Enum.map(fn {label, _count} -> label end)
  |> Enum.sort()
end

defp format_label_set(labels) do
  labels
  |> MapSet.to_list()
  |> Enum.sort()
  |> Enum.join(",")
end
```

- [ ] **Step 4: Verify schema route coverage tests pass**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"codex multi-profile config requires high medium and low difficulty routes"
```

Expected: PASS.

## Task 3: Runtime resolver requires exactly one difficulty label

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/config.ex`

- [ ] **Step 1: Replace fallback resolver test with strict difficulty tests**

Replace `test "codex runtime settings select profile from issue labels"` with:

```elixir
test "codex runtime settings select profile from exactly one difficulty label" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
      "codex-low" => %{"command" => "/tmp/codex-low app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
      %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
    ],
    codex_approval_policy: "never"
  )

  assert {:ok, high_settings} = Config.codex_runtime_settings_for_issue(%Issue{id: "issue-high", labels: [" backend ", " Difficulty/High "]})
  assert high_settings.command == "/tmp/codex-max app-server"
  assert high_settings.profile == "codex-max"
  assert high_settings.approval_policy == "never"

  assert {:ok, medium_settings} = Config.codex_runtime_settings_for_issue(%Issue{id: "issue-medium", labels: ["difficulty/medium"]})
  assert medium_settings.command == "/tmp/codex-mimo app-server"
  assert medium_settings.profile == "codex-mimo"

  assert {:ok, low_settings} = Config.codex_runtime_settings_for_issue(%Issue{id: "issue-low", labels: ["difficulty/low"]})
  assert low_settings.command == "/tmp/codex-low app-server"
  assert low_settings.profile == "codex-low"
end

test "codex runtime settings reject missing and ambiguous difficulty labels" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
      "codex-low" => %{"command" => "/tmp/codex-low app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
      %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
    ]
  )

  assert {:error, {:missing_difficulty_label, "issue-empty"}} =
           Config.codex_runtime_settings_for_issue(%Issue{id: "issue-empty", labels: ["backend"]})

  assert {:error, {:ambiguous_difficulty_labels, ["difficulty/high", "difficulty/low"]}} =
           Config.codex_runtime_settings_for_issue(%Issue{id: "issue-conflict", labels: ["difficulty/low", "difficulty/high"]})
end
```

Keep `test "codex runtime settings preserve legacy command mode"` and update its label to `difficulty/high` if desired; it should still pass in legacy command mode.

- [ ] **Step 2: Verify resolver tests fail for expected reason**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"codex runtime settings select profile from exactly one difficulty label" --only test:"codex runtime settings reject missing and ambiguous difficulty labels"
```

Expected: FAIL because current resolver falls back to default profile or errors with missing profile, not explicit difficulty errors.

- [ ] **Step 3: Implement strict difficulty resolver in Config**

In `elixir/lib/symphony_elixir/config.ex`, add:

```elixir
@difficulty_labels ["difficulty/high", "difficulty/medium", "difficulty/low"]
@difficulty_label_set MapSet.new(@difficulty_labels)
```

Replace multi-profile `resolve_codex_command/2` with:

```elixir
defp resolve_codex_command(%{profiles: profiles} = codex, issue) when is_map(profiles) and map_size(profiles) > 0 do
  with {:ok, selected_profile} <- select_required_codex_profile(codex.routes || [], issue) do
    case Map.fetch(profiles, selected_profile) do
      {:ok, %{command: command}} when is_binary(command) -> {:ok, selected_profile, command}
      _ -> {:error, {:missing_codex_profile, selected_profile}}
    end
  end
end
```

Add helpers:

```elixir
defp select_required_codex_profile(routes, issue) when is_list(routes) do
  issue_labels = normalized_issue_labels(issue)

  case difficulty_labels_for_issue(issue_labels) do
    [] ->
      {:error, {:missing_difficulty_label, issue_identifier_for_error(issue)}}

    [_label] ->
      case Enum.find(routes, fn route -> route_matches?(route, issue_labels) end) do
        nil -> {:error, {:missing_difficulty_route, MapSet.to_list(issue_labels)}}
        route -> {:ok, route.profile}
      end

    labels ->
      {:error, {:ambiguous_difficulty_labels, Enum.sort(labels)}}
  end
end

defp difficulty_labels_for_issue(issue_labels) do
  issue_labels
  |> Enum.filter(&MapSet.member?(@difficulty_label_set, &1))
  |> Enum.sort()
end

defp issue_identifier_for_error(%Issue{id: id, identifier: identifier}), do: identifier || id
defp issue_identifier_for_error(%{identifier: identifier, id: id}), do: identifier || id
defp issue_identifier_for_error(%{id: id}), do: id
defp issue_identifier_for_error(_issue), do: nil
```

Keep legacy command mode unchanged:

```elixir
defp resolve_codex_command(%{command: command}, _issue) when is_binary(command) do
  {:ok, nil, command}
end
```

- [ ] **Step 4: Verify resolver tests pass**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"codex runtime settings select profile from exactly one difficulty label" --only test:"codex runtime settings reject missing and ambiguous difficulty labels"
```

Expected: PASS.

## Task 4: Orchestrator records routing errors before spawning AgentRunner

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: Write failing Orchestrator pre-spawn test**

Add a test near existing retry/backoff tests in `core_test.exs`:

```elixir
test "orchestrator records difficulty routing errors without spawning worker" do
  issue_id = "issue-missing-difficulty"
  orchestrator_name = Module.concat(__MODULE__, :DifficultyRoutingOrchestrator)

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
      "codex-low" => %{"command" => "/tmp/codex-low app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
      %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
    ]
  )

  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
  end)

  issue = %Issue{
    id: issue_id,
    identifier: "MT-ROUTE",
    title: "Missing difficulty",
    state: "Todo",
    labels: ["backend"],
    assigned_to_worker: true
  }

  initial_state = :sys.get_state(pid)

  state =
    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{})
      |> Map.put(:claimed, MapSet.new())
      |> Map.put(:retry_attempts, %{})
    end)

  refreshed = :sys.get_state(pid)
  dispatched = :erlang.apply(Orchestrator, :__test_dispatch_issue__, [refreshed, issue])

  assert dispatched.running == %{}
  refute MapSet.member?(dispatched.claimed, issue_id)
  assert %{attempt: 1, identifier: "MT-ROUTE", error: error} = dispatched.retry_attempts[issue_id]
  assert error =~ "missing difficulty label"
end
```

If direct private function access is unavailable, expose a test-only public function guarded with `@doc false`:

```elixir
@doc false
@spec __test_dispatch_issue__(State.t(), Issue.t()) :: State.t()
def __test_dispatch_issue__(state, issue), do: dispatch_issue(state, issue)
```

- [ ] **Step 2: Verify the pre-spawn test fails**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"orchestrator records difficulty routing errors without spawning worker"
```

Expected: FAIL because Orchestrator does not yet resolve routing before spawn.

- [ ] **Step 3: Pass runtime settings from Orchestrator to AgentRunner**

In `Orchestrator.do_dispatch_issue/4`, resolve runtime settings before worker selection or immediately before spawn:

```elixir
defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
  recipient = self()

  case select_worker_host(state, preferred_worker_host) do
    :no_worker_capacity ->
      Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
      state

    worker_host ->
      case Config.codex_runtime_settings_for_issue(issue, nil, remote: is_binary(worker_host)) do
        {:ok, runtime_settings} ->
          spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, runtime_settings)

        {:error, reason} ->
          record_dispatch_routing_error(state, issue, attempt, worker_host, reason)
      end
  end
end
```

Change `spawn_issue_on_worker_host/5` to `/6` and pass runtime settings:

```elixir
defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, runtime_settings) do
  case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
         AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host, runtime_settings: runtime_settings)
       end) do
```

Add routing error recorder:

```elixir
defp record_dispatch_routing_error(%State{} = state, %Issue{} = issue, attempt, worker_host, reason) do
  error = format_dispatch_routing_error(reason)
  next_attempt = if is_integer(attempt), do: attempt + 1, else: 1

  Logger.warning("Skipping dispatch for #{issue_context(issue)} error=#{error}")

  schedule_issue_retry(state, issue.id, next_attempt, %{
    identifier: issue.identifier,
    error: error,
    worker_host: worker_host
  })
end

defp format_dispatch_routing_error({:missing_difficulty_label, _issue_identifier}) do
  "missing difficulty label: expected exactly one of difficulty/high,difficulty/medium,difficulty/low"
end

defp format_dispatch_routing_error({:ambiguous_difficulty_labels, labels}) when is_list(labels) do
  "ambiguous difficulty labels: #{Enum.join(labels, ",")}"
end

defp format_dispatch_routing_error(reason), do: "routing failed: #{inspect(reason)}"
```

In `AgentRunner.run_codex_turns/5`, reuse provided settings:

```elixir
runtime_settings =
  case Keyword.get(opts, :runtime_settings) do
    nil ->
      case Config.codex_runtime_settings_for_issue(issue, workspace, remote: is_binary(worker_host)) do
        {:ok, settings} -> settings
        {:error, reason} -> throw({:codex_runtime_settings_failed, reason})
      end

    settings ->
      settings
  end
```

- [ ] **Step 4: Verify Orchestrator pre-spawn test passes**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"orchestrator records difficulty routing errors without spawning worker"
```

Expected: PASS.

- [ ] **Step 5: Add snapshot/backoff visibility test**

In `orchestrator_status_test.exs`, add:

```elixir
test "orchestrator snapshot exposes difficulty routing errors in retrying list" do
  orchestrator_name = Module.concat(__MODULE__, :DifficultyRoutingSnapshotOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
  end)

  retry_entry = %{
    attempt: 1,
    timer_ref: nil,
    due_at_ms: System.monotonic_time(:millisecond) + 10_000,
    identifier: "MT-DIFF",
    error: "missing difficulty label: expected exactly one of difficulty/high,difficulty/medium,difficulty/low"
  }

  initial_state = :sys.get_state(pid)
  new_state = %{initial_state | retry_attempts: %{"issue-diff" => retry_entry}}
  :sys.replace_state(pid, fn _ -> new_state end)

  snapshot = GenServer.call(pid, :snapshot)

  assert [entry] = snapshot.retrying
  assert entry.issue_id == "issue-diff"
  assert entry.identifier == "MT-DIFF"
  assert entry.error =~ "missing difficulty label"
end
```

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs --only test:"orchestrator snapshot exposes difficulty routing errors in retrying list"
```

Expected: PASS because snapshot already carries retry error fields.

## Task 5: AgentRunner fallback fails before workspace creation for direct callers

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: Write direct-call fallback test**

Add near AgentRunner tests:

```elixir
test "agent runner direct call rejects missing difficulty before workspace creation" do
  test_root = Path.join(System.tmp_dir!(), "symphony-routing-fallback-#{System.unique_integer([:positive])}")
  workspace_root = Path.join(test_root, "workspaces")

  write_workflow_file!(Workflow.workflow_file_path(),
    workspace_root: workspace_root,
    codex_command: nil,
    codex_default_profile: nil,
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"},
      "codex-low" => %{"command" => "/tmp/codex-low app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
      %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
      %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
    ]
  )

  issue = %Issue{
    id: "issue-direct-missing-difficulty",
    identifier: "MT-DIRECT",
    title: "Direct call missing difficulty",
    description: "No worker should start",
    state: "Todo",
    labels: ["backend"]
  }

  try do
    assert_raise RuntimeError, ~r/missing_difficulty_label/, fn ->
      AgentRunner.run(issue)
    end

    refute File.exists?(workspace_root)
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: Verify fallback test fails**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"agent runner direct call rejects missing difficulty before workspace creation"
```

Expected: FAIL because current AgentRunner creates workspace before runtime settings resolution.

- [ ] **Step 3: Move AgentRunner runtime settings resolution before workspace creation**

In `AgentRunner.run/3`, compute runtime settings before `run_on_worker_host/5`:

```elixir
runtime_settings =
  case Keyword.get(opts, :runtime_settings) do
    nil ->
      case Config.codex_runtime_settings_for_issue(issue, nil, remote: is_binary(worker_host)) do
        {:ok, settings} -> settings
        {:error, reason} -> raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end

    settings ->
      settings
  end

opts = Keyword.put(opts, :runtime_settings, runtime_settings)
```

Then call `run_on_worker_host(issue, codex_update_recipient, opts, worker_host)` as today.

Keep the `run_codex_turns/5` fallback from Task 4 so tests that call lower layers still behave.

- [ ] **Step 4: Verify fallback test passes**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"agent runner direct call rejects missing difficulty before workspace creation"
```

Expected: PASS.

## Task 6: Update AppServer profile tests and workflow fixtures

**Files:**
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`
- Modify: `elixir/test/support/test_support.exs`

- [ ] **Step 1: Update app server selected-command test fixture**

In `app_server_test.exs`, update the profile-selection fixture around the current `codex_default_profile: "codex-mimo"` test:

```elixir
codex_default_profile: nil,
codex_profiles: %{
  "codex-max" => %{"command" => "#{fake_codex_path} --config model=\"gpt-5.5\" app-server"},
  "codex-mimo" => %{"command" => "#{fake_codex_path} --config model=\"mimo-v2.5-pro\" app-server"},
  "codex-low" => %{"command" => "#{fake_codex_path} --config model=\"low\" app-server"}
},
codex_routes: [
  %{"profile" => "codex-max", "labels" => %{"any" => ["difficulty/high"]}},
  %{"profile" => "codex-mimo", "labels" => %{"any" => ["difficulty/medium"]}},
  %{"profile" => "codex-low", "labels" => %{"any" => ["difficulty/low"]}}
]
```

Update the issue labels in that test to:

```elixir
labels: ["difficulty/high"]
```

- [ ] **Step 2: Verify app server focused tests fail or pass according to resolver state**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/app_server_test.exs --only test:"app server launches the command selected for the issue profile"
```

Expected: PASS after Tasks 1-5 are complete.

- [ ] **Step 3: Ensure test support emits nil default profile as absent or null consistently**

Inspect `write_workflow_file!/2` output behavior in `test/support/test_support.exs`. Keep current `yaml_value(nil)` behavior if existing tests expect `default_profile: null`; otherwise omit `default_profile` when nil. The implementation must allow tests to represent no default profile.

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/app_server_test.exs
```

Expected: PASS.

## Task 7: Update real workflow and add codex-low wrapper

**Files:**
- Modify: `workflows/mirofish-quant-engine.WORKFLOW.md`
- Create: `bin/agent-commands/codex-low`
- Modify if needed: `docs/symphony-service-guide.md`

- [ ] **Step 1: Create `codex-low` wrapper**

Create `bin/agent-commands/codex-low`:

```bash
#!/usr/bin/env bash
set -euo pipefail

exec /opt/homebrew/bin/codex -m mimo/mimo-v2.5-pro app-server "$@"
```

Set executable:

```bash
chmod +x /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-low
```

- [ ] **Step 2: Update workflow profile routes**

Change `workflows/mirofish-quant-engine.WORKFLOW.md` from:

```yaml
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
```

to:

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

- [ ] **Step 3: Update service guide profile section**

Update `docs/symphony-service-guide.md` to describe:

- `codex-max` handles `difficulty/high`.
- `codex-mimo` handles `difficulty/medium`.
- `codex-low` handles `difficulty/low`, initially using the same command as `codex-mimo` until a cheaper low-tier worker is configured.
- Every managed Linear issue must have exactly one difficulty label.

- [ ] **Step 4: Validate workflow parsing**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs --only test:"current WORKFLOW.md file is valid and complete"
```

Expected: PASS.

## Task 8: Run focused and full validation

**Files:**
- No edits unless tests reveal a defect.

- [ ] **Step 1: Run focused routing tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/app_server_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run formatting check**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix format --check-formatted
```

Expected: PASS.

- [ ] **Step 3: Run specs check**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix specs.check
```

Expected: PASS.

- [ ] **Step 4: Run full test suite**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
mise exec -- mix test
```

Expected: PASS.

## Task 9: Sync system-disk service copy and restart service

**Files:**
- Runtime copy: `/Users/deepzen/works/symphony`

- [ ] **Step 1: Stop running service before syncing**

Run:

```bash
/Users/deepzen/works/symphony/bin/symphony-service stop mirofish
```

Expected: service stops or reports already stopped.

- [ ] **Step 2: Sync repository changes to system disk copy**

Run from repository root:

```bash
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'log/services/*' \
  /Volumes/HY2TB/projects/symphony/ \
  /Users/deepzen/works/symphony/
```

Expected: system-disk copy receives updated workflow, wrappers, and Elixir source.

- [ ] **Step 3: Build system-disk escript**

Run:

```bash
cd /Users/deepzen/works/symphony/elixir
mise exec -- mix build
```

Expected: `bin/symphony` exists and build exits 0.

- [ ] **Step 4: Reinstall and restart service from system-disk copy**

Run:

```bash
/Users/deepzen/works/symphony/bin/symphony-service install mirofish \
  --workflow /Users/deepzen/works/symphony/workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4002 \
  --logs-root /Users/deepzen/Library/Logs/symphony/mirofish
/Users/deepzen/works/symphony/bin/symphony-service start mirofish
```

Expected: service starts.

- [ ] **Step 5: Verify service health**

Run:

```bash
/Users/deepzen/works/symphony/bin/symphony-service status mirofish
lsof -nP -iTCP:4002 -sTCP:LISTEN
python3 - <<'PY'
from urllib.request import urlopen
with urlopen('http://127.0.0.1:4002/', timeout=5) as response:
    print(response.status)
    print(response.headers.get('content-type'))
PY
```

Expected:

- `launchctl` state is `running`.
- `beam.smp` listens on `127.0.0.1:4002`.
- HTTP response is `200` and `text/html; charset=utf-8`.

## Task 10: Git commit and optional GitHub sync

**Files:**
- All changed source, tests, workflow, wrappers, docs.

- [ ] **Step 1: Inspect git status and diff**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony
git status --short
git diff --stat
```

Expected: only intended source/test/workflow/docs/wrapper changes are present. Do not include logs, `.env`, or temporary files.

- [ ] **Step 2: Stage only intended files**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony
git add \
  elixir/lib/symphony_elixir/config.ex \
  elixir/lib/symphony_elixir/config/schema.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/test/support/test_support.exs \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/app_server_test.exs \
  workflows/mirofish-quant-engine.WORKFLOW.md \
  bin/agent-commands/codex-low \
  docs/symphony-service-guide.md \
  docs/superpowers/specs/2026-05-12-difficulty-tier-routing-design.md \
  docs/superpowers/plans/2026-05-12-difficulty-tier-routing-plan.md
```

Expected: staged diff excludes secrets and runtime logs.

- [ ] **Step 3: Commit**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony
git commit -m "feat(elixir): require difficulty-tier routing"
```

Expected: commit succeeds without bypassing hooks.

- [ ] **Step 4: Push if user still wants GitHub sync**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony
git push
```

Expected: push succeeds. If remote rejects or branch policy blocks direct push, stop and report the exact message.

## Self-review notes

- Spec coverage: covers strict three-label contract, no default fallback, Orchestrator pre-spawn validation, visible Backoff queue errors, legacy command compatibility, workflow rollout, service restart.
- Placeholder scan: no placeholder instructions remain; the only open operational point is resolved by creating `codex-low` as a wrapper that initially reuses `codex-mimo`.
- Type consistency: uses existing names `codex.profiles`, `codex.routes`, `labels.any`, `runtime_settings`, `retry_attempts`, and `Config.codex_runtime_settings_for_issue/3` consistently.
