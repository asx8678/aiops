defmodule OpsBrain.WorkloadCollection do
  @moduledoc "One bounded list page/watch per tick, round-robin resources, persisted cursor CAS and collection fencing."
  alias OpsBrain.{SourceConfig, Store, Repo, Transport, Workloads}

  def reconcile(c, now, fence) do
    with {:ok, rows} <-
           SourceConfig.transaction(c.id, fn _ ->
             Store.rows(
               "SELECT resource,revision,data,updated_at FROM kubernetes_cursors WHERE source_id=$1::text::uuid",
               [c.id]
             )
           end) do
      resources = c.resources
      states = Map.new(rows, &{&1["resource"], &1["data"]})

      resource =
        Enum.min_by(resources, fn r ->
          row = Enum.find(rows, &(&1["resource"] == r))
          if row, do: DateTime.to_unix(row["updated_at"], :microsecond), else: 0
        end)

      row = Enum.find(rows, &(&1["resource"] == resource))
      scope = Store.digest({c.endpoint, c.namespace, c.approved_ips, c[:credential_env]})

      state =
        if row && row["data"]["scope"] == scope,
          do: row["data"],
          else: Workloads.empty(resource, c.namespace, row != nil)

      state = Map.put(state, "scope", scope)
      cap = Map.get(c, :inventory_limit, 200)
      response = read(c, state, cap)

      case response do
        {:ok, next} ->
          next = Map.put(next, "observed_at", DateTime.to_unix(now))
          commit(c, row, next, states, resources, now, fence)

        {:error, reason} ->
          # Record gaps and keep the last cursor on transient failures; expired/capped lists relist.
          next =
            if reason in [:expired, :inventory_cap, :malformed_or_inconsistent_list],
              do: Workloads.empty(resource, c.namespace, true) |> Map.put("scope", scope),
              else: Map.merge(state, %{"gap" => true, "coverage" => "partial", "changes" => []})

          next = Map.put(next, "error", Atom.to_string(reason))
          commit(c, row, next, states, resources, now, fence)
      end
    end
  end

  defp read(c, state, cap) do
    watch = state["phase"] == "watch" and is_binary(state["resource_version"])

    query =
      if watch,
        do: [
          {"watch", "true"},
          {"resourceVersion", state["resource_version"]},
          {"timeoutSeconds", 5},
          {"allowWatchBookmarks", "true"}
        ],
        else:
          [{"limit", c.page_size}] ++
            if(state["continuation"], do: [{"continue", state["continuation"]}], else: [])

    case Transport.get(c, Workloads.path(state["resource"], c.namespace), query) do
      {:ok, %{status: 410}} ->
        {:error, :expired}

      {:ok, %{status: 200, body: body}} when watch ->
        Workloads.watch(state, body, cap)

      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> Workloads.list_page(state, data, cap, c.max_pages)
          _ -> {:error, :malformed_list}
        end

      _ ->
        {:error, :workload_unavailable}
    end
  end

  defp commit(c, row, next, states, resources, now, _fence) do
    clean =
      states
      |> Enum.filter(fn {r, s} -> r in resources and s["scope"] == next["scope"] end)
      |> Map.new(fn {r, s} -> {r, Map.put(s, "changes", [])} end)

    summary =
      Workloads.summary(
        Map.put(clean, next["resource"], next),
        resources,
        DateTime.to_unix(now),
        c.interval_seconds * max(length(resources), 1) * 3
      )

    if length(summary["changes"]) > 100 or byte_size(Jason.encode!(summary)) > 60_000 do
      {:error, :workload_transition_budget_exceeded}
    else
      {:ok,
       Map.put(summary, "_pending_cursor", %{
         "state" => next,
         "expected_revision" => if(row, do: row["revision"], else: 0)
       })}
    end
  end

  # Called inside the SAME transaction as evidence/windows. A crash cannot advance a
  # watch position without its observations; retry repeats an uncommitted response safely.
  def persist(c, data, now, fence) do
    cursor = Map.fetch!(data, "_pending_cursor")
    next = cursor["state"]

    if fence do
      lease =
        Store.one(
          "SELECT fence,lease_until FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE",
          [c.id]
        )

      if lease == nil or lease["fence"] != fence or lease["lease_until"] == nil or
           DateTime.compare(lease["lease_until"], Store.now()) == :lt,
         do: Repo.rollback(:stale_lease)
    end

    if byte_size(Jason.encode!(next)) > 500_000, do: Repo.rollback(:inventory_byte_cap)
    revision = cursor["expected_revision"]

    saved =
      Repo.query!(
        """
        INSERT INTO kubernetes_cursors(company_id,source_id,resource,revision,updated_at,data)
        VALUES($1::text::uuid,$2::text::uuid,$3,1,$4,$5)
        ON CONFLICT(source_id,resource) DO UPDATE SET data=EXCLUDED.data,updated_at=EXCLUDED.updated_at,revision=kubernetes_cursors.revision+1
        WHERE kubernetes_cursors.revision=$6
        """,
        [c.company_id, c.id, next["resource"], now, next, revision]
      )

    if saved.num_rows != 1, do: Repo.rollback(:stale_cursor)
    Map.delete(data, "_pending_cursor")
  end
end
