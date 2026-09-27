defmodule OpsBrain.Insights.ThresholdsTest do
  # Config mutations are global: these tests run sync and restore the env.
  use ExUnit.Case, async: false
  alias OpsBrain.Insights

  @defaults %{
    storage: %{
      warn_pct: 85,
      crit_pct: 95,
      warn_hours: 72,
      crit_hours: 24,
      abnormal_factor: 3,
      recent_window_hours: 6,
      min_abnormal_rate_gib_h: 0.25
    },
    pipelines: %{window: 10, streak_critical: 2, last5_critical: 3}
  }

  setup do
    prior = Application.get_env(:ops_brain, Insights)
    on_exit(fn -> restore_env(prior) end)
    :ok
  end

  defp restore_env(nil), do: Application.delete_env(:ops_brain, Insights)
  defp restore_env(value), do: Application.put_env(:ops_brain, Insights, value)

  defp flat(used), do: for(h <- 23..0//-1, do: %{"hours_ago" => h, "used_gib" => used})

  defp history(end_used, baseline, recent) do
    for h <- 23..0//-1 do
      used = end_used - recent * min(h, 6) - baseline * max(h - 6, 0)
      %{"hours_ago" => h, "used_gib" => used}
    end
  end

  defp stopped_growth do
    for h <- 23..0//-1 do
      %{"hours_ago" => h, "used_gib" => if(h <= 3, do: 150.0, else: 140.0)}
    end
  end

  defp runs(results),
    do: Enum.map(results, &%{"service" => "svc", "result" => &1, "finish_at" => nil})

  test "defaults are returned unchanged without config" do
    assert Insights.thresholds() == @defaults
  end

  test "malformed top-level and nested config never raises and yields defaults" do
    for bad <- [false, true, 42, "nonsense", :atom, {1, 2}] do
      Application.put_env(:ops_brain, Insights, bad)
      assert Insights.thresholds() == @defaults
    end

    Application.put_env(:ops_brain, Insights, storage: [42], pipelines: "garbage")
    assert Insights.thresholds() == @defaults
  end

  test "string-key group maps are accepted at top level and inside" do
    Application.put_env(:ops_brain, Insights, %{"storage" => %{"warn_pct" => 90}})

    t = Insights.thresholds()
    assert t.storage.warn_pct == 90
    assert t.storage.warn_hours == 72
    assert t.pipelines == @defaults.pipelines

    Application.put_env(:ops_brain, Insights, %{"pipelines" => %{"window" => 4}})
    assert Insights.thresholds().pipelines.window == 4
  end

  test "keyword-list overrides change every listed storage decision" do
    # default side of each boundary first
    pct = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(87.0)})
    assert pct.level == "warning"

    crit_pct = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(96.0)})
    assert crit_pct.level == "critical"

    # (256-181)/5 = 15h to full: critical by the default crit_hours 24
    crit = Insights.analyze_storage(%{"size_gib" => 256, "history" => history(181.0, 5.0, 5.0)})
    assert crit.level == "critical"

    # (256-191)/1 = 65h to full: warning by the default warn_hours 72
    warn = Insights.analyze_storage(%{"size_gib" => 256, "history" => history(191.0, 1.0, 1.0)})
    assert warn.level == "warning"

    factor = Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.5, 1.5)})
    assert factor.abnormal
    assert factor.level == "warning"

    window = Insights.analyze_storage(%{"size_gib" => 256, "history" => stopped_growth()})
    assert window.level == "warning"

    min_rate =
      Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.0, 0.5)})

    assert min_rate.abnormal
    assert min_rate.level == "warning"

    Application.put_env(:ops_brain, Insights,
      storage: [
        warn_pct: 90,
        crit_pct: 97,
        warn_hours: 60,
        crit_hours: 12,
        abnormal_factor: 5,
        recent_window_hours: 3,
        min_abnormal_rate_gib_h: 1.0
      ]
    )

    # 87% is now below warn_pct 90
    assert Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(87.0)}).level ==
             "ok"

    # 96% is now below crit_pct 97
    assert Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(96.0)}).level ==
             "warning"

    # 15h to full is now above crit_hours 12 (still under warn_hours 60)
    assert Insights.analyze_storage(%{"size_gib" => 256, "history" => history(181.0, 5.0, 5.0)}).level ==
             "warning"

    # 65h to full is now above warn_hours 60
    assert Insights.analyze_storage(%{"size_gib" => 256, "history" => history(191.0, 1.0, 1.0)}).level ==
             "ok"

    # a 3x jump is now below abnormal_factor 5
    assert Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.5, 1.5)}).level ==
             "ok"

    # growth that stopped 4h ago is outside the 3h recent window: not measured
    stopped = Insights.analyze_storage(%{"size_gib" => 256, "history" => stopped_growth()})
    assert stopped.recent_rate == 0.0
    assert stopped.level == "ok"

    # 0.5 GiB/h over a flat baseline is below the 1.0 minimum abnormal rate
    assert Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.0, 0.5)}).level ==
             "ok"
  end

  test "pipeline window, streak and last5 overrides" do
    Application.put_env(:ops_brain, Insights,
      pipelines: [window: 3, streak_critical: 4, last5_critical: 4]
    )

    # window 3 + streak_critical 4: five straight failures are only a warning
    [five] = Insights.pipeline_health(runs(~w(failed failed failed failed failed)))
    assert five.level == "warning"

    Application.delete_env(:ops_brain, Insights)

    [default] = Insights.pipeline_health(runs(~w(failed failed failed failed failed)))
    assert default.level == "critical"

    # streak_critical 4 with last5_critical 5: four consecutive failures critical, three not
    Application.put_env(:ops_brain, Insights, pipelines: [streak_critical: 4, last5_critical: 5])

    [four] = Insights.pipeline_health(runs(~w(failed failed failed failed succeeded)))
    assert four.level == "critical"

    [three] = Insights.pipeline_health(runs(~w(failed failed failed succeeded succeeded)))
    assert three.level == "warning"

    # last5_critical 4: three of the last five is not critical, four is
    Application.put_env(:ops_brain, Insights, pipelines: [last5_critical: 4])

    [three_last] = Insights.pipeline_health(runs(~w(failed succeeded failed succeeded failed)))
    assert three_last.level == "warning"

    [four_last] = Insights.pipeline_health(runs(~w(failed succeeded failed failed failed)))
    assert four_last.level == "critical"
  end

  test "a failing streak below the configured critical threshold never reads as recovered" do
    results =
      ~w(failed failed failed succeeded succeeded failed failed failed succeeded succeeded)

    [default] = Insights.pipeline_health(runs(results))
    assert default.streak == 3
    assert default.level == "critical"

    Application.put_env(:ops_brain, Insights, pipelines: [streak_critical: 4, last5_critical: 5])

    [raised] = Insights.pipeline_health(runs(results))
    assert raised.streak == 3
    assert raised.level == "warning"
    assert raised.reason == "latest run failed and it has failed before"
    refute raised.reason =~ "recovered"
  end

  test "prior five stays capped at five when the window grows" do
    Application.put_env(:ops_brain, Insights, pipelines: [window: 12])

    results =
      ~w(succeeded failed succeeded failed succeeded succeeded succeeded failed succeeded succeeded failed failed)

    [p] = Insights.pipeline_health(runs(results))
    assert p.level == "warning"
    assert p.reason == "failing more often than before"
  end

  test "map and string-key overrides are accepted" do
    Application.put_env(:ops_brain, Insights, %{storage: %{"warn_pct" => 92, crit_pct: 93}})

    t = Insights.thresholds()
    assert t.storage.warn_pct == 92
    assert t.storage.crit_pct == 93
    assert t.storage.warn_hours == 72
    assert t.pipelines == @defaults.pipelines

    # 88% used is below warn_pct 92: ok instead of warning
    assert Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(88.0)}).level ==
             "ok"
  end

  test "invalid overrides fall back per key and unknown keys are ignored" do
    Application.put_env(:ops_brain, Insights,
      storage: [
        warn_pct: "90",
        crit_pct: nil,
        warn_hours: -1,
        crit_hours: 0,
        abnormal_factor: 1,
        recent_window_hours: :six,
        min_abnormal_rate_gib_h: "lots",
        bogus: 42
      ],
      pipelines: [window: 2.5, streak_critical: 0, last5_critical: "3", other: 1]
    )

    assert Insights.thresholds() == @defaults
  end
end
