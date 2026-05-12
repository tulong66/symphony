defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @difficulty_labels ["difficulty/high", "difficulty/medium", "difficulty/low"]
  @difficulty_label_set MapSet.new(@difficulty_labels)

  @type codex_runtime_settings :: %{
          command: String.t(),
          profile: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    codex_runtime_settings_for_issue(%Issue{labels: []}, workspace, opts)
  end

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

  defp resolve_codex_command(%{profiles: profiles} = codex, issue) when is_map(profiles) and map_size(profiles) > 0 do
    with {:ok, selected_profile} <- select_required_codex_profile(codex.routes || [], issue) do
      case Map.fetch(profiles, selected_profile) do
        {:ok, %{command: command}} when is_binary(command) -> {:ok, selected_profile, command}
        _ -> {:error, {:missing_codex_profile, selected_profile}}
      end
    end
  end

  defp resolve_codex_command(%{command: command}, _issue) when is_binary(command) do
    {:ok, nil, command}
  end

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

  defp normalized_issue_labels(%Issue{} = issue), do: issue |> Issue.label_names() |> normalize_labels()
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

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
