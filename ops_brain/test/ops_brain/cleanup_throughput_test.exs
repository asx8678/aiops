defmodule OpsBrain.CleanupThroughputTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{DirectoryMaintenanceWorker, Retention, SourceConfig, Repo, Evidence}

  setup do
    f = fixture()
    previous = Application.fetch_env(:ops_brain, :maintenance_enabled)

    on_exit(fn ->
      cleanup()

      case previous do
        {:ok, value} -> Application.put_env(:ops_brain, :maintenance_enabled, value)
        :error -> Application.delete_env(:ops_brain, :maintenance_enabled)
      end
    end)

    c = config(f)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{c: c, now: now})
  end

  defp insert_terminal_jobs(n, older_than) do
    Repo.query!(
      """
      INSERT INTO oban_jobs(state,queue,worker,args,inserted_at,completed_at,max_attempts,attempt,priority,tags,meta)
      SELECT 'completed','collect','Synthetic.Worker',('{"n":'||g||'}')::jsonb, $1, $1, 1, 1, 0, '{}', '{}'
      FROM generate_series(1,$2) g
      """,
      [older_than, n]
    )
  end

  defp old_evidence(f) do
    old = DateTime.add(f.now, -9, :day)

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Evidence.save(
          c,
          "cleanup-old:#{System.unique_integer([:positive])}",
          "pipeline_task",
          %{"tool" => "x", "issues" => ["ENOSPC"]},
          old,
          old
        )
      end)

    :ok
  end

  test "terminal work drains in bounded batches within one maintenance run", f do
    Application.put_env(:ops_brain, :maintenance_enabled, true)
    insert_terminal_jobs(130, DateTime.add(f.now, -40, :day))

    assert :ok = DirectoryMaintenanceWorker.perform(%Oban.Job{args: %{}})

    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM oban_jobs WHERE state='completed'")
    assert n == 0
  end

  test "full budget yields and continuation drains backlog", f do
    Application.put_env(:ops_brain, :maintenance_enabled, true)
    insert_terminal_jobs(650, DateTime.add(f.now, -40, :day))
    assert {:snooze, 5} = DirectoryMaintenanceWorker.perform(%Oban.Job{args: %{}})

    assert %{rows: [[150]]} =
             Repo.query!("SELECT count(*) FROM oban_jobs WHERE state='completed'")

    assert :ok = DirectoryMaintenanceWorker.perform(%Oban.Job{args: %{}})
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM oban_jobs WHERE state='completed'")
  end

  test "a future nonterminal job no longer suspends unrelated expired cleanup", f do
    assert {:ok, _} = Retention.sweep(f.c.id, f.now, 100)
    old_evidence(f)

    {:ok, _} =
      SourceConfig.transaction(f.c.id, fn c ->
        Repo.query!(
          "INSERT INTO oban_jobs(state,queue,worker,args,inserted_at,scheduled_at,max_attempts,attempt,priority,tags,meta) VALUES('scheduled','delivery','OpsBrain.NotificationWorker',$1,$2,$3,3,0,0,'{}','{}')",
          [
            %{"source_id" => c.id, "id" => Ecto.UUID.generate()},
            f.now,
            DateTime.add(f.now, 24, :hour)
          ]
        )
      end)

    assert {:ok, %{evidence_expired: n}} = Retention.sweep(f.c.id, f.now, 100)
    assert n >= 1
  end
end
