defmodule OpsBrain.DetectorsTest do
  use ExUnit.Case, async: true

  alias OpsBrain.{
    Fingerprints,
    Redactor,
    Evidence,
    Metrics,
    Logs,
    Capacity,
    Kubernetes,
    Correlation
  }

  test "redaction preserves semantics, unknown generic exit and exact versioned scope" do
    text = "HTTP 401 dependency api.example.test token=FAKE_SECRET_123 password=FAKE_PASSWORD"
    clean = Redactor.clean(text)
    refute clean =~ "FAKE_"
    assert Fingerprints.classify(clean) == "authentication_rejection"
    assert Fingerprints.classify("Process exited with code 1") == "unclassified"
    a = Fingerprints.identify("A", "prod", "tool", text)
    assert a.fingerprint != Fingerprints.identify("B", "prod", "tool", text).fingerprint
    assert a.fingerprint != Fingerprints.identify("A", "dev", "tool", text).fingerprint

    assert a.fingerprint !=
             Fingerprints.identify("A", "prod", "tool", String.replace(text, "401", "403")).fingerprint

    assert Fingerprints.normalize("TS1234 2025-01-01T00:00:00Z") ==
             Fingerprints.normalize("TS1234 2025-02-02T01:00:00Z")

    assert byte_size(Redactor.clean(String.duplicate("é", 5000), 99)) <= 99
    assert Redactor.clean(<<255>>) == "[invalid UTF-8]"
  end

  test "failed parent is not another leaf; attempts and sanitized issues remain" do
    body =
      Jason.encode!(%{
        records: [
          %{id: "parent", result: "failed"},
          %{
            id: "child",
            parentId: "parent",
            result: "failed",
            attempt: 2,
            issues: [%{message: "HTTP 403 token=FAKE_CANARY"}],
            previousAttempts: [%{attempt: 1, recordId: "child"}]
          }
        ]
      })

    assert {:ok, [leaf]} = Evidence.parse_timeline(body)
    assert leaf["attempt"] == 2 and leaf["parent_id"] == "parent"
    refute Jason.encode!(leaf) =~ "FAKE_CANARY"
    assert length(leaf["previous_attempts"]) == 1
  end

  test "metric missing stale NaN warnings and matched traffic ratios" do
    now = ~U[2025-01-01 00:00:00Z]

    body = fn value, ts ->
      Jason.encode!(%{
        status: "success",
        data: %{
          resultType: "vector",
          result: [%{metric: %{job: "synthetic"}, value: [ts, value]}]
        }
      })
    end

    assert {:ok, [_]} = Metrics.decode(body.("0", DateTime.to_unix(now)), now, 60)
    assert {:error, _} = Metrics.decode(body.("NaN", DateTime.to_unix(now)), now, 60)
    assert {:error, _} = Metrics.decode(body.("3", DateTime.to_unix(now) - 120), now, 60)
    n = [%{"series" => "a", "value" => 5}, %{"series" => "b", "value" => 0}]
    d = [%{"series" => "a", "value" => 10}, %{"series" => "b", "value" => 90}]
    assert {:ok, 0.05} = Metrics.ratio(n, d, 50)
    assert {:error, _} = Metrics.ratio(n, tl(d), 1)
    assert {:error, _} = Metrics.ratio(n, d, 1000)
    assert Metrics.condition([], %{}) == "unknown"
  end

  test "Loki total independent of downloaded samples and legitimate identical entries retained" do
    total =
      Jason.encode!(%{
        status: "success",
        data: %{resultType: "vector", result: [%{value: [1, "4000"]}]}
      })

    assert {:ok, 4000.0} = Logs.decode_count(total)

    body =
      Jason.encode!(%{
        status: "success",
        data: %{
          resultType: "streams",
          result: [
            %{
              stream: %{app: "test"},
              values: List.duplicate(["123", "same legitimate error"], 200)
            }
          ]
        }
      })

    assert {:ok, samples, "capped_or_saturated"} = Logs.decode_samples(body)
    assert length(samples) == 200

    assert {:error, _} =
             Logs.decode_count(
               Jason.encode!(%{status: "success", data: %{resultType: "vector", result: []}})
             )
  end

  defp policy,
    do: %{
      unit: "bytes",
      limits_verified: true,
      freshness_seconds: 120,
      max_gap_seconds: 60,
      min_history_seconds: 240,
      effective_threshold: 1000,
      min_growth_bytes_per_second: 0.1,
      warning_horizon_seconds: 1000
    }

  defp history,
    do:
      for(
        i <- 0..5,
        do: %{
          time: i * 60,
          received_at: i * 60,
          value: 100 + i * 60,
          unit: "bytes",
          series: "storage-a",
          segment: "stable"
        }
      )

  test "capacity positive growth conditional; flat negative resize stale and future evidence suppressed" do
    assert %{condition: "warning", seconds_to_threshold: 600.0} =
             Capacity.evaluate(history(), policy(), 300)

    assert %{condition: "unknown"} =
             Capacity.evaluate(Enum.map(history(), &%{&1 | value: 100}), policy(), 300)

    assert %{condition: "unknown"} =
             Capacity.evaluate(Enum.map(history(), &%{&1 | value: -&1.value}), policy(), 300)

    assert %{condition: "unknown"} =
             Capacity.evaluate(
               List.update_at(history(), 5, &%{&1 | segment: "resized"}),
               policy(),
               300
             )

    assert %{condition: "unknown"} = Capacity.evaluate(history(), policy(), 600)
    assert [%{result: %{condition: "unknown"}}] = Capacity.backtest(history(), policy(), [60])

    assert Capacity.evaluate(
             history() ++
               [
                 %{
                   time: 301,
                   received_at: 500,
                   value: 999,
                   unit: "bytes",
                   series: "storage-a",
                   segment: "stable"
                 }
               ],
             policy(),
             300
           ) == Capacity.evaluate(history(), policy(), 300)
  end

  defp pod(uid, rv, restarts),
    do: %{
      "metadata" => %{
        "uid" => uid,
        "name" => "same-name",
        "namespace" => "test",
        "resourceVersion" => rv,
        "annotations" => %{"secret" => "FAKE"}
      },
      "spec" => %{"secret" => "FAKE"},
      "status" => %{
        "phase" => "Running",
        "containerStatuses" => [%{"ready" => true, "restartCount" => restarts}]
      }
    }

  test "Kubernetes initial snapshot opaque RV UID reuse restart deltas and 410" do
    assert {:ok, s} =
             Kubernetes.initial(
               %{
                 "metadata" => %{"resourceVersion" => "opaque:a"},
                 "items" => [pod("old", "v1", 2)]
               },
               "test",
               false
             )

    assert s["changes"] == []
    refute Jason.encode!(s) =~ "FAKE"
    event = Jason.encode!(%{type: "MODIFIED", object: pod("old", "v2", 3)})
    assert {:ok, s2} = Kubernetes.decode_watch(s, event)
    assert [%{"restart_delta" => 1}] = s2["changes"]
    assert {:ok, s3} = Kubernetes.decode_watch(s2, event)
    assert s3["changes"] == []

    assert {:ok, s4} =
             Kubernetes.decode_watch(
               s3,
               Jason.encode!(%{type: "ADDED", object: pod("new", "v3", 3)})
             )

    assert map_size(s4["objects"]) == 2 and s4["changes"] == []

    assert {:error, :expired} =
             Kubernetes.decode_watch(s4, Jason.encode!(%{type: "ERROR", object: %{code: 410}}))
  end

  test "correlation preserves alternatives counterevidence and knowledge time across arrival order" do
    symptom = %{
      company_id: "a",
      environment_id: "prod",
      target_id: "api",
      occurred_at: 100,
      evidence_id: "symptom"
    }

    changes =
      for {id, t} <- [{"early", 90}, {"late", 110}],
          do: Map.merge(symptom, %{occurred_at: t, received_at: t, evidence_id: id})

    a = Correlation.evaluate(symptom, changes, [], 120)
    assert a == Correlation.evaluate(symptom, Enum.reverse(changes), [], 120)
    assert length(a.candidates) == 2
    assert List.last(a.candidates).counterevidence == ["symptom predates change"]
    assert length(Correlation.evaluate(symptom, changes, [], 100).candidates) == 1
    assert Correlation.evaluate(%{symptom | company_id: "b"}, changes, [], 120).candidates == []
  end
end
