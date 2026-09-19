defmodule OpsBrain.Workloads do
  @moduledoc "Bounded namespace workload inventory and transitions. Identity is always a UID, never a reusable name."
  alias OpsBrain.Redactor

  @kinds %{
    "pods" => "Pod",
    "deployments" => "Deployment",
    "replicasets" => "ReplicaSet",
    "events" => "Event"
  }
  def resources, do: Map.keys(@kinds)

  def path(resource, ns) when resource in ["deployments", "replicasets"],
    do: "/apis/apps/v1/namespaces/#{ns}/#{resource}"

  def path(resource, ns) when resource in ["pods", "events"],
    do: "/api/v1/namespaces/#{ns}/#{resource}"

  def empty(resource, namespace, gap \\ false),
    do: %{
      "resource" => resource,
      "namespace" => namespace,
      "objects" => %{},
      "coverage" => "partial",
      "condition" => "unknown",
      "gap" => gap,
      "changes" => [],
      "continuation" => nil,
      "resource_version" => nil,
      "initial_snapshot" => true,
      "phase" => "list"
    }

  def list_page(state, data, cap, page_limit \\ 100)

  def list_page(state, %{"metadata" => meta, "items" => items}, cap, page_limit)
      when is_list(items) and is_map(meta) do
    rv = meta["resourceVersion"]
    token = meta["continue"] || ""

    with true <- bounded?(rv, 512) and is_binary(token) and byte_size(token) <= 2048,
         true <- state["resource_version"] in [nil, rv],
         true <- token == "" or OpsBrain.Store.digest(token) not in Map.get(state, "tokens", []),
         true <- Map.get(state, "pages", 0) < page_limit,
         {:ok, objects} <- sanitize_all(items, state) do
      merged = Map.merge(state["objects"], objects)

      if map_size(merged) <= cap do
        {:ok,
         Map.merge(state, %{
           "objects" => merged,
           "resource_version" => rv,
           "continuation" => if(token == "", do: nil, else: token),
           "changes" => [],
           "pages" => Map.get(state, "pages", 0) + 1,
           "tokens" =>
             Enum.take([OpsBrain.Store.digest(token) | Map.get(state, "tokens", [])], 100),
           "error" => nil,
           "initial_snapshot" => true,
           "phase" => if(token == "", do: "watch", else: "list"),
           "coverage" => if(token == "", do: "complete", else: "partial")
         })}
      else
        {:error, :inventory_cap}
      end
    else
      _ -> {:error, :malformed_or_inconsistent_list}
    end
  end

  def list_page(_, _, _, _), do: {:error, :malformed_list}

  def watch(state, body, cap) do
    lines = String.split(body, "\n", trim: true)

    if length(lines) > 200 do
      {:error, :watch_cap}
    else
      Enum.reduce_while(
        lines,
        {:ok,
         Map.merge(state, %{
           "changes" => [],
           "initial_snapshot" => false,
           "phase" => "watch",
           "coverage" => "complete",
           "error" => nil
         })},
        fn line, {:ok, s} ->
          case event(s, Jason.decode(line), cap) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp event(_, {:ok, %{"type" => "ERROR", "object" => %{"code" => 410}}}, _),
    do: {:error, :expired}

  defp event(
         s,
         {:ok, %{"type" => "BOOKMARK", "object" => %{"metadata" => %{"resourceVersion" => rv}}}},
         _
       ) do
    if bounded?(rv, 512),
      do: {:ok, Map.put(s, "resource_version", rv)},
      else: {:error, :invalid_version}
  end

  defp event(s, {:ok, %{"type" => type, "object" => raw}}, cap)
       when type in ["ADDED", "MODIFIED", "DELETED"] do
    with {:ok, obj} <- sanitize(raw, s["resource"], s["namespace"]) do
      old = s["objects"][obj["uid"]]
      changes = if type == "DELETED" and is_nil(old), do: [], else: transitions(old, obj)

      objects =
        if type == "DELETED",
          do: Map.delete(s["objects"], obj["uid"]),
          else: Map.put(s["objects"], obj["uid"], obj)

      if map_size(objects) <= cap do
        {:ok,
         Map.merge(s, %{
           "objects" => objects,
           "resource_version" => obj["resource_version"],
           "changes" => s["changes"] ++ changes
         })}
      else
        {:error, :inventory_cap}
      end
    end
  end

  defp event(_, _, _), do: {:error, :malformed_watch}

  def sanitize(%{"metadata" => m} = raw, resource, namespace) when is_map(m) do
    with true <-
           m["namespace"] == namespace and bounded?(m["uid"], 128) and
             bounded?(m["resourceVersion"], 512),
         true <- raw["kind"] in [nil, @kinds[resource]],
         true <- is_list(m["ownerReferences"] || []),
         true <-
           (raw["status"] == nil or is_map(raw["status"])) and
             (raw["involvedObject"] == nil or is_map(raw["involvedObject"])),
         true <- raw["series"] == nil or is_map(raw["series"]),
         {:ok, status} <- status(resource, raw) do
      owners = Enum.take(m["ownerReferences"] || [], 5)

      if Enum.all?(
           owners,
           &(is_map(&1) and bounded?(&1["uid"], 128) and
               &1["kind"] in ["Deployment", "ReplicaSet", "StatefulSet", "Job", "CronJob"])
         ) do
        {:ok,
         Map.merge(
           %{
             "uid" => m["uid"],
             "name" => Redactor.clean(m["name"], 100),
             "kind" => @kinds[resource],
             "resource_version" => m["resourceVersion"],
             "generation" => integer(m["generation"]),
             "owners" => Enum.map(owners, &Map.take(&1, ["uid", "kind"]))
           },
           status
         )}
      else
        {:error, :invalid_owner}
      end
    else
      _ -> {:error, :out_of_scope_or_malformed_object}
    end
  end

  def sanitize(_, _, _), do: {:error, :malformed_object}

  defp status("pods", raw) do
    s = raw["status"] || %{}

    rows =
      if is_list(s["containerStatuses"] || []) and is_list(s["initContainerStatuses"] || []),
        do: (s["containerStatuses"] || []) ++ (s["initContainerStatuses"] || []),
        else: :invalid

    if is_list(rows) and length(rows) <= 40 and
         Enum.all?(
           rows,
           &(is_map(&1) and (&1["lastState"] == nil or is_map(&1["lastState"])) and
               (get_in(&1, ["lastState", "terminated"]) == nil or
                  is_map(get_in(&1, ["lastState", "terminated"]))))
         ) do
      containers =
        Enum.map(rows, fn c ->
          term = get_in(c, ["lastState", "terminated"]) || %{}

          %{
            "name" => Redactor.clean(c["name"], 100),
            "restarts" => integer(c["restartCount"]),
            "ready" => c["ready"] == true,
            "termination" => %{
              "reason" => Redactor.clean(term["reason"], 100),
              "finished_at" => safe_time(term["finishedAt"]),
              "exit_code" => integer(term["exitCode"])
            }
          }
        end)

      {:ok,
       %{
         "containers" => containers,
         "ready" => containers != [] and Enum.all?(containers, & &1["ready"]),
         "phase" => Redactor.clean(s["phase"], 40)
       }}
    else
      {:error, :invalid_containers}
    end
  end

  defp status(resource, raw) when resource in ["deployments", "replicasets"] do
    s = raw["status"] || %{}

    {:ok,
     %{
       "observed_generation" => integer(s["observedGeneration"]),
       "replicas" => integer(s["replicas"]),
       "ready_replicas" => integer(s["readyReplicas"]),
       "available_replicas" => integer(s["availableReplicas"])
     }}
  end

  defp status("events", raw) do
    target = raw["involvedObject"] || %{}

    {:ok,
     %{
       "target_uid" => clean_id(target["uid"]),
       "target_kind" => Redactor.clean(target["kind"], 60),
       "count" => integer(raw["count"] || get_in(raw, ["series", "count"]) || 1),
       "type" => Redactor.clean(raw["type"], 30),
       "reason" => Redactor.clean(raw["reason"], 100),
       "last_seen" =>
         safe_time(
           raw["lastTimestamp"] || get_in(raw, ["series", "lastObservedTime"]) || raw["eventTime"]
         )
     }}
  end

  defp status(_, _), do: {:error, :unsupported_resource}

  def transitions(nil, %{"kind" => "Event"} = obj),
    do: [
      %{
        "uid" => obj["uid"],
        "kind" => "Event",
        "target_uid" => obj["target_uid"],
        "count_delta" => obj["count"],
        "count" => obj["count"],
        "resource_version" => obj["resource_version"],
        "reason" => obj["reason"],
        "type" => obj["type"]
      }
    ]

  def transitions(nil, _), do: []
  def transitions(%{"resource_version" => rv}, %{"resource_version" => rv}), do: []

  def transitions(old, %{"kind" => "Pod"} = obj) do
    for c <- obj["containers"],
        prior = Enum.find(old["containers"], &(&1["name"] == c["name"])),
        prior != nil,
        c["restarts"] > prior["restarts"] do
      %{
        "uid" => obj["uid"],
        "kind" => "Pod",
        "container" => c["name"],
        "restart_delta" => c["restarts"] - prior["restarts"],
        "restart_count" => c["restarts"],
        "resource_version" => obj["resource_version"],
        "oom" =>
          c["termination"]["reason"] == "OOMKilled" and c["termination"] != prior["termination"],
        "termination" => c["termination"]
      }
    end
  end

  def transitions(old, %{"kind" => "Event"} = obj) do
    if obj["count"] > old["count"],
      do: [
        %{
          "uid" => obj["uid"],
          "kind" => "Event",
          "target_uid" => obj["target_uid"],
          "count_delta" => obj["count"] - old["count"],
          "count" => obj["count"],
          "resource_version" => obj["resource_version"],
          "reason" => obj["reason"],
          "type" => obj["type"]
        }
      ],
      else: []
  end

  def transitions(old, %{"kind" => kind} = obj) when kind in ["Deployment", "ReplicaSet"] do
    if obj["generation"] > old["generation"],
      do: [
        %{
          "uid" => obj["uid"],
          "kind" => kind,
          "generation" => obj["generation"],
          "relation" => "observed generation change, not deployment success"
        }
      ],
      else: []
  end

  def transitions(_, _), do: []

  def summary(states, resources, now, freshness) do
    all = for {_, s} <- states, {uid, o} <- s["objects"], into: %{}, do: {uid, o}
    selected = Map.take(states, resources)

    complete =
      Enum.all?(resources, fn r ->
        s = selected[r]

        s != nil and s["coverage"] == "complete" and is_integer(s["observed_at"]) and
          now - s["observed_at"] <= freshness
      end)

    changes = Enum.flat_map(selected, fn {_, s} -> s["changes"] || [] end)

    %{
      "coverage" => if(complete, do: "complete", else: "partial"),
      "condition" => condition(changes),
      "source_error" => Enum.find_value(selected, fn {_, s} -> s["error"] end),
      "gap" => Enum.any?(selected, fn {_, s} -> s["gap"] == true end),
      "changes" => changes,
      "resources" =>
        Map.new(selected, fn {r, s} ->
          {r,
           Map.take(s, [
             "coverage",
             "resource_version",
             "observed_at",
             "gap",
             "initial_snapshot",
             "error"
           ])}
        end),
      "inventory_counts" => Map.new(selected, fn {r, s} -> {r, map_size(s["objects"])} end),
      "owner_chains" =>
        all
        |> Enum.filter(fn {_, o} -> o["kind"] == "Pod" end)
        |> Enum.take(100)
        |> Map.new(fn {uid, _} -> {uid, owner_chain(uid, all, [])} end),
      "missing" =>
        "Configured namespace/resources only. No changes is not proof of workload health; owner links require matching UIDs."
    }
  end

  def condition(changes) do
    cond do
      Enum.any?(changes, &(&1["oom"] == true)) ->
        "critical"

      Enum.any?(changes, &(is_integer(&1["restart_delta"]) or &1["type"] == "Warning")) ->
        "warning"

      true ->
        "unknown"
    end
  end

  defp owner_chain(uid, all, seen) do
    case all[uid] do
      nil ->
        %{"uids" => Enum.reverse(seen), "complete" => false}

      o when length(seen) < 8 ->
        cond do
          uid in seen -> %{"uids" => Enum.reverse(seen), "complete" => false}
          o["owners"] == [] -> %{"uids" => Enum.reverse([uid | seen]), "complete" => true}
          length(o["owners"]) == 1 -> owner_chain(hd(o["owners"])["uid"], all, [uid | seen])
          true -> %{"uids" => Enum.reverse([uid | seen]), "complete" => false}
        end

      _ ->
        %{"uids" => Enum.reverse(seen), "complete" => false}
    end
  end

  defp sanitize_all(items, state) do
    Enum.reduce_while(items, {:ok, %{}}, fn raw, {:ok, acc} ->
      case sanitize(raw, state["resource"], state["namespace"]) do
        {:ok, o} -> {:cont, {:ok, Map.put(acc, o["uid"], o)}}
        error -> {:halt, error}
      end
    end)
  end

  defp bounded?(v, n), do: is_binary(v) and byte_size(v) in 1..n
  defp integer(n) when is_integer(n) and n >= 0, do: n
  defp integer(_), do: 0
  defp clean_id(id), do: if(bounded?(id, 128), do: id, else: nil)

  defp safe_time(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp safe_time(_), do: nil
end
