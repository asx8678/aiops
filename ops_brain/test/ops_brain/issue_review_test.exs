defmodule OpsBrain.IssueReviewTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{DatabaseSafety, Evidence, Issues, Replay, SourceConfig, Store}

  setup do
    f = fixture()
    c = config(f)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Application.put_env(:ops_brain, :http_plug, fn _ -> raise "local review contacted source" end)

    Application.put_env(:ops_brain, :notification_plug, fn _ ->
      raise "local review sent notification"
    end)

    on_exit(&cleanup/0)

    {:ok, _} =
      SourceConfig.transaction(c.id, fn trusted ->
        Evidence.failure(
          trusted,
          "audit-fixture",
          %{"issues" => ["HTTP 401"], "tool" => "test", "attempt" => 1},
          101,
          now
        )
      end)

    {:ok, [group]} = Issues.list(f.scope_a)
    Map.merge(f, %{c: c, now: now, group: group["id"], revision: group["revision"]})
  end

  defp state(f) do
    {:ok, [group]} = Issues.list(f.scope_a)
    group
  end

  test "every successful local action atomically records actual actor, versions and redacted local values",
       f do
    assert {:ok, assigned} =
             Issues.assign(f.scope_a, f.group, "token=CANARY_OWNER",
               expected_revision: f.revision
             )

    assert {:ok, unassigned} =
             Issues.unassign(f.scope_a, f.group, expected_revision: assigned["revision"])

    assert {:ok, reviewed} =
             Issues.review(f.scope_a, f.group, "quiet",
               expected_revision: unassigned["revision"],
               owner: "on-call"
             )

    until = DateTime.add(f.now, 3600)

    assert {:ok, snoozed} =
             Issues.snooze(f.scope_a, f.group, until, expected_revision: reviewed["revision"])

    assert {:ok, closed} =
             Issues.review(f.scope_a, f.group, "closed_by_reviewer",
               expected_revision: snoozed["revision"]
             )

    assert {:ok, reopened} =
             Issues.review(f.scope_a, f.group, "active", expected_revision: closed["revision"])

    assert reopened["revision"] == f.revision + 6
    assert reopened["owner"] == "on-call"
    assert DateTime.compare(reopened["snoozed_until"], until) == :eq
    assert {:ok, newest_first} = Issues.audit_history(f.scope_a, f.group)
    events = Enum.reverse(newest_first)
    assert Enum.map(events, & &1["action"]) == ~w(assign unassign review snooze review review)

    assert Enum.map(events, & &1["after_revision"]) ==
             Enum.to_list((f.revision + 1)..(f.revision + 6))

    for event <- events do
      assert event["actor_id"] == f.alice.id and event["actor_name"] == f.alice.name
      assert event["source_id"] == f.c.id and event["group_id"] == f.group
      assert event["after_revision"] == event["before_revision"] + 1
      assert DateTime.compare(event["inserted_at"], f.now) == :eq
      assert Enum.sort(Map.keys(event["before_state"])) == ~w(owner snoozed_until status)
      assert Enum.sort(Map.keys(event["after_state"])) == ~w(owner snoozed_until status)
    end

    assert hd(events)["before_state"]["owner"] == nil
    assert hd(events)["after_state"]["owner"] == "token=[REDACTED]"
    assert Enum.at(events, 3)["before_state"]["snoozed_until"] == nil

    assert Enum.at(events, 3)["after_state"]["snoozed_until"] ==
             Store.iso(snoozed["snoozed_until"])

    refute Jason.encode!(events) =~ "CANARY_OWNER"
    refute Jason.encode!(events) =~ f.token_a
    assert {:ok, _} = Replay.fingerprints(f.scope_a, f.now)
    assert {:ok, ^newest_first} = Issues.audit_history(f.scope_a, f.group)
  end

  test "stale, missing, malformed and invalid actions cannot change state or add history", f do
    assert {:ok, updated} =
             Issues.assign(f.scope_a, f.group, "winner", expected_revision: f.revision)

    before = state(f)
    assert {:ok, events} = Issues.audit_history(f.scope_a, f.group)

    actions = [
      fn opts -> Issues.assign(f.scope_a, f.group, "loser", opts) end,
      fn opts -> Issues.unassign(f.scope_a, f.group, opts) end,
      fn opts -> Issues.review(f.scope_a, f.group, "locally_acknowledged", opts) end,
      fn opts -> Issues.snooze(f.scope_a, f.group, DateTime.add(f.now, 60), opts) end
    ]

    for action <- actions do
      assert {:error, :stale_revision} = action.(expected_revision: f.revision)
      assert {:error, :revision_required} = action.([])

      for revision <- [nil, "2", 0, -1, true, 2.5, 2_147_483_647] do
        assert {:error, :invalid_revision} = action.(expected_revision: revision)
      end

      assert {:error, :invalid_options} =
               action.(expected_revision: updated["revision"], actor_id: f.bob.id)
    end

    assert {:error, :invalid_options} =
             Issues.review(f.scope_a, f.group, "active", "legacy-owner-without-revision")

    assert {:error, :invalid_transition} =
             Issues.review(f.scope_a, f.group, "recovered",
               expected_revision: updated["revision"]
             )

    assert {:error, :invalid_snooze} =
             Issues.snooze(f.scope_a, f.group, DateTime.add(f.now, 8, :day),
               expected_revision: updated["revision"]
             )

    assert state(f) == before
    assert {:ok, ^events} = Issues.audit_history(f.scope_a, f.group)
  end

  test "two physical connections with one observed revision produce one winner and one audit event",
       f do
    repo = start_supervised!({Repo, name: nil, pool_size: 2})
    tasks = start_supervised!(Task.Supervisor)
    {:ok, dual_scope} = Tenancy.authorize(f.token_dual, f.a.id)
    parent = self()

    workers =
      for {scope, owner} <- [{f.scope_a, "alice-choice"}, {dual_scope, "dual-choice"}] do
        Task.Supervisor.async_nolink(tasks, fn ->
          Repo.put_dynamic_repo(repo)

          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:ready, self(), backend})

            receive do
              :go -> Issues.assign(scope, f.group, owner, expected_revision: f.revision)
            after
              5000 -> raise "race start barrier timed out"
            end
          end)
        end)
      end

    assert_receive {:ready, first, backend_a}, 5000
    assert_receive {:ready, second, backend_b}, 5000
    refute backend_a == backend_b
    send(first, :go)
    send(second, :go)
    results = Task.await_many(workers, 10_000)
    assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1
    assert {:ok, [event]} = Issues.audit_history(f.scope_a, f.group)
    expected_actor = if state(f)["owner"] == "alice-choice", do: f.alice.id, else: f.dual.id
    assert event["actor_id"] == expected_actor
    assert state(f)["revision"] == f.revision + 1
    assert event["after_state"]["owner"] == state(f)["owner"]
  end

  test "membership revoked while a request waits for the row lock is rechecked before mutation",
       f do
    repo = start_supervised!({Repo, name: nil, pool_size: 1})
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    {:ok, worker} =
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.query!("SELECT id FROM issue_groups WHERE id=$1::text::uuid FOR UPDATE", [f.group])

        worker =
          Task.Supervisor.async_nolink(tasks, fn ->
            Repo.put_dynamic_repo(repo)

            Repo.checkout(fn ->
              [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:waiting_backend, backend})
              Issues.assign(f.scope_a, f.group, "revoked", expected_revision: f.revision)
            end)
          end)

        assert_receive {:waiting_backend, backend}, 5000

        waiting =
          Enum.reduce_while(1..300, false, fn _, _ ->
            [[waiting]] =
              TestAdminRepo.query!(
                "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
                [backend]
              ).rows

            if waiting,
              do: {:halt, true},
              else:
                (
                  Process.sleep(10)
                  {:cont, false}
                )
          end)

        assert waiting, "request must reach the row lock before membership is revoked"

        TestAdminRepo.query!(
          "DELETE FROM memberships WHERE operator_id=$1::text::uuid AND company_id=$2::text::uuid",
          [f.alice.id, f.a.id]
        )

        worker
      end)

    assert Task.await(worker, 5000) == {:error, :unauthorized}
    {:ok, scope} = Tenancy.authorize(f.token_dual, f.a.id)
    assert {:ok, [unchanged]} = Issues.list(scope)
    assert unchanged["revision"] == f.revision and unchanged["owner"] == nil
    assert {:ok, []} = Issues.audit_history(scope, f.group)
  end

  test "actor snapshots are byte-bounded UTF-8, redacted and stable across identity renames", f do
    TestAdminRepo.query!("UPDATE operators SET name=$1 WHERE id=$2::text::uuid", [
      "token=ACTOR_CANARY " <> String.duplicate("界", 50),
      f.alice.id
    ])

    assert {:ok, _} = Issues.assign(f.scope_a, f.group, "owner", expected_revision: f.revision)
    assert {:ok, [event]} = Issues.audit_history(f.scope_a, f.group)
    assert event["actor_id"] == f.alice.id
    assert String.valid?(event["actor_name"]) and byte_size(event["actor_name"]) <= 100
    assert event["actor_name"] =~ "token=[REDACTED]"
    refute Jason.encode!(event) =~ "ACTOR_CANARY"

    TestAdminRepo.query!("UPDATE operators SET name=$1 WHERE id=$2::text::uuid", [
      f.alice.name,
      f.alice.id
    ])

    assert {:ok, [^event]} = Issues.audit_history(f.scope_a, f.group)
  end

  test "an audit insertion failure rolls back the local update and revision", f do
    before = state(f)

    TestAdminRepo.query!(
      "CREATE FUNCTION r08_reject_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic audit storage failure'; END $$"
    )

    TestAdminRepo.query!(
      "CREATE TRIGGER r08_reject_audit BEFORE INSERT ON issue_audit_events FOR EACH ROW EXECUTE FUNCTION r08_reject_audit()"
    )

    try do
      assert_raise Postgrex.Error, fn ->
        Issues.assign(f.scope_a, f.group, "must-roll-back", expected_revision: f.revision)
      end

      assert state(f) == before
      assert {:ok, []} = Issues.audit_history(f.scope_a, f.group)
    after
      TestAdminRepo.query!("DROP TRIGGER r08_reject_audit ON issue_audit_events")
      TestAdminRepo.query!("DROP FUNCTION r08_reject_audit()")
    end
  end

  test "company scoping and revoked membership apply to writes and retained actor history", f do
    assert {:ok, updated} =
             Issues.assign(f.scope_a, f.group, "first", expected_revision: f.revision)

    assert {:ok, []} = Issues.audit_history(f.scope_b, f.group)
    assert {:ok, []} = Issues.audit_history(f.scope_a, Ecto.UUID.generate())

    assert {:ok, nil} =
             Issues.assign(f.scope_b, f.group, "foreign", expected_revision: updated["revision"])

    assert {:ok, nil} =
             Issues.review(f.scope_a, Ecto.UUID.generate(), "active", expected_revision: 1)

    assert Repo.query!("SELECT id FROM issue_audit_events").rows == []

    TestAdminRepo.query!(
      "DELETE FROM memberships WHERE operator_id=$1::text::uuid AND company_id=$2::text::uuid",
      [f.alice.id, f.a.id]
    )

    assert {:error, :unauthorized} =
             Issues.unassign(f.scope_a, f.group, expected_revision: updated["revision"])

    assert {:error, :unauthorized} = Issues.audit_history(f.scope_a, f.group)
    {:ok, dual_scope} = Tenancy.authorize(f.token_dual, f.a.id)
    assert {:ok, [%{"actor_id" => actor}]} = Issues.audit_history(dual_scope, f.group)
    assert actor == f.alice.id
  end

  test "runtime cannot rewrite or directly delete audit history and startup rejects excess grants",
       f do
    assert {:ok, _} = Issues.assign(f.scope_a, f.group, "owner", expected_revision: f.revision)

    for sql <- [
          "UPDATE issue_audit_events SET actor_name='tampered'",
          "DELETE FROM issue_audit_events",
          "TRUNCATE issue_audit_events"
        ] do
      assert_raise Postgrex.Error, fn ->
        Tenancy.with_scope(f.scope_a, fn -> Repo.query!(sql) end)
      end
    end

    DatabaseSafety.verify!()
    TestAdminRepo.query!("GRANT UPDATE ON issue_audit_events TO ops_brain_runtime")

    try do
      assert_raise RuntimeError, ~r/Unsafe audit history privileges/, fn ->
        DatabaseSafety.verify!()
      end
    after
      TestAdminRepo.query!("REVOKE UPDATE ON issue_audit_events FROM ops_brain_runtime")
    end

    assert {:ok, [_]} = Issues.audit_history(f.scope_a, f.group)
    DatabaseSafety.verify!()
  end

  test "audit constraints reject cross-source links, unknown actors and oversized local payloads",
       f do
    {:ok, other_source} = Tenancy.create_source(f.scope_a, %{name: "other-source"})

    base = [
      Ecto.UUID.generate(),
      f.a.id,
      f.c.id,
      f.group,
      f.alice.id,
      "actor",
      "assign",
      1,
      2,
      %{"status" => "new", "owner" => nil, "snoozed_until" => nil},
      %{"status" => "new", "owner" => "owner", "snoozed_until" => nil},
      f.now
    ]

    sql =
      "INSERT INTO issue_audit_events(id,company_id,source_id,group_id,actor_id,actor_name,action,before_revision,after_revision,before_state,after_state,inserted_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$6,$7,$8,$9,$10,$11,$12)"

    for {index, value, code} <- [
          {2, other_source.id, :foreign_key_violation},
          {4, Ecto.UUID.generate(), :foreign_key_violation},
          {5, String.duplicate("x", 101), :check_violation},
          {6, "upstream_restart", :check_violation},
          {8, 9, :check_violation},
          {9, Map.put(Enum.at(base, 9), "token", "forbidden-field"), :check_violation},
          {10, Map.put(Enum.at(base, 10), "owner", String.duplicate("x", 2049)),
           :check_violation},
          {1, f.b.id, :insufficient_privilege}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Tenancy.with_scope(f.scope_a, fn ->
            Repo.query!(sql, List.replace_at(base, index, value))
          end)
        end

      assert error.postgres.code == code
    end

    assert {:ok, []} = Issues.audit_history(f.scope_a, f.group)
  end

  test "history is bounded and follows deliberate parent retention rather than blocking it", f do
    last =
      Enum.reduce(1..55, f.revision, fn n, revision ->
        {:ok, updated} =
          Issues.assign(f.scope_a, f.group, "owner-#{div(n, 2)}", expected_revision: revision)

        updated["revision"]
      end)

    assert {:ok, events} = Issues.audit_history(f.scope_a, f.group)
    assert length(events) == 50
    # Repeated values are still intentional actions with distinct revisions/events.
    assert Enum.any?(events, &(&1["before_state"] == &1["after_state"]))
    assert Enum.map(events, & &1["after_revision"]) == Enum.to_list(last..(last - 49)//-1)

    assert {:ok, [[55]]} =
             Tenancy.with_scope(f.scope_a, fn ->
               Repo.query!("SELECT count(*) FROM issue_audit_events").rows
             end)

    assert {:ok, _} =
             Tenancy.with_scope(f.scope_a, fn ->
               Repo.query!("DELETE FROM issue_groups WHERE id=$1::text::uuid", [f.group])
             end)

    assert {:ok, []} = Issues.audit_history(f.scope_a, f.group)
  end
end
