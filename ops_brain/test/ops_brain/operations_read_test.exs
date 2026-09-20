defmodule OpsBrain.OperationsReadTest do
  use OpsBrain.DataCase, async: false
  alias OpsBrain.{Evidence, Issues, SourceConfig, Store}

  setup do
    f = fixture()
    c = OpsBrain.SourceFixtures.config(f)
    on_exit(&OpsBrain.SourceFixtures.cleanup/0)

    {:ok, _} =
      SourceConfig.transaction(c.id, fn trusted ->
        for {key, run, attempt} <- [{"one", 1, 1}, {"two", 1, 2}, {"three", 2, 1}] do
          Evidence.failure(
            trusted,
            key,
            %{"issues" => ["HTTP 401 api.invalid"], "tool" => "compiler", "attempt" => attempt},
            run,
            Store.now()
          )
        end
      end)

    {:ok, [group]} = Issues.list(f.scope_a)
    Map.merge(f, %{group: group})
  end

  defp capture(_event, _measurements, metadata, parent) do
    if String.contains?(metadata.query, "WITH page AS MATERIALIZED"),
      do: send(parent, {:page_query, metadata.query})
  end

  defp nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &nodes/1)]

  test "stable 100-group page counts exact occurrences only for selected groups; EXPLAIN uses bounded aggregate loops",
       f do
    {:ok, _} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!(
          """
          INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data)
          SELECT gen_random_uuid(),company_id,source_id,fingerprint,parser_version,first_seen,last_seen - interval '1 second',severity,data
          FROM issue_groups CROSS JOIN generate_series(1,150) WHERE id=$1::text::uuid
          """,
          [f.group["id"]]
        )
      end)

    handler = "operations-page-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:ops_brain, :repo, :query], &capture/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, groups} = Issues.list(f.scope_a)
    assert length(groups) == 100
    assert hd(groups)["id"] == f.group["id"]
    assert hd(groups)["occurrences"] == 3
    assert hd(groups)["distinct_runs"] == 2
    assert hd(groups)["distinct_attempts"] == 3
    assert Enum.all?(tl(groups), &(&1["occurrences"] == 0))
    assert {:ok, ^groups} = Issues.list(f.scope_a)
    assert {:ok, []} = Issues.list(f.scope_b)
    assert_receive {:page_query, sql}

    {:ok, result} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql)
      end)

    [[[%{"Plan" => plan} = report]]] = result.rows
    plan_nodes = nodes(plan)
    assert Enum.any?(plan_nodes, &(&1["Node Type"] == "Limit" and &1["Actual Rows"] == 100))
    aggregates = Enum.filter(plan_nodes, &(&1["Node Type"] == "Aggregate"))
    assert length(aggregates) == 1
    assert hd(aggregates)["Actual Loops"] == 100
    # Optional diagnostic artifact, useful for independent plan review.
    if path = System.get_env("OPS_BRAIN_READ_PLAN_ARTIFACT"),
      do: File.write!(path, Jason.encode!(report, pretty: true))

    {:ok, indexes} =
      Tenancy.with_scope(f.scope_a, fn ->
        Store.rows(
          "SELECT indexname FROM pg_indexes WHERE tablename IN ('issue_groups','failure_occurrences','pipeline_runs','notification_outbox','evidence_items')"
        )
      end)

    names = Enum.map(indexes, & &1["indexname"])

    for name <- [
          "issue_groups_company_id_last_seen_id_index",
          "failure_occurrences_company_id_group_id_run_id_attempt_index",
          "deployment_run_read_index"
        ],
        do: assert(name in names)
  end
end
