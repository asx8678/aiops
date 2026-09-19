defmodule OpsBrain.OperationPolicy do
  @moduledoc "Outbound observation operation allowlist, independent of HTTP method."
  def allowed?(%{kind: "azure_build"} = c, path) do
    base = "/#{c.organization}/#{c.project_id}/_apis/build/builds"

    path == base or
      (String.starts_with?(path, base <> "/") and
         Regex.match?(
           ~r/^\/[1-9][0-9]*(?:\/timeline|\/logs\/[1-9][0-9]*)?$/,
           String.replace_prefix(path, base, "")
         ))
  end

  def allowed?(%{kind: "prometheus"}, path), do: path == "/api/v1/query"

  def allowed?(%{kind: "loki"}, path),
    do: path in ["/loki/api/v1/query", "/loki/api/v1/query_range"]

  def allowed?(%{kind: "kubernetes", namespace: ns} = c, path),
    do: Enum.any?(Map.get(c, :resources, ["pods"]), &(path == OpsBrain.Workloads.path(&1, ns)))

  def allowed?(_, _), do: false
end
