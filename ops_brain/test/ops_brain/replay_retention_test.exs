defmodule OpsBrain.ReplayDetectorsTest do
  use ExUnit.Case, async: true
  alias OpsBrain.Replay.Detectors
  @now ~U[2026-01-01 01:00:00Z]

  defp evaluate(kind, data, policy \\ %{}, extra \\ %{}) do
    row =
      Map.merge(
        %{
          "kind" => kind,
          "data" => data,
          "policy" => policy,
          "detector_version" => 1,
          "company_id" => "company",
          "source_id" => "source",
          "service_id" => "service"
        },
        extra
      )

    Detectors.evaluate(row, @now, @now, @now)
  end

  test "metric thresholds and log totals use retained policy, not stored condition" do
    assert %{status: :ok, result: %{condition: "warning"}} =
             evaluate(
               "prometheus",
               %{
                 "samples" => [%{"value" => 12, "timestamp" => DateTime.to_unix(@now)}],
                 "condition" => "normal"
               },
               %{"threshold" => 10}
             )

    assert %{status: :missing_inputs} = evaluate("prometheus", %{"samples" => []})

    assert %{status: :ok, result: %{condition: "watch", signatures: [%{sample_count: 2}]}} =
             evaluate("loki", %{
               "count" => 10,
               "samples" => [%{"message" => "ENOSPC"}, %{"message" => "ENOSPC"}]
             })
  end

  test "ratio replay recomputes from aligned backend totals, never trusts stored ratios" do
    p = %{"semantics" => "ratio", "minimum_traffic" => 10, "threshold" => 0.1}

    d = %{
      "numerators" => [%{"series" => "a", "value" => 2, "timestamp" => 100}],
      "denominators" => [%{"series" => "a", "value" => 10, "timestamp" => 100}],
      "samples" => [%{"value" => 0}],
      "condition" => "normal"
    }

    assert %{status: :ok, result: %{condition: "warning", ratio: 0.2}} =
             evaluate("prometheus", d, p)

    assert %{status: :ok, result: %{condition: "unknown", coverage: "partial"}} =
             evaluate("prometheus", d, %{p | "minimum_traffic" => 100})

    assert %{status: :ok, result: %{condition: "unknown"}} =
             evaluate(
               "prometheus",
               %{
                 d
                 | "denominators" => [%{"series" => "other", "value" => 10, "timestamp" => 100}]
               },
               p
             )

    assert %{status: :missing_inputs} = evaluate("prometheus", Map.delete(d, "numerators"), p)
  end

  test "future embedded metric samples do not enter a historical replay" do
    future = DateTime.to_unix(@now) + 5

    assert %{status: :missing_inputs} =
             evaluate("prometheus", %{"samples" => [%{"value" => 12, "timestamp" => future}]}, %{
               "threshold" => 10
             })

    assert %{status: :missing_inputs} =
             evaluate(
               "prometheus",
               %{
                 "numerators" => [%{"series" => "a", "value" => 1, "timestamp" => future}],
                 "denominators" => [%{"series" => "a", "value" => 10, "timestamp" => future}]
               },
               %{"semantics" => "ratio", "minimum_traffic" => 1, "threshold" => 0.1}
             )
  end

  test "workload summary replay supports OOM, Warning events, and generation changes" do
    assert %{status: :ok, result: %{condition: "critical"}} =
             evaluate("kubernetes", %{"changes" => [%{"oom" => true, "restart_delta" => 1}]})

    assert %{status: :ok, result: %{condition: "warning"}} =
             evaluate("kubernetes", %{
               "changes" => [%{"kind" => "Event", "type" => "Warning", "count_delta" => 2}]
             })

    assert %{status: :ok, result: %{condition: "unknown"}} =
             evaluate("kubernetes", %{"changes" => [%{"kind" => "Deployment", "generation" => 2}]})

    assert %{status: :missing_inputs} = evaluate("kubernetes", %{"condition" => "normal"})
  end

  test "workload replay uses retained deltas and never labels inventory as deployment" do
    assert %{status: :ok, result: %{condition: "unknown"}} =
             evaluate("kubernetes", %{"initial_snapshot" => true, "changes" => []})

    assert %{status: :ok, result: %{condition: "warning"}} =
             evaluate("kubernetes", %{
               "initial_snapshot" => false,
               "changes" => [%{"restart_delta" => 2}]
             })
  end

  test "pipeline fallback matches production snippet and explicit absence statuses" do
    assert %{status: :ok, result: %{classification: "disk_space"}} =
             evaluate("pipeline_task", %{"issues" => [], "tool" => "task", "snippet" => "ENOSPC"})

    assert %{status: :unsupported_version} =
             evaluate("pipeline_task", %{}, %{}, %{"detector_version" => 99})

    assert %{status: :expired} = evaluate("pipeline_task", %{"expired" => true})
    assert %{status: :expired} = evaluate("pipeline_task", %{}, %{}, %{"expires_at" => @now})
    assert %{status: :missing_inputs} = evaluate("correlation", %{"result" => %{"version" => 1}})
    assert %{status: :unsupported_kind} = evaluate("unknown", %{})
  end

  test "capacity uses normalized string inputs and independently filters event and receipt times" do
    now = DateTime.to_unix(@now)

    policy = %{
      "unit" => "bytes",
      "limits_verified" => true,
      "freshness_seconds" => 120,
      "max_gap_seconds" => 120,
      "min_history_seconds" => 240,
      "effective_threshold" => 1000,
      "warning_horizon_seconds" => 1000,
      "min_growth_bytes_per_second" => 0
    }

    samples =
      for n <- 0..4,
          do: %{
            "time" => now - 240 + n * 60,
            "received_at" => now - 240 + n * 60,
            "value" => 100 + n * 60,
            "unit" => "bytes",
            "series" => "a",
            "segment" => "s"
          }

    data = %{
      "version" => 1,
      "input_samples" => samples,
      "policy" => policy,
      "as_of" => DateTime.to_iso8601(@now)
    }

    assert %{status: :ok, result: %{condition: "warning"}} = evaluate("capacity_evaluation", data)
    delayed = List.update_at(samples, 4, &Map.put(&1, "received_at", now + 1))

    assert %{status: :ok, result: %{condition: "unknown", reason: "insufficient history"}} =
             evaluate("capacity_evaluation", %{data | "input_samples" => delayed})

    future = List.update_at(samples, 4, &Map.put(&1, "time", now + 1))

    assert %{status: :ok, result: %{condition: "unknown"}} =
             evaluate("capacity_evaluation", %{data | "input_samples" => future})

    assert %{status: :missing_inputs} =
             evaluate("capacity_evaluation", Map.delete(data, "input_samples"))
  end

  test "correlation excludes future changes and keeps alternatives" do
    now = DateTime.to_unix(@now)

    symptom = %{
      company_id: "c",
      environment_id: "e",
      target_id: "t",
      evidence_id: "s",
      occurred_at: now - 10,
      received_at: now
    }

    change = %{symptom | evidence_id: "a", occurred_at: now - 20}
    future = %{change | evidence_id: "b", occurred_at: now + 1}
    delayed = %{change | evidence_id: "c", received_at: now + 1}

    assert %{status: :ok, result: %{candidates: [%{change_evidence_id: "a"}]}} =
             Detectors.correlate(symptom, [future, delayed, change], [], @now, @now)
  end

  test "bounds and maintenance job arguments reject before touching storage" do
    assert {:error, :invalid_options} =
             OpsBrain.Replay.page(nil, occurred_before: @now, limit: 101)

    assert {:error, :invalid_retention_arguments} = OpsBrain.Retention.sweep("id", @now, 501)

    assert :discard =
             OpsBrain.MaintenanceWorker.perform(%Oban.Job{
               args: %{"source_id" => "x", "company_id" => "injected"}
             })
  end
end

defmodule OpsBrain.ReplayRetentionTest do
  use OpsBrain.DataCase, async: false
  @moduletag :database
  import OpsBrain.SourceFixtures
  alias OpsBrain.{Evidence, Replay, Retention, SourceConfig, Store}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{c: config(f), now: now})
  end

  defp revision(f, window, revision, received, value) do
    {:ok, id} =
      SourceConfig.transaction(f.c.id, fn c ->
        finish = DateTime.add(f.now, -60)
        start = DateTime.add(finish, -60)

        data = %{
          "samples" => [%{"value" => value, "timestamp" => DateTime.to_unix(finish)}],
          "coverage" => "complete"
        }

        Repo.query!(
          """
          INSERT INTO observation_windows(id,company_id,source_id,profile,kind,window_start,window_end,received_at,data)
          VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,'test:v1','prometheus',$4,$5,$6,$7)
          ON CONFLICT DO NOTHING
          """,
          [window, c.company_id, c.id, start, finish, received, data]
        )

        id = Ecto.UUID.generate()

        Repo.query!(
          """
          INSERT INTO observation_revisions(id,company_id,source_id,window_id,profile,kind,window_start,window_end,received_at,revision,data,policy,detector_version)
          VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,'test:v1','prometheus',$5,$6,$7,$8,$9,$10,1)
          """,
          [
            id,
            c.company_id,
            c.id,
            window,
            start,
            finish,
            received,
            revision,
            data,
            %{"threshold" => 10}
          ]
        )

        id
      end)

    id
  end

  test "retention cannot remove the expiry marker of a protected revision", f do
    old = DateTime.add(f.now, -30, :day)
    window = Ecto.UUID.generate()
    revision(%{f | now: DateTime.add(old, 60)}, window, 1, old, 15)

    SourceConfig.transaction(f.c.id, fn c ->
      id = Evidence.save(c, "window:#{window}:1", "prometheus", %{"samples" => []}, old, old)

      Repo.query!(
        "UPDATE evidence_items SET data='{\"expired\":true}'::jsonb WHERE id=$1::text::uuid",
        [id]
      )

      Repo.query!(
        "INSERT INTO collection_states(company_id,source_id,window_start,window_end) VALUES($1::text::uuid,$2::text::uuid,$3,$4)",
        [c.company_id, c.id, DateTime.add(old, -60), old]
      )
    end)

    assert {:ok, %{status: :expired}} = Replay.one(f.scope_a, window, occurred_before: f.now)

    assert {:ok, %{revisions_deleted: 0, tombstones_deleted: 0}} =
             Retention.sweep(f.c.id, f.now, 1)

    assert {:ok, %{status: :expired}} = Replay.one(f.scope_a, window, occurred_before: f.now)
  end

  test "latest revision known at receipt cutoff wins without using mutable current input", f do
    window = Ecto.UUID.generate()
    revision(f, window, 1, DateTime.add(f.now, -30), 5)
    revision(f, window, 2, f.now, 15)

    assert {:ok, %{revision: 1, result: %{condition: "normal"}}} =
             Replay.one(f.scope_a, window,
               occurred_before: f.now,
               received_before: DateTime.add(f.now, -1)
             )

    assert {:ok, %{revision: 2, result: %{condition: "warning"}}} =
             Replay.one(f.scope_a, window, occurred_before: f.now)

    assert {:ok, %{status: :missing_or_not_known}} =
             Replay.one(f.scope_b, window, occurred_before: f.now)

    assert {:ok, %{status: :missing_or_not_known}} =
             Replay.one(f.scope_a, window, occurred_before: DateTime.add(f.now, -61))
  end

  test "evidence pagination is deterministic, bound to cutoffs, and performs no mutations", f do
    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        for n <- 1..3,
            do:
              Evidence.save(
                c,
                "task:#{n}",
                "pipeline_task",
                %{"tool" => "task", "issues" => [], "snippet" => "ENOSPC"},
                f.now,
                f.now
              )
      end)

    Application.put_env(:ops_brain, :http_plug, fn _ -> flunk("replay network call") end)
    Application.put_env(:ops_brain, :notification_plug, fn _ -> flunk("replay delivery") end)
    before = counts(f.scope_a)
    opts = [stream: :evidence, occurred_before: f.now, limit: 2]

    assert {:ok, %{items: first, continuation: cursor, complete: false}} =
             Replay.page(f.scope_a, opts)

    assert length(first) == 2

    assert {:ok, %{items: [last], continuation: nil, complete: true}} =
             Replay.page(f.scope_a, opts ++ [continuation: cursor])

    refute last.id in Enum.map(first, & &1.id)

    assert {:error, :invalid_continuation} =
             Replay.page(f.scope_b, opts ++ [continuation: cursor])

    assert {:error, :invalid_continuation} =
             Replay.page(
               f.scope_a,
               Keyword.put(opts, :received_before, DateTime.add(f.now, 1)) ++
                 [continuation: cursor]
             )

    assert counts(f.scope_a) == before
  end

  test "retention is bounded and protects open issue evidence", f do
    old = DateTime.add(f.now, -9, :day)

    {:ok, ids} =
      SourceConfig.transaction(f.c.id, fn c ->
        for n <- 1..3,
            do:
              Evidence.save(
                c,
                "old:#{n}",
                "pipeline_task",
                %{"tool" => "x", "issues" => ["ENOSPC"]},
                old,
                old
              )
      end)

    [protected | _] = ids
    group = Ecto.UUID.generate()

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Repo.query!(
          "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,'fp',1,'{}')",
          [c.company_id, c.id]
        )

        Repo.query!(
          "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,status,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,'fp',1,$4,$4,'warning','active','{}')",
          [group, c.company_id, c.id, old]
        )

        Repo.query!(
          "INSERT INTO failure_occurrences(id,company_id,source_id,occurrence_key,group_id,evidence_id,occurred_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,'protected',$4::text::uuid,$5::text::uuid,$6)",
          [Ecto.UUID.generate(), c.company_id, c.id, group, protected, old]
        )
      end)

    assert {:ok, %{evidence_expired: 1, more?: true}} = Retention.sweep(f.c.id, f.now, 1)

    assert {:ok, %{"data" => %{"issues" => ["ENOSPC"]}}} =
             Tenancy.with_scope(f.scope_a, fn ->
               Store.one("SELECT data FROM evidence_items WHERE id=$1::text::uuid", [protected])
             end)

    assert {:ok, %{evidence_expired: 1}} = Retention.sweep(f.c.id, f.now, 1)
    assert {:ok, %{evidence_expired: 0, groups_deleted: 0}} = Retention.sweep(f.c.id, f.now, 1)

    outbox = Ecto.UUID.generate()

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Repo.query!(
          "UPDATE issue_groups SET status='closed_by_reviewer' WHERE id=$1::text::uuid",
          [group]
        )

        Repo.query!(
          "INSERT INTO notification_outbox(id,company_id,source_id,group_id,revision,destination,status,next_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,1,'synthetic','pending',$5,$5)",
          [outbox, c.company_id, c.id, group, old]
        )
      end)

    assert {:ok, %{evidence_expired: 0, groups_deleted: 0, outbox_deleted: 0}} =
             Retention.sweep(f.c.id, f.now, 1)

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn _ ->
        Repo.query!("UPDATE notification_outbox SET status='delivered' WHERE id=$1::text::uuid", [
          outbox
        ])
      end)

    assert {:ok,
            %{
              evidence_expired: 1,
              groups_deleted: 1,
              outbox_deleted: 1,
              occurrences_deleted: 1,
              fingerprints_deleted: 1
            }} = Retention.sweep(f.c.id, f.now, 1)
  end

  test "unexpired capacity inputs protect revisions and windows until dependency expiry", f do
    old = DateTime.add(f.now, -9, :day)
    window = Ecto.UUID.generate()
    revision(%{f | now: old}, window, 1, old, 5)

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Evidence.save(
          c,
          "capacity-dependency",
          "capacity_evaluation",
          %{"input_window_ids" => [window]},
          old,
          f.now
        )
      end)

    assert {:ok, %{revisions_deleted: 0, windows_deleted: 0}} = Retention.sweep(f.c.id, f.now, 1)

    assert {:ok, %{revisions_deleted: 1, windows_deleted: 1}} =
             Retention.sweep(f.c.id, DateTime.add(f.now, 8, :day), 1)

    assert {:ok, %{status: :missing_or_not_known}} =
             Replay.one(f.scope_a, window, occurred_before: f.now)
  end

  defp counts(scope) do
    {:ok, counts} =
      Tenancy.with_scope(scope, fn ->
        for table <-
              ~w(evidence_items observation_revisions failure_occurrences issue_groups notification_outbox oban_jobs),
            into: %{},
            do: {table, Store.one("SELECT count(*) AS n FROM #{table}")["n"]}
      end)

    counts
  end
end
