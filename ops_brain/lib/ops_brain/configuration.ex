defmodule OpsBrain.Configuration do
  @moduledoc "Bounded deployment-owned JSON, not operator/source payload configuration. Secrets are environment references only."
  @keys ~w(id company_id kind endpoint approved_origins approved_ips network_reviewed enabled anonymous_approved credential_env ca_file interval_seconds max_bytes page_size max_pages max_window_seconds retention_days requests_per_minute organization project_id definitions stage_targets stage_identifier service_id namespace resources inventory_limit tenant service_id profile reviewed version query numerator_query denominator_query minimum_traffic selector unit semantics threshold minimum_count freshness_seconds capacity_segment capacity_policy limits_verified max_gap_seconds min_history_seconds effective_threshold min_growth_bytes_per_second warning_horizon_seconds approved url approved_urls approved_ip digest_seconds cooldown_seconds quiet_utc_hours)a
  @lookup Map.new(@keys, &{Atom.to_string(&1), &1})
  def load! do
    if path = System.get_env("OPS_BRAIN_CONFIG_FILE") do
      cfg = read!(path)
      for {key, value} <- cfg, do: Application.put_env(:ops_brain, key, value)
    end
  end

  def read!(path) do
    with {:ok, %{size: size}} when size <= 65536 <- File.stat(path),
         {:ok, raw} <- File.read(path),
         {:ok, %{"sources" => sources} = root} <- Jason.decode(raw),
         true <- is_list(sources) and length(sources) <= 100 do
      sources = Enum.map(sources, &convert!/1)

      if length(Enum.uniq_by(sources, & &1.id)) != length(sources),
        do: raise("duplicate source ID")

      if Enum.any?(Enum.group_by(sources, & &1.company_id), fn {_, rows} -> length(rows) > 10 end),
         do: raise("pilot limit: ten sources per company")

      if Enum.any?(sources, fn s ->
           s[:enabled] == true and (placeholder?(s) or OpsBrain.SourceConfig.validate(s) != :ok)
         end),
         do: raise("invalid source configuration")

      sinks =
        Map.new(Map.get(root, "notification_sinks", %{}), fn {name, s} ->
          if not is_binary(name) or byte_size(name) > 80, do: raise("invalid destination name")
          {name, convert!(s)}
        end)

      if map_size(sinks) > 20, do: raise("destination limit")

      if Enum.any?(sinks, fn {_, s} ->
           s[:enabled] == true and
             (placeholder?(s) or not OpsBrain.Notifications.approved?(s, s[:company_id]))
         end),
         do: raise("invalid or placeholder notification configuration")

      companies = Enum.map(sources, & &1.company_id) |> Enum.uniq()

      if length(companies) > 1 and root["multi_company_reviewed"] != true,
        do: raise("multi-company security review required")

      %{
        sources: Map.new(sources, &{&1.id, &1}),
        notification_sinks: sinks,
        maintenance_enabled: root["maintenance_enabled"] == true,
        collection_enabled: root["collection_enabled"] == true,
        delivery_enabled: root["delivery_enabled"] == true
      }
    else
      _ -> raise "Invalid or oversized Ops Brain deployment configuration"
    end
  end

  defp convert!(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      atom = Map.get(@lookup, key) || raise("unknown configuration field")
      {atom, if(is_map(value), do: convert!(value), else: value)}
    end)
  end

  defp convert!(_), do: raise("configuration object required")

  # File templates cannot be activated by just flipping the enabled switch.
  defp placeholder?(v) when is_map(v), do: Enum.any?(Map.values(v), &placeholder?/1)
  defp placeholder?(v) when is_list(v), do: Enum.any?(v, &placeholder?/1)

  defp placeholder?(v) when is_binary(v),
    do:
      String.contains?(v, ["REPLACE_", "replace-", ".invalid"]) or
        Regex.match?(~r/^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)/, v)

  defp placeholder?(_), do: false
end
