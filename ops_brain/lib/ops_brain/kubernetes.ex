defmodule OpsBrain.Kubernetes do
  @moduledoc "Namespace-scoped Pod list/watch status projection. No specs, Secrets, logs or execution subresources."
  alias OpsBrain.{Transport, SourceConfig, Store}

  def reconcile(c, now, fence \\ nil)

  def reconcile(%{resources: resources} = c, now, fence) when is_list(resources),
    do: OpsBrain.WorkloadCollection.reconcile(c, now, fence)

  def reconcile(c, now, _fence) do
    with true <-
           is_binary(c[:namespace]) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}$/, c.namespace),
         {:ok, previous} <-
           SourceConfig.transaction(c.id, fn _ ->
             Store.one(
               "SELECT data FROM observation_windows WHERE source_id=$1::text::uuid AND kind='kubernetes' ORDER BY received_at DESC LIMIT 1",
               [c.id]
             )
           end) do
      state = if previous, do: previous["data"], else: nil

      if state && state["resource_version"] && state["coverage"] == "complete" do
        case Transport.get(c, path(c), [
               {"watch", "true"},
               {"resourceVersion", state["resource_version"]},
               {"timeoutSeconds", 10},
               {"allowWatchBookmarks", "true"}
             ]) do
          {:ok, %{status: 410}} ->
            list(c, true, now)

          {:ok, %{status: 200, body: body}} ->
            case decode_watch(state, body) do
              {:error, :expired} -> list(c, true, now)
              result -> result
            end

          _ ->
            {:error, :watch_disconnected}
        end
      else
        list(c, state != nil, now)
      end
    else
      _ -> {:error, :unapproved_namespace}
    end
  end

  defp path(c), do: "/api/v1/namespaces/#{c.namespace}/pods"

  defp list(c, gap, _now) do
    with {:ok, %{status: 200, body: body}} <- Transport.get(c, path(c), [{"limit", 200}]),
         {:ok, decoded} <- Jason.decode(body) do
      initial(decoded, c.namespace, gap)
    else
      _ -> {:error, :list_unavailable}
    end
  end

  def initial(%{"metadata" => meta, "items" => items}, namespace, gap)
      when is_list(items) and length(items) <= 200 do
    with true <- is_binary(meta["resourceVersion"]),
         {:ok, objects} <- objects(items, namespace) do
      {:ok,
       %{
         "objects" => objects,
         "namespace" => namespace,
         "resource_version" => meta["resourceVersion"],
         "gap" => gap,
         "initial_snapshot" => true,
         "condition" => "unknown",
         "coverage" => if(meta["continue"] in [nil, ""], do: "complete", else: "partial"),
         "changes" => [],
         "missing" => "Initial inventory is not a new deployment; no cluster-wide coverage"
       }}
    else
      _ -> {:error, :malformed_list}
    end
  end

  def initial(_, _, _), do: {:error, :malformed_list}

  defp objects(items, namespace) do
    Enum.reduce_while(items, {:ok, %{}}, fn item, {:ok, acc} ->
      case sanitize(item, namespace) do
        {:ok, o} -> {:cont, {:ok, Map.put(acc, o["uid"], o)}}
        error -> {:halt, error}
      end
    end)
  end

  defp sanitize(%{"metadata" => m, "status" => s}, namespace) do
    if m["namespace"] == namespace and is_binary(m["uid"]) and is_binary(m["resourceVersion"]) do
      statuses = Enum.take(s["containerStatuses"] || [], 20)

      {:ok,
       %{
         "uid" => m["uid"],
         "name" => OpsBrain.Redactor.clean(m["name"], 100),
         "resource_version" => m["resourceVersion"],
         "owners" =>
           Enum.map(
             Enum.take(m["ownerReferences"] || [], 5),
             &Map.take(&1, ["uid", "kind", "name"])
           ),
         "ready" => Enum.all?(statuses, &(&1["ready"] == true)) and statuses != [],
         "restarts" =>
           Enum.reduce(statuses, 0, fn r, n -> n + max(r["restartCount"] || 0, 0) end),
         "phase" => s["phase"]
       }}
    else
      {:error, :out_of_scope_object}
    end
  end

  defp sanitize(_, _), do: {:error, :malformed_object}

  def decode_watch(state, body) do
    lines = String.split(body, "\n", trim: true)
    if length(lines) > 200, do: {:error, :watch_cap}, else: reduce_events(state, lines)
  end

  defp reduce_events(state, lines) do
    Enum.reduce_while(
      lines,
      {:ok,
       Map.merge(state, %{"changes" => [], "initial_snapshot" => false, "condition" => "unknown"})},
      fn line, {:ok, s} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "ERROR", "object" => %{"code" => 410}}} ->
            {:halt, {:error, :expired}}

          {:ok, %{"type" => "BOOKMARK", "object" => %{"metadata" => %{"resourceVersion" => rv}}}}
          when is_binary(rv) ->
            {:cont, {:ok, Map.put(s, "resource_version", rv)}}

          {:ok, %{"type" => type, "object" => obj}}
          when type in ["ADDED", "MODIFIED", "DELETED"] ->
            case sanitize(obj, s["namespace"]) do
              {:ok, o} ->
                old = s["objects"][o["uid"]]

                change =
                  if old && old["resource_version"] != o["resource_version"] &&
                       o["restarts"] > old["restarts"],
                     do: [
                       %{"uid" => o["uid"], "restart_delta" => o["restarts"] - old["restarts"]}
                     ],
                     else: []

                objects =
                  if type == "DELETED",
                    do: Map.delete(s["objects"], o["uid"]),
                    else: Map.put(s["objects"], o["uid"], o)

                if map_size(objects) > 200 do
                  {:halt, {:error, :inventory_cap}}
                else
                  {:cont,
                   {:ok,
                    Map.merge(s, %{
                      "objects" => objects,
                      "resource_version" => o["resource_version"],
                      "changes" => s["changes"] ++ change,
                      "condition" => if(change == [], do: s["condition"], else: "warning")
                    })}}
                end

              error ->
                {:halt, error}
            end

          _ ->
            {:halt, {:error, :malformed_watch}}
        end
      end
    )
  end
end
