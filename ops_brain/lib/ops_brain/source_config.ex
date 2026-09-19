defmodule OpsBrain.SourceConfig do
  @moduledoc "Trusted deployment configuration only. Payloads/jobs cannot override company, endpoint, tenant, queries or credentials."
  alias OpsBrain.{Repo, Store}
  @kinds ~w(azure_build prometheus loki kubernetes)
  def all, do: Application.get_env(:ops_brain, :sources, %{})

  def fetch(id) do
    with true <- is_binary(id),
         {:ok, c} <- Map.fetch(all(), id),
         :ok <- validate(c),
         true <- c.id == id do
      {:ok, c}
    else
      _ -> {:error, :source_disabled_or_invalid}
    end
  end

  def validate(c) when is_map(c) do
    uri = URI.parse(c[:endpoint] || "")

    with {:ok, _} <- Ecto.UUID.cast(c[:id]),
         {:ok, _} <- Ecto.UUID.cast(c[:company_id]),
         true <- c[:kind] in @kinds,
         true <- c[:enabled] == true,
         true <-
           uri.scheme == "https" and is_binary(uri.host) and uri.userinfo == nil and
             uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, "", "/"],
         true <- c[:endpoint] in (c[:approved_origins] || []),
         true <- c[:network_reviewed] == true,
         true <- is_integer(c[:interval_seconds]) and c.interval_seconds >= 30,
         true <- is_integer(c[:max_bytes]) and c.max_bytes in 1024..2_000_000,
         true <- is_integer(c[:page_size]) and c.page_size in 1..200,
         true <- is_integer(c[:max_pages]) and c.max_pages in 1..100,
         true <- is_integer(c[:max_window_seconds]) and c.max_window_seconds in 60..86400,
         true <- is_integer(c[:retention_days]) and c.retention_days in 1..90,
         true <- is_list(c[:approved_ips]) and length(c.approved_ips) in 1..8,
         true <-
           Enum.all?(c.approved_ips, fn ip ->
             is_binary(ip) and match?({:ok, _}, :inet.parse_address(String.to_charlist(ip)))
           end),
         true <- Map.get(c, :requests_per_minute, 6) in 1..60,
         :ok <- kind_valid(c) do
      :ok
    else
      _ -> {:error, :invalid_source_configuration}
    end
  end

  def validate(_), do: {:error, :invalid_source_configuration}

  defp kind_valid(%{kind: "azure_build"} = c) do
    with {:ok, _} <- Ecto.UUID.cast(c[:project_id]),
         true <- is_list(c[:definitions]) and c.definitions != [] and length(c.definitions) <= 50,
         true <- Enum.all?(c.definitions, &(is_integer(&1) and &1 > 0)),
         true <- valid_stage_targets?(Map.get(c, :stage_targets, [])),
         true <-
           is_binary(c[:organization]) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,80}$/, c.organization) do
      :ok
    else
      _ -> {:error, :invalid_build_scope}
    end
  end

  defp kind_valid(%{kind: kind, profile: p}) when kind in ["prometheus", "loki"] and is_map(p) do
    with true <- p[:reviewed] == true,
         true <- is_binary(p[:id]) and byte_size(p.id) in 1..80,
         true <- is_integer(p[:version]) and p.version > 0,
         true <-
           is_integer(Map.get(p, :freshness_seconds, 120)) and
             Map.get(p, :freshness_seconds, 120) in 1..3600,
         true <-
           if(kind == "prometheus",
             do: metric_profile?(p),
             else: is_binary(p[:selector]) and byte_size(p.selector) <= 1000
           ) do
      :ok
    else
      _ -> {:error, :invalid_profile}
    end
  end

  defp kind_valid(%{kind: "kubernetes", namespace: ns} = c) when is_binary(ns) do
    resources = Map.get(c, :resources, ["pods"])

    if Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}$/, ns) and
         is_list(resources) and length(resources) in 1..4 and
         Enum.uniq(resources) == resources and
         Enum.all?(resources, &(&1 in OpsBrain.Workloads.resources())) and
         Map.get(c, :inventory_limit, 200) in 1..500,
       do: :ok,
       else: {:error, :invalid_namespace}
  end

  defp kind_valid(_), do: {:error, :missing_profile}

  defp metric_profile?(%{semantics: "gauge", query: query}),
    do: is_binary(query) and byte_size(query) in 1..2000

  defp metric_profile?(%{
         semantics: "ratio",
         unit: "ratio",
         numerator_query: n,
         denominator_query: d,
         minimum_traffic: minimum
       }),
       do:
         is_binary(n) and byte_size(n) in 1..2000 and is_binary(d) and byte_size(d) in 1..2000 and
           is_number(minimum) and minimum > 0

  defp metric_profile?(_), do: false

  defp valid_stage_targets?(mappings) when is_list(mappings) and length(mappings) <= 20 do
    Enum.all?(mappings, fn
      %{"stage_identifier" => stage, "service_id" => service} ->
        is_binary(stage) and byte_size(stage) in 1..100 and
          match?({:ok, _}, Ecto.UUID.cast(service))

      _ ->
        false
    end)
  end

  defp valid_stage_targets?(_), do: false

  # Internal worker entry. Job arguments carry only a source ID resolved above.
  def transaction(id, fun) do
    with {:ok, c} <- fetch(id) do
      Repo.transaction(fn ->
        if Repo.query!("SELECT current_setting('ops_brain.company_id',true)").rows not in [
             [[nil]],
             [[""]]
           ],
           do: Repo.rollback(:nested_scope)

        Repo.query!("SELECT set_config('ops_brain.company_id',$1,true)", [c.company_id])

        case Store.one(
               "SELECT id::text, kind FROM sources WHERE company_id=$1::text::uuid AND id=$2::text::uuid",
               [c.company_id, c.id]
             ) do
          %{"kind" => kind} when kind == c.kind -> :ok
          _ -> Repo.rollback(:source_scope_mismatch)
        end

        result = fun.(c)
        Repo.query!("SELECT set_config('ops_brain.company_id','',true)")
        result
      end)
    end
  end
end
