defmodule OpsBrain.LifecycleDbTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Store, Issues, Evidence, Fingerprints}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    c = config(f, :a)
    Map.merge(f, %{c: c, now: DateTime.utc_now()})
  end

  defp fingerprint(c), do: Fingerprints.identify(c.company_id, "svc", "tool", "synthetic boom")

  defp record(f, c, key, at, severity) do
    {:ok, group} =
      SourceConfig.transaction(c.id, fn trusted ->
        evidence =
          Evidence.save(
            trusted,
            "lifecycle:#{key}",
            "pipeline_task",
            %{"occurred_at" => Store.iso(at), "key" => key},
            at,
            f.now
          )

        Issues.record(
          trusted,
          key,
          evidence,
          fingerprint(c),
          %{occurred_at: at, severity: severity, scope: "svc"},
          f.now
        )
      end)

    group
  end

  defp read(_f, c, id) do
    {:ok, row} =
      SourceConfig.transaction(c.id, fn _ ->
        Store.one(
          "SELECT severity,status,owner,first_seen,last_seen,(SELECT count(*)::integer FROM failure_occurrences WHERE group_id=$1::text::uuid) AS occurrences FROM issue_groups WHERE id=$1::text::uuid",
          [id]
        )
      end)

    row
  end

  test "severity escalates on the active group and is never downgraded by older evidence", f do
    t0 = DateTime.add(f.now, -600)
    t1 = DateTime.add(f.now, -300)

    group = record(f, f.c, "sev-1", t0, "warning")
    assert group == record(f, f.c, "sev-2", t1, "critical")
    assert read(f, f.c, group)["severity"] == "critical"

    assert group == record(f, f.c, "sev-3", t0, "warning")
    assert read(f, f.c, group)["severity"] == "critical"
    assert read(f, f.c, group)["occurrences"] == 3
  end

  test "episode membership uses event time, not arrival time", f do
    base = DateTime.add(f.now, -4 * 3600)
    e1 = base
    e2 = DateTime.add(base, 60)
    e3 = DateTime.add(base, 120)

    g3 = record(f, f.c, "ep-3", e3, "warning")
    g1 = record(f, f.c, "ep-1", e1, "warning")
    g2 = record(f, f.c, "ep-2", e2, "warning")

    assert g1 == g2 and g2 == g3
    row = read(f, f.c, g1)
    assert row["occurrences"] == 3
    assert DateTime.to_unix(row["first_seen"]) == DateTime.to_unix(e1)
    assert DateTime.to_unix(row["last_seen"]) == DateTime.to_unix(e3)
  end

  test "a reviewed closure is not silently reopened or joined", f do
    base = DateTime.add(f.now, -2 * 3600)
    group = record(f, f.c, "closed-1", base, "warning")
    assert {:ok, _} = Issues.review(f.scope_a, group, "closed_by_reviewer")

    new_group = record(f, f.c, "closed-2", DateTime.add(base, 300), "warning")
    refute new_group == group
    assert read(f, f.c, group)["status"] == "closed_by_reviewer"
  end

  test "reverse arrival outside the episode gap does not join a newer episode", f do
    newer = record(f, f.c, "gap-new", f.now, "warning")
    older = record(f, f.c, "gap-old", DateTime.add(f.now, -7200), "warning")
    refute older == newer
    assert read(f, f.c, older)["occurrences"] == 1
    assert read(f, f.c, newer)["occurrences"] == 1
  end

  test "duplicate critical and escalation preserve acknowledgment and assignment", f do
    group = record(f, f.c, "human-warning", f.now, "warning")
    assert {:ok, _} = Issues.assign(f.scope_a, group, "synthetic-owner")
    assert {:ok, _} = Issues.review(f.scope_a, group, "locally_acknowledged")
    assert group == record(f, f.c, "human-critical", f.now, "critical")
    record(f, f.c, "human-critical", f.now, "critical")
    row = read(f, f.c, group)
    assert row["severity"] == "critical"
    assert row["status"] == "locally_acknowledged"
    assert row["owner"] == "synthetic-owner"
    assert row["occurrences"] == 2
  end

  test "review preserves an existing owner when none is supplied", f do
    group = record(f, f.c, "owner-1", f.now, "warning")

    assert {:ok, %{"owner" => "synthetic-owner"}} =
             Issues.assign(f.scope_a, group, "synthetic-owner")

    assert {:ok, %{"owner" => "synthetic-owner", "status" => "locally_acknowledged"}} =
             Issues.review(f.scope_a, group, "locally_acknowledged")

    assert {:ok, %{"owner" => nil}} = Issues.unassign(f.scope_a, group)
    assert {:error, :invalid_owner} = Issues.assign(f.scope_a, group, nil)
  end
end
