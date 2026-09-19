defmodule OpsBrain.InvestigationTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures

  alias OpsBrain.{
    Services,
    SourceConfig,
    Deployments,
    Store,
    Issues,
    Evidence,
    Fingerprints,
    InvestigationWorker
  }

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    env = Enum.find(f.envs, &(&1.company_id == f.a.id and &1.name == :prod))

    {:ok, s} =
      Services.create(f.scope_a, %{
        source_id: f.source_a.id,
        environment_id: env.id,
        service_key: "api",
        target: "ns/api"
      })

    c =
      config(f, :a, %{
        stage_targets: [%{"stage_identifier" => "DeployProd", "service_id" => s["id"]}]
      })

    Map.merge(f, %{c: c, service: s["id"], now: DateTime.utc_now()})
  end

  test "reported deployment is explicit, replay idempotent, delayed changes recompute evidence candidates",
       f do
    assert {:ok, group} =
             SourceConfig.transaction(f.c.id, fn c ->
               e =
                 Evidence.save(
                   c,
                   "symptom",
                   "prometheus",
                   %{"observed" => "pressure threshold exceeded"},
                   f.now,
                   f.now
                 )

               fp = Fingerprints.identify(c.company_id, f.service, "metric", "pressure")
               Issues.record(c, "symptom", e, fp, %{occurred_at: f.now, scope: f.service}, f.now)
             end)

    assert {:ok, %{candidates: []}} =
             SourceConfig.transaction(f.c.id, fn c ->
               InvestigationWorker.evaluate(c, group, f.now)
             end)

    changed = DateTime.add(f.now, -60)

    body =
      Jason.encode!(%{
        records: [
          %{
            id: "stage",
            identifier: "DeployProd",
            type: "Stage",
            state: "completed",
            result: "succeeded",
            attempt: 1,
            finishTime: Store.iso(changed)
          }
        ]
      })

    later = DateTime.add(f.now, 30)

    for _ <- 1..2 do
      assert {:ok, _} =
               SourceConfig.transaction(f.c.id, fn c ->
                 Deployments.persist(c, 101, body, later)
               end)
    end

    assert {:ok, %{candidates: [candidate]}} =
             SourceConfig.transaction(f.c.id, fn c ->
               InvestigationWorker.evaluate(c, group, later)
             end)

    assert candidate.elapsed_seconds == 60
    assert candidate.relation =~ "not established cause"
    assert {:ok, items} = Issues.evidence(f.scope_a, group, later)
    assert Enum.any?(items, &(&1["kind"] == "correlation"))
    assert {:ok, []} = Issues.evidence(f.scope_b, group, later)

    assert {:ok, %{"n" => 1}} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.one(
                 "SELECT count(*)::integer AS n FROM evidence_items WHERE kind='deployment'"
               )
             end)

    assert {:ok, %{candidates: []}} =
             SourceConfig.transaction(f.c.id, fn c ->
               InvestigationWorker.evaluate(c, group, f.now)
             end)
  end

  test "unmapped stage never creates a production deployment", f do
    body =
      Jason.encode!(%{
        records: [
          %{id: "ci", identifier: "Build", type: "Stage", state: "completed", result: "succeeded"}
        ]
      })

    assert {:ok, _} =
             SourceConfig.transaction(f.c.id, fn c -> Deployments.persist(c, 101, body, f.now) end)

    assert {:ok, []} =
             SourceConfig.transaction(f.c.id, fn _ ->
               Store.rows("SELECT * FROM evidence_items WHERE kind='deployment'")
             end)
  end
end
