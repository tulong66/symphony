# Single-Service Model Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add single-service, multi-profile Codex routing so one Symphony workflow can route Linear issues to `codex-max` or `codex-mimo` based on `complexity/high` labels.

**Architecture:** Keep one launchd service and one workflow. Extend `codex` config with backward-compatible `default_profile`, `profiles`, and `routes`; resolve the selected command per issue before launching the app-server child process. Existing single-command workflows using `codex.command` must keep working unchanged.

**Tech Stack:** Elixir/OTP, Ecto embedded schemas, ExUnit, existing Codex app-server stdio client, Bash command wrappers.

---

## File structure

- Modify `elixir/lib/symphony_elixir/config/schema.ex`
  - Add embedded schemas for Codex profiles and routes.
  - Validate multi-profile configuration without breaking legacy `codex.command`.
- Modify `elixir/lib/symphony_elixir/config.ex`
  - Add route resolution based on `Issue.label_names/1`.
  - Return selected `command` together with existing runtime settings.
- Modify `elixir/lib/symphony_elixir/codex/app_server.ex`
  - Store selected command in session state.
  - Launch the selected command instead of always reading global `Config.settings!().codex.command`.
- Modify `elixir/lib/symphony_elixir/agent_runner.ex`
  - Resolve per-issue Codex runtime settings before `AppServer.start_session/2`.
- Modify `elixir/test/support/test_support.exs`
  - Allow tests to emit `codex.default_profile`, `codex.profiles`, and `codex.routes`.
- Modify `elixir/test/symphony_elixir/core_test.exs`
  - Add config validation and route resolver tests.
- Modify `elixir/test/symphony_elixir/app_server_test.exs`
  - Add selected-command launch test using fake Codex binaries.
- Modify `workflows/mirofish-quant-engine.WORKFLOW.md`
  - Switch to `codex-max`/`codex-mimo` profile routing.
- Create `bin/agent-commands/codex-max`
  - Repo-local wrapper for `/Users/deepzen/bin/codex-max app-server`.
- Create `bin/agent-commands/codex-mimo`
  - Repo-local wrapper for `codex -m mimo/mimo-v2.5-pro app-server`.
- Modify `docs/symphony-service-guide.md`
  - Update agent command profile examples from old `codex-hh` wording to `codex-max`/`codex-mimo` routing.

## Task 1: Extend Codex config schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Add failing tests for legacy and multi-profile config validation**

Add tests to `elixir/test/symphony_elixir/core_test.exs` after the existing `config defaults and validation checks` test:

```elixir
test "codex multi-profile config validates and preserves legacy command mode" do
  write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/legacy app-server")

  assert :ok = Config.validate!()
  assert Config.settings!().codex.command == "/bin/legacy app-server"
  assert Config.settings!().codex.default_profile == nil
  assert Config.settings!().codex.profiles == %{}
  assert Config.settings!().codex.routes == []

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: "codex-mimo",
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["complexity/high"]}}
    ]
  )

  assert :ok = Config.validate!()
  assert Config.settings!().codex.default_profile == "codex-mimo"
  assert Config.settings!().codex.profiles["codex-max"].command == "/tmp/codex-max app-server"
  assert Config.settings!().codex.profiles["codex-mimo"].command == "/tmp/codex-mimo app-server"
  assert [%{profile: "codex-max", labels: %{any: ["complexity/high"]}}] = Config.settings!().codex.routes
end

test "codex multi-profile config rejects invalid profile references" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: "missing",
    codex_profiles: %{"codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"}},
    codex_routes: []
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "codex.default_profile"

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: "codex-mimo",
    codex_profiles: %{"codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"}},
    codex_routes: [%{"profile" => "codex-max", "labels" => %{"any" => ["complexity/high"]}}]
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "codex.routes"
  assert message =~ "codex-max"

  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: "codex-mimo",
    codex_profiles: %{"codex-mimo" => %{"command" => ""}},
    codex_routes: []
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "codex.profiles.codex-mimo.command"
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs
```

Expected: failures because `write_workflow_file!/2` does not emit multi-profile fields and `Schema.Codex` has no `default_profile`, `profiles`, or `routes` fields.

- [ ] **Step 3: Update test workflow helper to emit multi-profile Codex fields**

Modify `elixir/test/support/test_support.exs`:

1. In the default keyword list around existing `codex_command`, add:

```elixir
codex_default_profile: nil,
codex_profiles: %{},
codex_routes: [],
```

2. After `codex_command = Keyword.get(config, :codex_command)`, add:

```elixir
codex_default_profile = Keyword.get(config, :codex_default_profile)
codex_profiles = Keyword.get(config, :codex_profiles)
codex_routes = Keyword.get(config, :codex_routes)
```

3. Replace the `"codex:"` block entries around current `command` with:

```elixir
"codex:",
"  command: #{yaml_value(codex_command)}",
"  default_profile: #{yaml_value(codex_default_profile)}",
"  profiles: #{yaml_value(codex_profiles)}",
"  routes: #{yaml_value(codex_routes)}",
"  approval_policy: #{yaml_value(codex_approval_policy)}",
```

Keep existing `approval_policy`, `thread_sandbox`, `turn_sandbox_policy`, timeout, and stall fields after those lines.

- [ ] **Step 4: Add embedded schema types and fields**

In `elixir/lib/symphony_elixir/config/schema.ex`, inside `defmodule Codex`, add nested modules before `embedded_schema do`:

```elixir
defmodule Profile do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command], empty_values: [])
    |> validate_required([:command])
  end
end

defmodule RouteLabels do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:any, {:array, :string}, default: [])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:any], empty_values: [])
    |> validate_change(:any, fn :any, labels ->
      if Enum.any?(labels, &(is_binary(&1) and String.trim(&1) != "")) do
        []
      else
        [any: "must include at least one label"]
      end
    end)
  end
end

defmodule Route do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:profile, :string)
    embeds_one(:labels, RouteLabels, on_replace: :update)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:profile], empty_values: [])
    |> cast_embed(:labels, required: true)
    |> validate_required([:profile])
  end
end
```

Then extend `embedded_schema do` with:

```elixir
field(:default_profile, :string)
embeds_many(:routes, Route, on_replace: :delete)
```

Keep `field(:command, :string, default: "codex app-server")` for legacy mode.

- [ ] **Step 5: Add profile map casting and semantic validation**

Still in `defmodule Codex`, update `changeset/2` to cast new fields and then validate profiles:

```elixir
|> cast(
  attrs,
  [
    :command,
    :default_profile,
    :approval_policy,
    :thread_sandbox,
    :turn_sandbox_policy,
    :turn_timeout_ms,
    :read_timeout_ms,
    :stall_timeout_ms
  ],
  empty_values: []
)
|> put_profile_changes(attrs)
|> cast_embed(:routes)
|> validate_number(:turn_timeout_ms, greater_than: 0)
|> validate_number(:read_timeout_ms, greater_than: 0)
|> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
|> validate_codex_command_or_profiles()
|> validate_profile_references()
```

Add helper functions inside `defmodule Codex`:

```elixir
@spec profiles(%__MODULE__{}) :: map()
def profiles(%__MODULE__{} = codex), do: Map.get(codex, :profiles, %{})

defp put_profile_changes(changeset, attrs) do
  raw_profiles = Map.get(attrs, "profiles", Map.get(attrs, :profiles, %{}))

  case cast_profiles(raw_profiles) do
    {:ok, profiles} -> put_change(changeset, :profiles, profiles)
    {:error, message} -> add_error(changeset, :profiles, message)
  end
end

defp cast_profiles(nil), do: {:ok, %{}}
defp cast_profiles(raw_profiles) when raw_profiles == %{}, do: {:ok, %{}}

defp cast_profiles(raw_profiles) when is_map(raw_profiles) do
  raw_profiles
  |> Enum.reduce({:ok, %{}}, fn
    {name, attrs}, {:ok, acc} when is_binary(name) and is_map(attrs) ->
      changeset = Profile.changeset(%Profile{}, attrs)

      if changeset.valid? do
        {:ok, Map.put(acc, name, Ecto.Changeset.apply_changes(changeset))}
      else
        {:error, "invalid codex.profiles.#{name}.command"}
      end

    _entry, {:ok, _acc} ->
      {:error, "must be a map of profile names to profile objects"}

    _entry, {:error, _reason} = error ->
      error
  end)
end

defp cast_profiles(_raw_profiles), do: {:error, "must be a map of profile names to profile objects"}

defp validate_codex_command_or_profiles(changeset) do
  profiles = get_field(changeset, :profiles, %{})

  if map_size(profiles) > 0 do
    validate_required(changeset, [:default_profile])
  else
    validate_required(changeset, [:command])
  end
end

defp validate_profile_references(changeset) do
  profiles = get_field(changeset, :profiles, %{})
  default_profile = get_field(changeset, :default_profile)
  routes = get_field(changeset, :routes, [])

  changeset
  |> validate_default_profile(profiles, default_profile)
  |> validate_route_profiles(profiles, routes)
end

defp validate_default_profile(changeset, profiles, default_profile) do
  cond do
    map_size(profiles) == 0 ->
      changeset

    is_binary(default_profile) and Map.has_key?(profiles, default_profile) ->
      changeset

    true ->
      add_error(changeset, :default_profile, "must reference an existing codex profile")
  end
end

defp validate_route_profiles(changeset, profiles, routes) do
  Enum.reduce(routes, changeset, fn route, acc ->
    if is_binary(route.profile) and Map.has_key?(profiles, route.profile) do
      acc
    else
      add_error(acc, :routes, "profile #{inspect(route.profile)} must reference an existing codex profile")
    end
  end)
end
```

Because `Ecto.Schema` does not define a storage field for arbitrary `profiles`, add this field to `embedded_schema do` before `embeds_many(:routes, ...)`:

```elixir
field(:profiles, :map, default: %{})
```

- [ ] **Step 6: Run config tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs
```

Expected: tests pass for config validation, or only fail for exact error string formatting. If error strings differ, update assertions to match the real field names while preserving the validation requirements.

## Task 2: Add per-issue profile resolver

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Add failing routing tests**

Append to `elixir/test/symphony_elixir/core_test.exs` near config tests:

```elixir
test "codex runtime settings select profile from issue labels" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: nil,
    codex_default_profile: "codex-mimo",
    codex_profiles: %{
      "codex-max" => %{"command" => "/tmp/codex-max app-server"},
      "codex-mimo" => %{"command" => "/tmp/codex-mimo app-server"}
    },
    codex_routes: [
      %{"profile" => "codex-max", "labels" => %{"any" => ["complexity/high"]}}
    ],
    codex_approval_policy: "never"
  )

  high_issue = %Issue{id: "issue-high", labels: [" backend ", " Complexity/High "]}
  ordinary_issue = %Issue{id: "issue-normal", labels: ["backend"]}
  unlabeled_issue = %Issue{id: "issue-empty", labels: []}

  assert {:ok, high_settings} = Config.codex_runtime_settings_for_issue(high_issue)
  assert high_settings.command == "/tmp/codex-max app-server"
  assert high_settings.profile == "codex-max"
  assert high_settings.approval_policy == "never"

  assert {:ok, ordinary_settings} = Config.codex_runtime_settings_for_issue(ordinary_issue)
  assert ordinary_settings.command == "/tmp/codex-mimo app-server"
  assert ordinary_settings.profile == "codex-mimo"

  assert {:ok, unlabeled_settings} = Config.codex_runtime_settings_for_issue(unlabeled_issue)
  assert unlabeled_settings.command == "/tmp/codex-mimo app-server"
  assert unlabeled_settings.profile == "codex-mimo"
end

test "codex runtime settings preserve legacy command mode" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: "/tmp/legacy app-server",
    codex_approval_policy: "never"
  )

  assert {:ok, settings} = Config.codex_runtime_settings_for_issue(%Issue{id: "issue-legacy", labels: ["complexity/high"]})
  assert settings.command == "/tmp/legacy app-server"
  assert settings.profile == nil
  assert settings.approval_policy == "never"
end
```

- [ ] **Step 2: Run routing tests to verify they fail**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs
```

Expected: failure because `Config.codex_runtime_settings_for_issue/1` does not exist.

- [ ] **Step 3: Add resolver types and function**

Modify `elixir/lib/symphony_elixir/config.ex`.

Add alias:

```elixir
alias SymphonyElixir.Linear.Issue
```

Update `@type codex_runtime_settings` to include command/profile:

```elixir
@type codex_runtime_settings :: %{
        command: String.t(),
        profile: String.t() | nil,
        approval_policy: String.t() | map(),
        thread_sandbox: String.t(),
        turn_sandbox_policy: map()
      }
```

Add a new public function after existing `codex_runtime_settings/2`:

```elixir
@spec codex_runtime_settings_for_issue(Issue.t() | map(), Path.t() | nil, keyword()) ::
        {:ok, codex_runtime_settings()} | {:error, term()}
def codex_runtime_settings_for_issue(issue, workspace \\ nil, opts \\ []) do
  with {:ok, settings} <- settings(),
       {:ok, turn_sandbox_policy} <- Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts),
       {:ok, profile, command} <- resolve_codex_command(settings.codex, issue) do
    {:ok,
     %{
       command: command,
       profile: profile,
       approval_policy: settings.codex.approval_policy,
       thread_sandbox: settings.codex.thread_sandbox,
       turn_sandbox_policy: turn_sandbox_policy
     }}
  end
end
```

Update existing `codex_runtime_settings/2` to call the new command resolver in legacy-neutral form:

```elixir
@spec codex_runtime_settings(Path.t() | nil, keyword()) ::
        {:ok, codex_runtime_settings()} | {:error, term()}
def codex_runtime_settings(workspace \\ nil, opts \\ []) do
  codex_runtime_settings_for_issue(%Issue{labels: []}, workspace, opts)
end
```

Add private helpers:

```elixir
defp resolve_codex_command(%{profiles: profiles} = codex, issue) when is_map(profiles) and map_size(profiles) > 0 do
  selected_profile = select_codex_profile(codex.routes || [], issue) || codex.default_profile

  case Map.fetch(profiles, selected_profile) do
    {:ok, %{command: command}} when is_binary(command) -> {:ok, selected_profile, command}
    _ -> {:error, {:missing_codex_profile, selected_profile}}
  end
end

defp resolve_codex_command(%{command: command}, _issue) when is_binary(command) do
  {:ok, nil, command}
end

defp select_codex_profile(routes, issue) when is_list(routes) do
  issue_labels = normalized_issue_labels(issue)

  routes
  |> Enum.find(fn route -> route_matches?(route, issue_labels) end)
  |> case do
    nil -> nil
    route -> route.profile
  end
end

defp normalized_issue_labels(%Issue{} = issue), do: Issue.label_names(issue) |> normalize_labels()
defp normalized_issue_labels(%{labels: labels}) when is_list(labels), do: normalize_labels(labels)
defp normalized_issue_labels(_issue), do: MapSet.new()

defp normalize_labels(labels) do
  labels
  |> Enum.filter(&is_binary/1)
  |> Enum.map(&normalize_label/1)
  |> Enum.reject(&(&1 == ""))
  |> MapSet.new()
end

defp normalize_label(label) do
  label
  |> String.trim()
  |> String.downcase()
end

defp route_matches?(%{labels: %{any: labels}}, issue_labels) when is_list(labels) do
  labels
  |> Enum.map(&normalize_label/1)
  |> Enum.any?(&MapSet.member?(issue_labels, &1))
end

defp route_matches?(_route, _issue_labels), do: false
```

- [ ] **Step 4: Run routing tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs
```

Expected: core tests pass.

## Task 3: Launch selected command per app-server session

**Files:**
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`

- [ ] **Step 1: Add failing app-server selected-command test**

Append to `elixir/test/symphony_elixir/app_server_test.exs` after the turn sandbox policy test:

```elixir
test "app server launches the command selected for the issue profile" do
  test_root =
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-app-server-selected-command-#{System.unique_integer([:positive])}"
    )

  try do
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ROUTE")
    max_binary = Path.join(test_root, "fake-codex-max")
    mimo_binary = Path.join(test_root, "fake-codex-mimo")
    trace_file = Path.join(test_root, "selected-command.trace")
    previous_trace = System.get_env("SYMP_SELECTED_COMMAND_TRACE")

    on_exit(fn -> restore_env("SYMP_SELECTED_COMMAND_TRACE", previous_trace) end)
    System.put_env("SYMP_SELECTED_COMMAND_TRACE", trace_file)
    File.mkdir_p!(workspace)

    fake_codex = fn name ->
      """
      #!/bin/sh
      printf '#{name}\n' >> "${SYMP_SELECTED_COMMAND_TRACE}"
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-route"}}}' ;;
          3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-route"}}}' ;;
          4) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """
    end

    File.write!(max_binary, fake_codex.("codex-max"))
    File.write!(mimo_binary, fake_codex.("codex-mimo"))
    File.chmod!(max_binary, 0o755)
    File.chmod!(mimo_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: nil,
      codex_default_profile: "codex-mimo",
      codex_profiles: %{
        "codex-max" => %{"command" => "#{max_binary} app-server"},
        "codex-mimo" => %{"command" => "#{mimo_binary} app-server"}
      },
      codex_routes: [
        %{"profile" => "codex-max", "labels" => %{"any" => ["complexity/high"]}}
      ],
      codex_approval_policy: "never"
    )

    high_issue = %Issue{
      id: "issue-route-high",
      identifier: "MT-ROUTE",
      title: "Route high complexity",
      state: "In Progress",
      labels: ["complexity/high"]
    }

    normal_issue = %Issue{
      id: "issue-route-normal",
      identifier: "MT-ROUTE",
      title: "Route normal complexity",
      state: "In Progress",
      labels: ["backend"]
    }

    assert {:ok, _result} = AppServer.run(workspace, "High", high_issue)
    assert {:ok, _result} = AppServer.run(workspace, "Normal", normal_issue)

    assert File.read!(trace_file) == "codex-max\ncodex-mimo\n"
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: Run selected-command test to verify it fails**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/app_server_test.exs
```

Expected: failure because `AppServer.start_session/2` still starts `Config.settings!().codex.command`, not selected per issue.

- [ ] **Step 3: Thread selected runtime settings through AppServer**

Modify `elixir/lib/symphony_elixir/codex/app_server.ex`:

1. Update `@type session` to include:

```elixir
command: String.t(),
profile: String.t() | nil,
```

2. In `start_session/2`, before `start_port`, resolve runtime settings from opts:

```elixir
runtime_settings = Keyword.get(opts, :runtime_settings)
```

Replace:

```elixir
with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
     {:ok, port} <- start_port(expanded_workspace, worker_host) do
```

with:

```elixir
with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
     {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, runtime_settings),
     {:ok, port} <- start_port(expanded_workspace, worker_host, session_policies.command) do
```

Then remove the inner `with {:ok, session_policies} <- ...` and keep only `do_start_session` inside the port branch.

3. Add command/profile to returned session map:

```elixir
command: session_policies.command,
profile: Map.get(session_policies, :profile),
```

4. Change local `start_port/2` to `start_port/3`:

```elixir
defp start_port(workspace, nil, command) do
  executable = System.find_executable("bash")

  if is_nil(executable) do
    {:error, :bash_not_found}
  else
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(command)],
          cd: String.to_charlist(workspace),
          line: @port_line_bytes
        ]
      )

    {:ok, port}
  end
end
```

5. Change remote start:

```elixir
defp start_port(workspace, worker_host, command) when is_binary(worker_host) do
  remote_command = remote_launch_command(workspace, command)
  SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
end

defp remote_launch_command(workspace, command) when is_binary(workspace) and is_binary(command) do
  [
    "cd #{shell_escape(workspace)}",
    "exec #{command}"
  ]
  |> Enum.join(" && ")
end
```

6. Replace `session_policies/2` with:

```elixir
defp session_policies(workspace, nil, nil) do
  Config.codex_runtime_settings(workspace)
end

defp session_policies(_workspace, nil, runtime_settings) when is_map(runtime_settings) do
  {:ok, runtime_settings}
end

defp session_policies(workspace, worker_host, nil) when is_binary(worker_host) do
  Config.codex_runtime_settings(workspace, remote: true)
end

defp session_policies(_workspace, worker_host, runtime_settings) when is_binary(worker_host) and is_map(runtime_settings) do
  {:ok, runtime_settings}
end
```

- [ ] **Step 4: Resolve runtime settings in AgentRunner**

Modify `elixir/lib/symphony_elixir/agent_runner.ex`.

In `run_codex_turns/5`, before `AppServer.start_session`, add:

```elixir
runtime_settings =
  case Config.codex_runtime_settings_for_issue(issue, workspace, remote: is_binary(worker_host)) do
    {:ok, settings} -> settings
    {:error, reason} -> throw({:codex_runtime_settings_failed, reason})
  end
```

Replace:

```elixir
with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
```

with:

```elixir
with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host, runtime_settings: runtime_settings) do
```

Avoid changing continuation behavior: the same selected session command should be used for all turns inside that app-server session.

- [ ] **Step 5: Run app-server tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/app_server_test.exs
```

Expected: app server tests pass.

- [ ] **Step 6: Run core tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs
```

Expected: core tests pass.

## Task 4: Add command wrappers and update workflow/docs

**Files:**
- Create: `bin/agent-commands/codex-max`
- Create: `bin/agent-commands/codex-mimo`
- Modify: `workflows/mirofish-quant-engine.WORKFLOW.md`
- Modify: `docs/symphony-service-guide.md`
- Optional remove: `bin/agent-commands/codex-hh` if no workflow or docs reference remains

- [ ] **Step 1: Write wrapper scripts**

Create `bin/agent-commands/codex-max`:

```bash
#!/usr/bin/env bash
set -euo pipefail

exec /Users/deepzen/bin/codex-max app-server "$@"
```

Create `bin/agent-commands/codex-mimo`:

```bash
#!/usr/bin/env bash
set -euo pipefail

exec codex -m mimo/mimo-v2.5-pro app-server "$@"
```

Set both executable:

```bash
chmod +x /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-max /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-mimo
```

- [ ] **Step 2: Validate wrapper syntax**

Run:

```bash
bash -n /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-max
bash -n /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-mimo
```

Expected: both exit 0.

- [ ] **Step 3: Update mirofish workflow**

Change the `agent` and `codex` block in `workflows/mirofish-quant-engine.WORKFLOW.md` from the current single command form to:

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

- [ ] **Step 4: Update service guide**

In `docs/symphony-service-guide.md`, update the `Agent command profiles` section to say:

```markdown
`symphony/bin/agent-commands/` hosts per-provider/model wrapper scripts used by workflow profile routing. The current `mirofish-quant-engine` workflow uses:

- `codex-max` — high-capability heihei GPT-5.5 profile for `complexity/high` issues.
- `codex-mimo` — default `mimo/mimo-v2.5-pro` profile for ordinary issues.

These wrappers are distinct from Claude Code aliases; each script must launch a Codex-compatible app-server command.
```

Replace the old single-command YAML example with:

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

- [ ] **Step 5: Remove obsolete codex-hh wrapper only if unused**

Run:

```bash
grep -R "codex-hh" /Volumes/HY2TB/projects/symphony/bin /Volumes/HY2TB/projects/symphony/workflows /Volumes/HY2TB/projects/symphony/docs -n || true
```

If the only match is `bin/agent-commands/codex-hh`, remove it:

```bash
rm /Volumes/HY2TB/projects/symphony/bin/agent-commands/codex-hh
```

If docs or workflow still mention it, update those references first and rerun the grep.

- [ ] **Step 6: Validate workflow YAML front matter parses**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file("/Volumes/HY2TB/projects/symphony/workflows/mirofish-quant-engine.WORKFLOW.md"); puts "yaml-ok"'
```

Expected: `yaml-ok`.

## Task 5: End-to-end validation

**Files:**
- No planned file edits.

- [ ] **Step 1: Run focused tests**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/app_server_test.exs
```

Expected: all tests pass.

- [ ] **Step 2: Run broader Elixir test suite**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 3: Run formatting check**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix format --check-formatted
```

Expected: exit 0.

If formatting fails, run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix format
```

Then rerun the formatting check.

- [ ] **Step 4: Build escript**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony/elixir
/opt/homebrew/bin/mise exec -- mix build
```

Expected: `Generated escript bin/symphony` or successful no-op build, and `elixir/bin/symphony` remains executable.

- [ ] **Step 5: Validate service dry-run still works**

Run:

```bash
cd /Volumes/HY2TB/projects/symphony
./bin/symphony-service install mirofish \
  --workflow workflows/mirofish-quant-engine.WORKFLOW.md \
  --port 4001 \
  --dry-run > /tmp/mirofish-symphony.plist
plutil -lint /tmp/mirofish-symphony.plist
```

Expected: plist is valid XML.

- [ ] **Step 6: Report validation limits**

If no real launchd service is started, report that code and dry-run validation passed but live daemon startup remains untested. Do not install or start the launchd service unless the user explicitly asks.

## Self-review checklist

- Spec coverage:
  - Single service: covered by workflow/service dry-run and no new service instances.
  - `codex-max` high-complexity route: covered by config, resolver, app-server tests, workflow.
  - `codex-mimo` default: covered by config, resolver, app-server tests, workflow.
  - Global concurrency 2: covered by workflow update.
  - No profile-level concurrency: no schema or scheduler changes for profile concurrency.
  - No automatic fallback: error path remains existing selected-command failure path.
- Placeholder scan: no TBD/TODO placeholders are present.
- Type consistency:
  - `default_profile`, `profiles`, `routes`, `labels.any`, `profile`, and `command` are used consistently across schema, resolver, tests, and workflow.
