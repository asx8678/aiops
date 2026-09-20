defmodule OpsBrain.KubernetesConsolidationTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  alias OpsBrain.{SourceConfig, Tenancy, Evidence, Replay, Retention}

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Application.put_env(:ops_brain, :clock, fn -> now end)
    Map.merge(f, %{now: now})
  end

  test "omitted kubernetes resources default to pods through the single engine", f do
    {:ok, source} = Tenancy.create_source(f.scope_a, %{name: "k8s-omitted", kind: :kubernetes})

    c =
      config(%{f | source_a: source}, :a, %{
        kind: "kubernetes",
        namespace: "synthetic",
        page_size: 100,
        max_pages: 10,
        interval_seconds: 30,
        inventory_limit: 200
      })

    refute Map.has_key?(c, :resources)
    {:ok, fetched} = SourceConfig.fetch(c.id)
    assert fetched.resources == ["pods"]

    Application.put_env(:ops_brain, :http_plug, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"metadata" => %{"resourceVersion" => "rv1"}, "items" => []})
      )
    end)

    assert {:ok, %{"_pending_cursor" => %{"state" => %{"resource" => "pods"}}}} =
             OpsBrain.Kubernetes.reconcile(fetched, f.now, nil)

    assert {:ok, _} = OpsBrain.TelemetryCollection.tick(c.id, f.now)

    assert {:ok, %{"resource" => "pods", "revision" => 1}} =
             SourceConfig.transaction(c.id, fn _ ->
               OpsBrain.Store.one("SELECT resource,revision FROM kubernetes_cursors")
             end)
  end

  test "expiry belongs to maintenance and is tenant scoped and idempotent", f do
    config(f)
    old = DateTime.add(f.now, -9, :day)

    {:ok, _} =
      SourceConfig.transaction(f.source_a.id, fn c ->
        Evidence.save(
          c,
          "expire-legacy:#{System.unique_integer([:positive])}",
          "pipeline_task",
          %{"tool" => "x", "issues" => ["ENOSPC"]},
          old,
          old
        )
      end)

    refute {:expire, 1} in Replay.__info__(:functions)
    refute {:expire, 2} in Replay.__info__(:functions)
    assert {:ok, 0} = Retention.expire_evidence(f.scope_b, f.now)
    assert {:ok, 1} = Retention.expire_evidence(f.scope_a, f.now)
    assert {:ok, 0} = Retention.expire_evidence(f.scope_a, f.now)
  end
end
