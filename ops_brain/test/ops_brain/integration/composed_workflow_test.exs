defmodule OpsBrain.Integration.ComposedWorkflowTest do
  use OpsBrain.DataCase, async: false
  @moduletag :integration
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Evidence, Issues, Store, Fingerprints}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{c: c, now: now})
  end

  test "concurrent improving retries keep one occurrence with a current revision", f do
    repo = start_supervised!({OpsBrain.Repo, name: nil, pool_size: 4})

    work = fn n ->
      OpsBrain.Repo.put_dynamic_repo(repo)

      SourceConfig.transaction(f.c.id, fn trusted ->
        Evidence.failure(
          trusted,
          "run:500:task:1",
          %{
            "issues" => ["HTTP 401"],
            "tool" => "t",
            "attempt" => 1,
            "occurred_at" => Store.iso(f.now),
            "snippet" => "attempt #{n}"
          },
          500,
          DateTime.add(f.now, n, :second)
        )
      end)
    end

    results =
      1..4
      |> Task.async_stream(work, max_concurrency: 4, timeout: 30_000)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    {:ok, [group]} = Issues.list(f.scope_a)
    assert group["occurrences"] == 1

    {:ok, revisions} = Issues.revisions(f.scope_a, group["id"], f.now)
    assert Enum.count(revisions, &(&1["current"] == true)) == 1
    assert length(revisions) >= 2
  end

  test "real queue collects and persists a synthetic provider response", f do
    name = __MODULE__.Queue
    parent = self()

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      send(parent, :provider_read)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{value: []}))
    end)

    start_supervised!(
      {Oban,
       name: name,
       repo: OpsBrain.Repo,
       queues: [collect: 1],
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       plugins: []}
    )

    {:ok, job} = Oban.insert(name, OpsBrain.CollectionWorker.new(%{source_id: f.c.id}))
    assert_receive :provider_read, 5000
    assert await_completed(job.id, 100)

    assert {:ok, %{"requests" => 1, "lease_until" => nil}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one("SELECT requests,lease_until FROM collection_states")
             end)
  end

  defp await_completed(_id, 0), do: false

  defp await_completed(id, remaining) do
    case OpsBrain.Repo.query!("SELECT state FROM oban_jobs WHERE id=$1", [id]).rows do
      [["completed"]] ->
        true

      _ ->
        Process.sleep(20)
        await_completed(id, remaining - 1)
    end
  end

  test "company separation survives a composed write path", f do
    assert {:ok, group} =
             SourceConfig.transaction(f.c.id, fn trusted ->
               evidence =
                 Evidence.save(
                   trusted,
                   "integration:1",
                   "pipeline_task",
                   %{"issues" => ["HTTP 401"], "tool" => "t", "occurred_at" => Store.iso(f.now)},
                   f.now,
                   f.now
                 )

               Issues.record(
                 trusted,
                 "integration:1",
                 evidence,
                 Fingerprints.identify(f.a.id, {f.c.id, "CI-only"}, "t", "HTTP 401"),
                 %{occurred_at: f.now, attempt: 1},
                 f.now
               )
             end)

    assert {:ok, [_]} = Issues.list(f.scope_a)
    assert {:ok, []} = Issues.list(f.scope_b)
    assert {:ok, nil} = Issues.review(f.scope_b, group, "locally_acknowledged")
  end
end
