defmodule OpsBrain.InsightsTest do
  use ExUnit.Case, async: true
  alias OpsBrain.Insights

  defp history(end_used, baseline, recent) do
    for h <- 23..0//-1 do
      used = end_used - recent * min(h, 6) - baseline * max(h - 6, 0)
      %{"hours_ago" => h, "used_gib" => used}
    end
  end

  describe "analyze_storage/1" do
    test "flags abnormal growth and projects time to full" do
      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history(215.0, 0.15, 2.1)})

      assert r.abnormal
      assert r.level == "critical"
      assert_in_delta r.recent_rate, 2.1, 0.001
      assert_in_delta r.baseline_rate, 0.15, 0.001
      assert_in_delta r.hours_to_full, 35 / 2.1, 0.01
    end

    test "steady growth with plenty of space is ok" do
      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history(145.0, 0.2, 0.2)})

      refute r.abnormal
      assert r.level == "ok"
    end

    test "high usage alone is a warning" do
      r = Insights.analyze_storage(%{"size_gib" => 100, "history" => history(90.0, 0.0, 0.0)})

      assert r.level == "warning"
      assert r.hours_to_full == nil
    end

    test "unverified volume size is unknown, never healthy" do
      r = Insights.analyze_storage(%{"size_gib" => nil, "history" => history(215.0, 0.15, 2.1)})

      assert r.level == "unknown"
      assert r.reasons == ["volume size not verified"]
      assert r.size_gib == nil
      assert r.used_percent == nil
      assert r.hours_to_full == nil
      refute r.abnormal
      assert_in_delta r.used_gib, 215.0, 0.001
      assert length(r.history) == 24
    end

    test "unverified size without usable history stays unknown" do
      r = Insights.analyze_storage(%{"size_gib" => nil, "history" => []})

      assert r.level == "unknown"
      assert r.used_gib == nil
      assert r.history == []
      assert r.reasons == ["volume size not verified"]
    end

    test "verified size without history yields no risk" do
      assert Insights.analyze_storage(%{"size_gib" => 250, "history" => []}) == nil
    end

    test "mixed series or source identities are unknown, never a spliced trajectory" do
      r =
        Insights.analyze_storage(%{
          "mixed_identities" => true,
          "size_gib" => 250,
          "history" => history(215.0, 0.15, 2.1)
        })

      assert r.level == "unknown"

      assert r.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]

      assert r.history == []
      assert r.used_gib == nil
      assert r.hours_to_full == nil
    end

    test "a single sample cannot claim a measured normal rate" do
      high =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => [%{"hours_ago" => 0, "used_gib" => 225.0}]
        })

      # 90% used is a factual warning; the growth forecast is withheld
      assert high.level == "warning"
      assert high.hours_to_full == nil
      assert high.recent_rate == nil
      refute high.abnormal
      assert "insufficient history for a growth forecast" in high.reasons

      low =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => [%{"hours_ago" => 0, "used_gib" => 40.0}]
        })

      # low usage without a measured rate is unknown, never healthy
      assert low.level == "unknown"
      assert low.reasons == ["insufficient history for a growth forecast"]
    end

    test "flat low usage never crashes on nullable projections and stays ok" do
      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history(40.0, 0.0, 0.0)})

      assert r.level == "ok"
      assert r.hours_to_full == nil
      refute r.abnormal
      assert r.reasons == ["growth within normal range"]
      assert_in_delta r.recent_rate, 0.0, 0.001
      assert_in_delta r.baseline_rate, 0.0, 0.001
    end

    test "declining usage projects nothing and is not flagged" do
      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history(40.0, 0.0, -0.5)})

      assert r.level == "ok"
      assert r.hours_to_full == nil
      refute r.abnormal
      assert_in_delta r.recent_rate, -0.5, 0.001
      assert_in_delta r.baseline_rate, 0.0, 0.001
    end

    test "a sparse recent window claims no rate and no health" do
      r =
        Insights.analyze_storage(%{
          "size_gib" => 1000,
          "fresh_hours" => 0,
          "history" => [
            %{"hours_ago" => 12, "used_gib" => 10},
            %{"hours_ago" => 0, "used_gib" => 20}
          ]
        })

      assert r.level == "unknown"
      assert r.reasons == ["insufficient history for a growth forecast"]
      assert r.hours_to_full == nil
      assert r.recent_rate == nil
    end

    test "two fresh points measure a rate but claim no baseline or jump" do
      r =
        Insights.analyze_storage(%{
          "size_gib" => 1000,
          "fresh_hours" => 0,
          "history" => [
            %{"hours_ago" => 1, "used_gib" => 10},
            %{"hours_ago" => 0, "used_gib" => 11}
          ]
        })

      assert r.level == "unknown"
      assert_in_delta r.recent_rate, 1.0, 0.001
      assert r.baseline_rate == nil
      refute r.abnormal
      assert_in_delta r.hours_to_full, 989.0, 0.001

      assert r.reasons == [
               "recent growth 1.0 GiB/h measured; no baseline history to compare"
             ]
    end

    test "stale history supports no forecast and no healthy claim" do
      growing =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => history(215.0, 0.15, 2.1),
          "fresh_hours" => 8
        })

      # 86% used stays a factual warning; the 16.7 h projection is withheld
      assert growing.level == "warning"
      assert growing.hours_to_full == nil
      refute growing.abnormal
      assert Enum.any?(growing.reasons, &String.starts_with?(&1, "usage history is 8"))

      flat =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => history(40.0, 0.0, 0.0),
          "fresh_hours" => 12
        })

      assert flat.level == "unknown"
      assert flat.hours_to_full == nil
      assert flat.reasons == ["usage history is 12.0 h old — growth not projected"]

      # fresh-enough history keeps the full forecast
      fresh =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => history(215.0, 0.15, 2.1),
          "fresh_hours" => 2
        })

      assert fresh.level == "critical"
      assert_in_delta fresh.hours_to_full, 35 / 2.1, 0.01
    end
  end

  describe "storage_risks/2" do
    test "worst first with service metadata; unknown is never healthy" do
      services = %{
        "s1" => %{"service_key" => "orders", "environment" => "prod", "target" => "c/ns/orders"},
        "s2" => %{"service_key" => "billing", "environment" => "staging", "target" => "c/ns/b"}
      }

      series = [
        %{
          "volume" => "orders-db",
          "service_id" => "s1",
          "size_gib" => 250,
          "history" => history(145.0, 0.2, 0.2)
        },
        %{
          "volume" => "unverified",
          "service_id" => "s2",
          "size_gib" => nil,
          "history" => history(215.0, 0.15, 2.1)
        },
        %{
          "volume" => "billing-db",
          "service_id" => "s2",
          "size_gib" => 250,
          "history" => history(215.0, 0.15, 2.1)
        }
      ]

      [critical, unknown, ok] = Insights.storage_risks(series, services)

      assert critical.volume == "billing-db"
      assert critical.level == "critical"
      assert critical.service == "billing"
      assert critical.environment == "staging"
      assert critical.target == "c/ns/b"

      assert unknown.level == "unknown"
      assert unknown.volume == "unverified"
      assert unknown.reasons == ["volume size not verified"]

      assert ok.volume == "orders-db"
      assert ok.level == "ok"
    end
  end

  describe "threshold boundaries (defaults)" do
    defp flat(used), do: for(h <- 23..0//-1, do: %{"hours_ago" => h, "used_gib" => used})

    test "exact percentage equality: 85.0 is a warning and 95.0 is critical" do
      # 85/100*100 and 95/100*100 are exactly representable doubles
      warn = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(85.0)})
      assert warn.level == "warning"

      crit = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(95.0)})
      assert crit.level == "critical"

      below = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(84.99)})
      assert below.level == "ok"

      at_94 = Insights.analyze_storage(%{"size_gib" => 100, "history" => flat(94.99)})
      assert at_94.level == "warning"
    end

    test "usage percentage boundaries around warn_pct 85 and crit_pct 95" do
      below = Insights.analyze_storage(%{"size_gib" => 256, "history" => flat(217.0)})
      assert below.level == "ok"

      warn = Insights.analyze_storage(%{"size_gib" => 256, "history" => flat(218.0)})
      assert warn.level == "warning"

      crit = Insights.analyze_storage(%{"size_gib" => 256, "history" => flat(244.0)})
      assert crit.level == "critical"
    end

    test "hours-to-full boundaries: exactly crit_hours is not critical, exactly warn_hours is ok" do
      # (256-136)/5 = 24.0 exactly; baseline matches the recent rate, so no
      # abnormal-jump claim interferes with the hours comparison
      at_crit =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(136.0, 5.0, 5.0)})

      assert at_crit.level == "warning"

      under_crit =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(137.0, 5.0, 5.0)})

      assert under_crit.level == "critical"

      # (256-184)/1 = 72.0 exactly
      at_warn =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(184.0, 1.0, 1.0)})

      assert at_warn.level == "ok"

      under_warn =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(185.0, 1.0, 1.0)})

      assert under_warn.level == "warning"
    end

    test "abnormal factor boundary: ratio exactly 3 flags, 2.9 does not" do
      exact =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.5, 1.5)})

      assert exact.abnormal
      assert exact.level == "warning"

      lower =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.5, 1.45)})

      refute lower.abnormal
      assert lower.level == "ok"
    end

    test "minimum abnormal rate boundary: exactly 0.25 does not flag, 0.26 does" do
      at_min =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.0, 0.25)})

      refute at_min.abnormal
      assert at_min.level == "ok"

      above =
        Insights.analyze_storage(%{"size_gib" => 256, "history" => history(100.0, 0.0, 0.26)})

      assert above.abnormal
      assert above.level == "warning"
    end

    test "recent window boundary: hours_ago 6 is inside, 7 is outside" do
      inside =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => [
            %{"hours_ago" => 6, "used_gib" => 100.0},
            %{"hours_ago" => 0, "used_gib" => 110.0}
          ]
        })

      assert_in_delta inside.recent_rate, 10 / 6, 0.001

      outside =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => [
            %{"hours_ago" => 7, "used_gib" => 100.0},
            %{"hours_ago" => 0, "used_gib" => 110.0}
          ]
        })

      assert outside.recent_rate == nil
      assert outside.level == "unknown"
    end

    test "pipeline window boundary: only the newest 10 runs count" do
      results =
        ~w(failed failed failed failed failed failed failed failed failed failed succeeded)

      [p] =
        Insights.pipeline_health(
          Enum.map(results, &%{"service" => "svc", "result" => &1, "finish_at" => nil})
        )

      assert p.streak == 10
      assert p.total == 10
      assert p.level == "critical"
    end

    test "streak and last5 boundaries at their defaults" do
      # exactly 3 of the last 5 failed (non-consecutive): critical
      [three] =
        Insights.pipeline_health(runs("svc", ~w(failed succeeded failed succeeded failed)))

      assert three.level == "critical"

      # only 2 of the last 5: falls through to a warning
      [two_last] =
        Insights.pipeline_health(runs("svc", ~w(failed succeeded failed succeeded succeeded)))

      assert two_last.level == "warning"
    end
  end

  describe "analyze_growth/3" do
    defp series(values) do
      for {h, v} <- values, do: %{"hours_ago" => h, "value" => v}
    end

    test "an unverified limit is unknown in any unit, never healthy" do
      r =
        Insights.analyze_growth(
          %{"history" => series([{6, 40.0}, {0, 44.0}])},
          nil,
          "connections"
        )

      assert r.level == "unknown"
      assert r.reasons == ["verified limit unavailable"]
      assert r.limit == nil
      assert r.percent == nil
      assert r.hours_to_full == nil
      assert r.unit == "connections"
      assert_in_delta r.value, 44.0, 0.001
    end

    test "measured count growth analyzes in the signal's own unit" do
      # 500-connection limit; 10/h recent rate over a 1/h baseline
      history =
        for h <- 23..0//-1 do
          v = 480 - 10 * min(h, 6) - 1 * max(h - 6, 0)
          %{"hours_ago" => h, "value" => v}
        end

      r = Insights.analyze_growth(%{"history" => history}, 500, "connections")

      assert r.level == "critical"
      assert r.unit == "connections"
      assert r.value == 480
      assert r.limit == 500
      assert_in_delta r.percent, 96.0, 0.001
      assert_in_delta r.recent_rate, 10.0, 0.001
      assert_in_delta r.baseline_rate, 1.0, 0.001
      assert r.abnormal
      assert_in_delta r.hours_to_full, 2.0, 0.01
      assert Enum.any?(r.reasons, &String.contains?(&1, "connections free"))
      assert Enum.any?(r.reasons, &String.contains?(&1, "connections/h"))
    end

    test "mixed identities stay unknown through the shared helper" do
      r = Insights.analyze_growth(%{"mixed_identities" => true}, 500, "connections")

      assert r.level == "unknown"

      assert r.reasons == [
               "usage samples cannot be attributed to one series or source identity — no single volume history"
             ]

      assert r.history == []
    end

    test "storage compatibility: analyze_storage reproduces the growth analysis" do
      storage =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => history(215.0, 0.15, 2.1)
        })

      growth =
        Insights.analyze_growth(
          %{
            "history" =>
              for h <- 23..0//-1 do
                v = 215.0 - 2.1 * min(h, 6) - 0.15 * max(h - 6, 0)
                %{"hours_ago" => h, "value" => v}
              end
          },
          250,
          "GiB"
        )

      assert storage.level == growth.level
      assert_in_delta storage.used_gib, growth.value, 0.001
      assert_in_delta storage.used_percent, growth.percent, 0.001
      assert_in_delta storage.recent_rate, growth.recent_rate, 0.001
      assert_in_delta storage.baseline_rate, growth.baseline_rate, 0.001
      assert storage.abnormal == growth.abnormal
      assert_in_delta storage.hours_to_full, growth.hours_to_full, 0.001
      assert storage.reasons == growth.reasons
    end
  end

  describe "growth-rate robustness" do
    test "least-squares slope dampens a glitchy endpoint" do
      # six samples grow 1 GiB/h; the OLDEST is a 50 GiB scrape glitch
      window = [
        %{"hours_ago" => 6, "used_gib" => 50.0},
        %{"hours_ago" => 5, "used_gib" => 101.0},
        %{"hours_ago" => 4, "used_gib" => 102.0},
        %{"hours_ago" => 3, "used_gib" => 103.0},
        %{"hours_ago" => 2, "used_gib" => 104.0},
        %{"hours_ago" => 1, "used_gib" => 105.0},
        %{"hours_ago" => 0, "used_gib" => 106.0}
      ]

      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => window})

      # endpoint slope would read (106-50)/6 = 9.33; least squares reads 178/28
      assert_in_delta r.recent_rate, 178 / 28, 0.001
      assert r.level == "critical"
    end

    test "a cleanup drop larger than 5% resets the analyzed segment" do
      # grows 1 GiB/h to 150, cleanup drops to 120 at h=6, then 1 GiB/h to 126
      history =
        Enum.map(23..7//-1, fn h -> %{"hours_ago" => h, "used_gib" => 150.0 - (h - 7)} end) ++
          [%{"hours_ago" => 6, "used_gib" => 120.0}] ++
          Enum.map(5..0//-1, fn h -> %{"hours_ago" => h, "used_gib" => 126.0 - h} end)

      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history})

      # only the post-cleanup segment feeds the rates
      assert_in_delta r.recent_rate, 1.0, 0.001
      assert_in_delta r.hours_to_full, 250 - 126, 0.001
      assert r.level == "unknown"
      assert "usage dropped (cleanup/resize) — history reset" in r.reasons
      # the sparkline still shows the full retained history
      assert length(r.history) == 24
    end

    test "a relative drop of exactly 5% does not reset; just over does" do
      base = [%{"hours_ago" => 7, "used_gib" => 100.0}]
      tail = fn used -> Enum.map(6..0//-1, &%{"hours_ago" => &1, "used_gib" => used}) end
      reset_reason = "usage dropped (cleanup/resize) — history reset"

      # 100 -> 95 is exactly a 5% drop in used space: no reset
      exact = Insights.analyze_storage(%{"size_gib" => 250, "history" => base ++ tail.(95.0)})

      refute reset_reason in exact.reasons

      # 100 -> 94.9 is just over 5%: reset
      just_over =
        Insights.analyze_storage(%{"size_gib" => 250, "history" => base ++ tail.(94.9)})

      assert reset_reason in just_over.reasons
    end

    test "cleanup detection is relative to used space, independent of capacity" do
      # a 6% used-space drop on a huge volume: still a cleanup
      history = [
        %{"hours_ago" => 6, "used_gib" => 100.0},
        %{"hours_ago" => 5, "used_gib" => 94.0},
        %{"hours_ago" => 4, "used_gib" => 95.0},
        %{"hours_ago" => 3, "used_gib" => 96.0},
        %{"hours_ago" => 2, "used_gib" => 97.0},
        %{"hours_ago" => 1, "used_gib" => 98.0},
        %{"hours_ago" => 0, "used_gib" => 99.0}
      ]

      reset_reason = "usage dropped (cleanup/resize) — history reset"

      big = Insights.analyze_storage(%{"size_gib" => 1000, "history" => history})
      assert reset_reason in big.reasons
      assert_in_delta big.recent_rate, 1.0, 0.001

      small = Insights.analyze_storage(%{"size_gib" => 200, "history" => history})

      assert reset_reason in small.reasons
      assert_in_delta small.recent_rate, 1.0, 0.001
      assert big.reasons == small.reasons
    end

    test "multiple cleanup drops keep only the segment after the LAST one" do
      history = [
        %{"hours_ago" => 7, "used_gib" => 200.0},
        %{"hours_ago" => 6, "used_gib" => 100.0},
        %{"hours_ago" => 5, "used_gib" => 110.0},
        %{"hours_ago" => 4, "used_gib" => 120.0},
        %{"hours_ago" => 3, "used_gib" => 130.0},
        %{"hours_ago" => 2, "used_gib" => 60.0},
        %{"hours_ago" => 1, "used_gib" => 65.0},
        %{"hours_ago" => 0, "used_gib" => 70.0}
      ]

      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => history})
      reset_reason = "usage dropped (cleanup/resize) — history reset"

      # only h2..h0 (5 GiB/h) feeds the rate; the first segment is ignored
      assert_in_delta r.recent_rate, 5.0, 0.001
      assert reset_reason in r.reasons
      assert length(r.history) == 8
    end

    test "flat series measure an exact zero rate" do
      r = Insights.analyze_storage(%{"size_gib" => 250, "history" => flat(40.0)})

      assert r.recent_rate == 0.0
      assert r.baseline_rate == 0.0
      assert r.level == "ok"
      assert r.reasons == ["growth within normal range"]
    end

    test "sparse two-point windows still measure the exact endpoint rate" do
      r =
        Insights.analyze_storage(%{
          "size_gib" => 250,
          "history" => [
            %{"hours_ago" => 6, "used_gib" => 100.0},
            %{"hours_ago" => 0, "used_gib" => 110.0}
          ]
        })

      assert_in_delta r.recent_rate, 10 / 6, 0.0001
    end
  end

  describe "pipeline_health/1" do
    defp runs(name, results),
      do: Enum.map(results, &%{"service" => name, "result" => &1, "finish_at" => nil})

    test "consecutive failures are critical and sorted first" do
      [first, second] =
        Insights.pipeline_health(
          runs("ok-svc", ~w(succeeded succeeded)) ++ runs("bad-svc", ~w(failed failed succeeded))
        )

      assert first.name == "bad-svc"
      assert first.level == "critical"
      assert first.streak == 2
      assert second.level == "ok"
    end

    test "a single latest failure is a warning" do
      [p] = Insights.pipeline_health(runs("svc", ~w(failed succeeded succeeded)))
      assert p.level == "warning"
    end

    test "flaky alternation boundaries: exactly three changes flag, two do not" do
      # four changes, latest succeeded, one failure per half: no failure clause
      # catches it, so the flaky clause is what keeps it from reading healthy
      alternating =
        ~w(succeeded failed succeeded succeeded succeeded failed succeeded succeeded succeeded succeeded)

      [three] = Insights.pipeline_health(runs("svc", alternating))

      assert three.flaky
      assert three.level == "warning"
      assert three.reason == "flaky: alternating results"

      # two changes only: not flaky, nothing to report
      steady =
        ~w(succeeded failed succeeded succeeded succeeded succeeded succeeded succeeded succeeded succeeded)

      [two] = Insights.pipeline_health(runs("svc", steady))

      refute two.flaky
      assert two.level == "ok"
    end

    test "a flaky pipeline with the latest run succeeded is never healthy" do
      [p] =
        Insights.pipeline_health(
          runs(
            "svc",
            ~w(succeeded failed succeeded succeeded succeeded failed succeeded succeeded succeeded succeeded)
          )
        )

      assert p.flaky
      assert p.level == "warning"
      assert p.reason == "flaky: alternating results"
    end

    test "critical streaks keep priority over flakiness" do
      [p] =
        Insights.pipeline_health(runs("svc", ~w(failed failed succeeded failed succeeded failed)))

      assert p.flaky
      assert p.level == "critical"
      assert p.reason =~ "failed runs in a row"
    end

    test "unfinished runs do not count as result changes" do
      [p] = Insights.pipeline_health(runs("svc", [nil, "failed", "succeeded", nil, "failed"]))

      # f->s and s->nil(skipped), nil->f(skipped): one real change
      refute p.flaky
    end

    test "exactly three result changes flag flaky" do
      # s->f, s->s, s->f... pairs: s-f(1), f-s(2), s-f(3), f-s(4) for four;
      # this list yields exactly three: f-s, s-f, f-s then s-s
      [p] = Insights.pipeline_health(runs("svc", ~w(failed succeeded failed succeeded succeeded)))

      assert p.flaky == false or p.flaky
      # recompute: changes = f-s(1), s-f(2), f-s(3), s-s -> exactly 3
      # but streak 1 + failures 3 -> warning "latest run failed and it has failed before"
      assert p.flaky
      assert p.level == "warning"
    end

    test "unrecognized outcomes never count as result changes" do
      # weird <-> failed pairs would be changes under naive counting
      [p] = Insights.pipeline_health(runs("svc", ["weird", "failed", "weird", "failed", "weird"]))

      refute p.flaky
    end

    test "missing, unrecognized or in-progress latest outcomes never read healthy" do
      [nil_only] = Insights.pipeline_health(runs("svc", [nil]))
      assert nil_only.level == "unknown"
      assert nil_only.reason == "latest run result unknown"

      [nil_latest] = Insights.pipeline_health(runs("svc", [nil, "succeeded"]))
      assert nil_latest.level == "unknown"

      [weird] = Insights.pipeline_health(runs("svc", ["timeoutFlake"]))
      assert weird.level == "unknown"
      assert weird.reason == "latest run result unknown"

      # concrete failure evidence still wins over unknown latest:
      # three of the last five failed (critical), despite the nil newest
      [evidence] =
        Insights.pipeline_health(runs("svc", [nil, "failed", "failed", "failed", "succeeded"]))

      assert evidence.level == "critical"
      assert evidence.reason =~ "of the last 5 runs failed"
    end

    test "a non-completed status is unknown even with a residual result" do
      in_progress_succeeded = %{
        "service" => "svc",
        "status" => "inProgress",
        "result" => "succeeded"
      }

      [p] = Insights.pipeline_health([in_progress_succeeded])
      assert p.level == "unknown"
      assert p.reason == "latest run result unknown"
      assert p.results == ["unknown"]

      # residual failed under in-progress: no false streak, no false failure
      [q] =
        Insights.pipeline_health([
          %{"service" => "svc", "status" => "inProgress", "result" => "failed"},
          %{"service" => "svc", "result" => "succeeded"}
        ])

      assert q.streak == 0
      assert q.failures == 0
      assert q.level == "unknown"

      # historical evidence remains visible beside the uncertain latest
      [r] =
        Insights.pipeline_health([
          %{"service" => "svc", "status" => "inProgress", "result" => "succeeded"},
          %{"service" => "svc", "result" => "failed"},
          %{"service" => "svc", "result" => "failed"},
          %{"service" => "svc", "result" => "failed"},
          %{"service" => "svc", "result" => "succeeded"}
        ])

      assert r.level == "critical"
      assert r.reason =~ "of the last 5 runs failed"

      # a non-completed status never counts as a result change
      [s] =
        Insights.pipeline_health(
          for _ <- 1..5,
              do: %{"service" => "svc", "status" => "inProgress", "result" => "failed"}
        )

      refute s.flaky
      assert s.level == "unknown"
    end

    test "degraded latest outcomes never imply success" do
      [partial] = Insights.pipeline_health(runs("svc", ["partiallySucceeded"]))
      assert partial.level == "warning"
      assert partial.reason == "latest run partiallySucceeded"

      [canceled] = Insights.pipeline_health(runs("svc", ["canceled"]))
      assert canceled.level == "warning"
      assert canceled.reason == "latest run canceled"
    end

    test "duration ratio displays one decimal, not inflated" do
      prev5 =
        for _ <- 1..5,
            do: %{
              "service" => "svc",
              "result" => "succeeded",
              "finish_at" => nil,
              "duration_seconds" => 100
            }

      last5 =
        for _ <- 1..5,
            do: %{
              "service" => "svc",
              "result" => "succeeded",
              "finish_at" => nil,
              "duration_seconds" => 150
            }

      [p] = Insights.pipeline_health(Enum.reverse(last5) ++ prev5)

      assert p.duration_ratio == 1.5
      assert p.reason =~ "run durations up 1.5x"
      assert p.last5_median_seconds == 150
      assert p.prev5_median_seconds == 100
    end

    test "duration trend flags at the 1.5x median boundary" do
      prev5 =
        for _ <- 1..5,
            do: %{
              "service" => "svc",
              "result" => "succeeded",
              "finish_at" => nil,
              "duration_seconds" => 100
            }

      last5_at = fn secs ->
        %{
          "service" => "svc",
          "result" => "succeeded",
          "finish_at" => nil,
          "duration_seconds" => secs
        }
      end

      # median 150 vs 100 is exactly 1.5x: flagged
      last5 = List.duplicate(last5_at.(150), 5)
      [exact] = Insights.pipeline_health(Enum.reverse(last5) ++ prev5)

      assert exact.level == "warning"
      assert exact.reason =~ "run durations up 1.5x"

      # median 149 vs 100 is just under: not flagged
      last5_under = List.duplicate(last5_at.(149), 5)
      [under] = Insights.pipeline_health(Enum.reverse(last5_under) ++ prev5)

      assert under.level == "ok"
      assert under.reason == "no recent failures"
    end

    test "duration trend needs both halves timed and never fabricates medians" do
      timed = fn s ->
        %{
          "service" => "svc",
          "result" => "succeeded",
          "finish_at" => nil,
          "duration_seconds" => s
        }
      end

      untimed = %{"service" => "svc", "result" => "succeeded", "finish_at" => nil}

      # previous five have no durations: no trend, no fabricated slowdown
      last5_timed = List.duplicate(timed.(500), 5)
      [p] = Insights.pipeline_health(Enum.reverse(last5_timed) ++ List.duplicate(untimed, 5))

      assert p.level == "ok"
      assert p.reason == "no recent failures"
    end

    test "a duration slowdown on a failing pipeline surfaces without hiding the failure" do
      timed = fn s, r ->
        %{"service" => "svc", "result" => r, "finish_at" => nil, "duration_seconds" => s}
      end

      prev =
        for _ <- 1..5,
            do: %{
              "service" => "svc",
              "result" => "failed",
              "finish_at" => nil,
              "duration_seconds" => 100
            }

      # latest failed with a slowing 2x median: warning, both facts surfaced
      last5 = [
        timed.(400, "failed"),
        timed.(300, "succeeded"),
        timed.(200, "succeeded"),
        timed.(100, "succeeded"),
        timed.(100, "failed")
      ]

      [p] = Insights.pipeline_health(last5 ++ prev)

      assert p.level == "warning"
      assert p.reason =~ "latest run failed"
      assert p.reason =~ "run durations up"
    end
  end

  test "checks suggest concrete next steps from signals" do
    checks =
      Insights.checks([], [%{"status" => "OOMKilled"}], nil, [], %{"p95_latency_ms" => 2400}, nil)

    assert Enum.any?(checks, &(&1 =~ "OOMKilled"))
    assert Enum.any?(checks, &(&1 =~ "p95 latency"))
  end
end
