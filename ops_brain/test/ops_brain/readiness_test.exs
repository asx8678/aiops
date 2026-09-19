defmodule OpsBrain.ReadinessTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Store, Repo, Evidence, Issues, Retention}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    Map.merge(f, %{c: config(f), now: DateTime.utc_now()})
  end

  test "all operational tables force tenant RLS with runtime identity and reset after worker rollback",
       f do
    assert :ok = OpsBrain.DatabaseSafety.verify!()

    for table <-
          ~w(collection_states pipeline_runs run_snapshots evidence_items error_fingerprints issue_groups failure_occurrences service_instances observation_windows source_budgets notification_outbox) do
      assert Repo.query!("SELECT * FROM #{table}").rows == []

      assert_raise Postgrex.Error, fn ->
        Repo.query!("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
      end
    end

    assert {:error, :probe} = SourceConfig.transaction(f.c.id, fn _ -> Repo.rollback(:probe) end)
    assert {:ok, %{company: _}} = Tenancy.overview(f.scope_b)

    assert Repo.query!("SELECT current_setting('ops_brain.company_id',true)").rows in [
             [[nil]],
             [[""]]
           ]
  end

  test "source policy denies mutation subresources and arbitrary query scopes", f do
    for path <- [
          "/api/v1/admin/tsdb/delete_series",
          "/api/v1/namespaces/prod/pods/x/exec",
          "/evil",
          "/#{f.c.organization}/#{f.c.project_id}/_apis/build/builds/1/cancel"
        ] do
      refute OpsBrain.OperationPolicy.allowed?(f.c, path)
    end

    assert {:error, _} = SourceConfig.validate(%{f.c | approved_ips: ["not-an-IP"]})
    assert {:error, _} = SourceConfig.validate(%{f.c | network_reviewed: false})

    for sample <- [
          ~s({"token":"FAKE_JSON_CANARY"}),
          "-----BEGIN PRIVATE KEY-----\nFAKE_KEY_CANARY\n-----END PRIVATE KEY-----",
          "Authorization: Bearer FAKE_BEARER_CANARY"
        ] do
      refute OpsBrain.Redactor.clean(sample) =~ "FAKE_"
    end
  end

  test "retention is bounded scoped and preserves expired evidence identity", f do
    past = DateTime.add(f.now, -8, :day)

    assert {:ok, id} =
             SourceConfig.transaction(f.c.id, fn c ->
               Evidence.save(c, "old", "missing", %{"reason" => "synthetic"}, past, past)
             end)

    assert {:ok, %{evidence_expired: 1}} = Retention.sweep(f.c.id, f.now)

    assert {:ok, %{"data" => %{"expired" => true}}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one("SELECT data FROM evidence_items WHERE id=$1::text::uuid", [id])
             end)

    assert {:ok, nil} =
             Tenancy.with_scope(f.scope_b, fn ->
               Store.one("SELECT data FROM evidence_items WHERE id=$1::text::uuid", [id])
             end)
  end

  @tag :local_load
  test "measured bounded synthetic burst creates one episode not one notice per occurrence", f do
    timings =
      for n <- 1..200 do
        {us, {:ok, _}} =
          :timer.tc(fn ->
            SourceConfig.transaction(f.c.id, fn c ->
              Evidence.failure(
                c,
                "synthetic-load:#{n}",
                %{
                  "issues" => ["HTTP 401 dependency.example.test"],
                  "tool" => "synthetic",
                  "attempt" => 1
                },
                n,
                f.now
              )
            end)
          end)

        us
      end

    assert {:ok, [g]} = Issues.list(f.scope_a)
    assert g["occurrences"] == 200 and g["distinct_runs"] == 200
    sorted = Enum.sort(timings)

    IO.puts(
      "SYNTHETIC_LOAD " <>
        Jason.encode!(%{
          operations: 200,
          pool_size: 1,
          concurrency: 1,
          p50_ms: Enum.at(sorted, 99) / 1000,
          p95_ms: Enum.at(sorted, 189) / 1000,
          p99_ms: Enum.at(sorted, 197) / 1000,
          total_ms: Enum.sum(timings) / 1000,
          method:
            "nearest-rank sorted per-transaction elapsed microseconds; local synthetic evidence inserts, not source throughput"
        })
    )
  end
end
