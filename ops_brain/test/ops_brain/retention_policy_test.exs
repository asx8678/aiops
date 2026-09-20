defmodule OpsBrain.RetentionPolicyTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Retention, SourceConfig, Repo, Store, Evidence}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{c: c, now: now})
  end

  defp old_evidence(f) do
    old = DateTime.add(f.now, -9, :day)

    {:ok, _id} =
      SourceConfig.transaction(f.c.id, fn c ->
        Evidence.save(
          c,
          "retention-old:#{System.unique_integer([:positive])}",
          "pipeline_task",
          %{"tool" => "x", "issues" => ["ENOSPC"]},
          old,
          old
        )
      end)

    :ok
  end

  test "disabled source keeps a persisted policy and remains cleanable without HTTP", f do
    assert {:ok, _} = Retention.sweep(f.c.id, f.now, 100)

    {:ok, row} =
      SourceConfig.transaction(f.c.id, fn _ ->
        Store.one("SELECT retention_days FROM sources WHERE id=$1::text::uuid", [f.c.id])
      end)

    assert row["retention_days"] == 7

    old_evidence(f)

    Application.put_env(
      :ops_brain,
      :sources,
      Map.put(SourceConfig.all(), f.c.id, %{f.c | enabled: false})
    )

    Application.put_env(:ops_brain, :http_plug, fn _ ->
      flunk("retention must not perform HTTP")
    end)

    assert {:ok, %{evidence_expired: n}} = Retention.sweep(f.c.id, f.now, 100)
    assert n >= 1
  end

  test "removed source is resolved from the durable catalog and cleaned", f do
    assert {:ok, _} = Retention.sweep(f.c.id, f.now, 100)
    old_evidence(f)
    Application.put_env(:ops_brain, :sources, %{})

    assert {:ok, %{evidence_expired: n}} = Retention.sweep(f.c.id, f.now, 100)
    assert n >= 1
  end

  test "missing historical policy is explicit and deletes nothing", f do
    old_evidence(f)
    Application.put_env(:ops_brain, :sources, %{})

    assert {:ok, %{status: :policy_unknown}} = Retention.sweep(f.c.id, f.now, 100)
    refute f.c.id in Retention.targets()

    assert {:ok, %{"n" => 1}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one("SELECT count(*) AS n FROM evidence_items WHERE NOT(data ? 'expired')")
             end)
  end

  test "outstanding evidence work retains the conservative source guard", f do
    assert {:ok, _} = Retention.sweep(f.c.id, f.now, 100)
    old_evidence(f)

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Repo.query!(
          "INSERT INTO oban_jobs(state,queue,worker,args,inserted_at,scheduled_at,max_attempts,attempt,priority,tags,meta) VALUES('scheduled','evidence','OpsBrain.EvidenceWorker',$1,$2,$3,3,0,0,'{}','{}')",
          [
            %{"source_id" => c.id, "id" => Ecto.UUID.generate()},
            f.now,
            DateTime.add(f.now, 24, :hour)
          ]
        )
      end)

    assert {:ok, %{status: :deferred_live_work}} = Retention.sweep(f.c.id, f.now, 100)
  end

  test "disabled policy is synchronized, retired and scheduled without enabling collection", f do
    old_evidence(f)
    Application.put_env(:ops_brain, :sources, %{f.c.id => %{f.c | enabled: false}})
    assert :ok = Retention.sync_from_config(f.now)
    assert f.c.id in Retention.targets()
    assert {:error, :source_disabled_or_invalid} = SourceConfig.fetch(f.c.id)

    Application.put_env(:ops_brain, :sources, %{})
    assert :ok = Retention.sync_from_config(f.now)
    assert f.c.id in Retention.targets()

    assert {:ok, %{"retired_at" => retired, "retention_days" => 7}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one(
                 "SELECT retired_at, retention_days FROM sources WHERE id=$1::text::uuid",
                 [f.c.id]
               )
             end)

    assert retired != nil

    Application.put_env(:ops_brain, :maintenance_enabled, true)
    on_exit(fn -> Application.delete_env(:ops_brain, :maintenance_enabled) end)
    assert {:noreply, 0} = OpsBrain.Scheduler.handle_info({:maintenance, 0}, 0)

    assert Store.one(
             "SELECT count(*) AS n FROM oban_jobs WHERE worker='OpsBrain.MaintenanceWorker' AND args->>'source_id'=$1",
             [f.c.id]
           )["n"] == 1

    assert :ok = OpsBrain.MaintenanceWorker.perform(%Oban.Job{args: %{"source_id" => f.c.id}})

    assert {:ok, %{"n" => 0}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one("SELECT count(*) AS n FROM evidence_items WHERE NOT(data ? 'expired')")
             end)
  end

  test "wrong company cannot rewrite or sweep a source policy", f do
    assert :ok = Retention.sync_from_config(f.now)

    Application.put_env(:ops_brain, :sources, %{
      f.c.id => %{f.c | company_id: f.source_b.company_id, retention_days: 1}
    })

    assert :ok = Retention.sync_from_config(f.now)
    assert {:error, :source_scope_mismatch} = Retention.sweep(f.c.id, f.now)

    assert {:ok, %{"retention_days" => 7}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one("SELECT retention_days FROM sources WHERE id=$1::text::uuid", [f.c.id])
             end)
  end

  test "sweeping a retired source leaves another company's evidence untouched", f do
    b = config(f, :b)
    old_evidence(f)
    old_evidence(%{f | c: b})
    assert :ok = Retention.sync_from_config(f.now)
    Application.put_env(:ops_brain, :sources, %{})
    assert {:ok, %{evidence_expired: 1}} = Retention.sweep(f.c.id, f.now)

    assert {:ok, %{"n" => 1}} =
             Tenancy.with_scope(f.scope_b, fn ->
               Store.one("SELECT count(*) AS n FROM evidence_items WHERE NOT(data ? 'expired')")
             end)

    assert Repo.query!("SELECT current_setting('ops_brain.company_id',true)").rows in [
             [[nil]],
             [[""]]
           ]
  end
end
