defmodule OpsBrain.EvidenceRevisionTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Evidence, Issues, Store, Fingerprints}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f)
    Map.merge(f, %{c: c, now: DateTime.utc_now()})
  end

  defp fail_run(f, extra) do
    SourceConfig.transaction(f.c.id, fn trusted ->
      Evidence.failure(
        trusted,
        "run:101:rec:1",
        Map.merge(
          %{
            "issues" => ["HTTP 401"],
            "tool" => "tool",
            "attempt" => 1,
            "occurred_at" => Store.iso(f.now)
          },
          extra
        ),
        101,
        f.now
      )
    end)
  end

  defp occurrence(f) do
    {:ok, row} =
      SourceConfig.transaction(f.c.id, fn _ ->
        Store.one(
          "SELECT id::text,group_id::text,evidence_id::text,evidence_revision,(SELECT count(*)::integer FROM failure_occurrences WHERE occurrence_key='run:101:rec:1') AS occurrences FROM failure_occurrences WHERE occurrence_key='run:101:rec:1'"
        )
      end)

    row
  end

  defp link_count(f, occurrence_id) do
    {:ok, n} =
      SourceConfig.transaction(f.c.id, fn _ ->
        Store.one(
          "SELECT count(*)::integer AS n FROM occurrence_evidence WHERE occurrence_id=$1::text::uuid",
          [occurrence_id]
        )
      end)

    n["n"]
  end

  test "a previously unseen stale revision is retained once without replacing current evidence",
       f do
    assert {:ok, _} = fail_run(f, %{})
    initial = occurrence(f)
    older = %{f | now: DateTime.add(f.now, -10)}
    assert {:ok, _} = fail_run(older, %{"snippet" => "late arrival"})
    assert {:ok, _} = fail_run(older, %{"snippet" => "late arrival"})
    latest = occurrence(f)
    assert latest["evidence_id"] == initial["evidence_id"]
    assert latest["evidence_revision"] == 2
    {:ok, [stale, current]} = Issues.revisions(f.scope_a, initial["group_id"], f.now)
    assert stale["reason"] == "stale_ignored"
    refute stale["current"]
    assert current["current"]
  end

  test "same-company evidence from a different source cannot be linked", f do
    assert {:ok, _} = fail_run(f, %{})
    first = occurrence(f)
    {:ok, other} = Tenancy.create_source(f.scope_a, %{name: "other", kind: :azure_build})
    other_config = config(%{f | source_a: other})

    {:ok, evidence} =
      SourceConfig.transaction(other_config.id, fn c ->
        Evidence.save(c, "foreign", "pipeline_task", %{}, f.now, f.now)
      end)

    assert_raise Postgrex.Error, fn ->
      SourceConfig.transaction(f.c.id, fn c ->
        fp = Fingerprints.identify(c.company_id, {c.id, "CI-only"}, "other", "HTTP 403")
        Issues.record(c, "run:101:rec:1", evidence, fp, %{occurred_at: f.now}, f.now)
      end)
    end

    assert occurrence(f) == first
  end

  test "old evidence replay is idempotent and history is tenant scoped and expires", f do
    assert {:ok, _} = fail_run(f, %{})
    first = occurrence(f)
    assert {:ok, _} = fail_run(%{f | now: DateTime.add(f.now, 1)}, %{"snippet" => "better"})
    latest = occurrence(f)
    assert {:ok, _} = fail_run(f, %{})
    assert occurrence(f) == latest
    assert link_count(f, first["id"]) == 2
    assert {:ok, []} = Issues.revisions(f.scope_b, first["group_id"], f.now)
    {:ok, history} = Issues.revisions(f.scope_a, first["group_id"], DateTime.add(f.now, 9, :day))
    assert length(history) == 2
    assert Enum.all?(history, &(&1["data"] == %{"status" => "expired"}))

    assert_raise Postgrex.Error, fn ->
      SourceConfig.transaction(f.c.id, fn _ ->
        Repo.query!("UPDATE occurrence_evidence SET reason='tampered'")
      end)
    end
  end

  test "same stored evidence can be reclassified without losing reviewer state or old provenance",
       f do
    assert {:ok, _} = fail_run(f, %{})
    first = occurrence(f)
    assert {:ok, _} = Issues.assign(f.scope_a, first["group_id"], "reviewer")
    assert {:ok, _} = Issues.review(f.scope_a, first["group_id"], "closed_by_reviewer")

    {:ok, new_group} =
      SourceConfig.transaction(f.c.id, fn c ->
        fp = Fingerprints.identify(c.company_id, {c.id, "CI-only"}, "other", "HTTP 403")
        Issues.record(c, "run:101:rec:1", first["evidence_id"], fp, %{occurred_at: f.now}, f.now)
      end)

    refute new_group == first["group_id"]
    assert occurrence(f)["occurrences"] == 1
    {:ok, [old]} = Issues.revisions(f.scope_a, first["group_id"], f.now)
    refute old["current"]
    {:ok, groups} = Issues.list(f.scope_a)
    old_group = Enum.find(groups, &(&1["id"] == first["group_id"]))
    assert old_group["owner"] == "reviewer"
    assert old_group["status"] == "closed_by_reviewer"
    assert old_group["occurrences"] == 0
  end

  test "concurrent initial evidence uses one occurrence and ordered immutable revisions", f do
    repo = start_supervised!({OpsBrain.Repo, name: nil, pool_size: 2})
    parent = self()

    tasks =
      for i <- 1..2 do
        Task.async(fn ->
          OpsBrain.Repo.put_dynamic_repo(repo)

          SourceConfig.transaction(f.c.id, fn c ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:ready, self(), pid})

            receive do
              :go -> :ok
            after
              5000 -> raise "barrier timeout"
            end

            Evidence.failure(
              c,
              "run:101:rec:1",
              %{
                "issues" => ["HTTP 401"],
                "tool" => "tool",
                "attempt" => 1,
                "snippet" => "revision #{i}",
                "occurred_at" => Store.iso(f.now)
              },
              101,
              DateTime.add(f.now, i)
            )
          end)
        end)
      end

    assert_receive {:ready, a, pid_a}, 5000
    assert_receive {:ready, b, pid_b}, 5000
    refute pid_a == pid_b
    send(a, :go)
    send(b, :go)
    for task <- tasks, do: assert({:ok, _} = Task.await(task, 10_000))
    row = occurrence(f)
    assert row["occurrences"] == 1
    assert row["evidence_revision"] == 2
    assert link_count(f, row["id"]) == 2
    {:ok, history} = Issues.revisions(f.scope_a, row["group_id"], DateTime.add(f.now, 3))
    current = Enum.find(history, & &1["current"])
    assert current["data"]["snippet"] == "revision 2"
  end

  test "improved evidence becomes a revision on the same occurrence", f do
    assert {:ok, _} = fail_run(f, %{})
    first = occurrence(f)
    assert first["evidence_revision"] == 1
    assert first["occurrences"] == 1

    assert {:ok, _} = fail_run(f, %{"snippet" => "CANARY better log"})
    second = occurrence(f)
    assert second["evidence_revision"] == 2
    refute second["evidence_id"] == first["evidence_id"]
    assert second["group_id"] == first["group_id"]
    assert second["occurrences"] == 1
    assert link_count(f, first["id"]) == 2

    assert {:ok, _} = fail_run(f, %{"snippet" => "CANARY better log"})
    assert occurrence(f)["evidence_revision"] == 2
  end

  test "an improved fingerprint reclassifies without duplicating the occurrence", f do
    assert {:ok, _} = fail_run(f, %{})
    first = occurrence(f)

    {:ok, new_group} =
      SourceConfig.transaction(f.c.id, fn trusted ->
        evidence =
          Evidence.save(
            trusted,
            "reclass:1",
            "pipeline_task",
            %{"issues" => ["HTTP 500"], "tool" => "other", "occurred_at" => Store.iso(f.now)},
            f.now,
            f.now
          )

        fp =
          Fingerprints.identify(
            trusted.company_id,
            {trusted.id, "CI-only"},
            "other",
            "Unclassified failed operation"
          )

        Issues.record(
          trusted,
          "run:101:rec:1",
          evidence,
          fp,
          %{occurred_at: f.now, attempt: 1},
          f.now
        )
      end)

    moved = occurrence(f)
    assert moved["group_id"] == new_group
    refute new_group == first["group_id"]
    assert moved["evidence_revision"] == 2
    assert moved["occurrences"] == 1
    assert link_count(f, first["id"]) == 2

    {:ok, old_count} =
      SourceConfig.transaction(f.c.id, fn _ ->
        Store.one(
          "SELECT count(*)::integer AS n FROM failure_occurrences WHERE group_id=$1::text::uuid",
          [first["group_id"]]
        )
      end)

    assert old_count["n"] == 0
  end
end
