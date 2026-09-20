defmodule OpsBrain.LifecycleTest do
  use ExUnit.Case, async: true
  alias OpsBrain.Lifecycle

  test "severity escalates and never downgrades within an episode" do
    assert Lifecycle.escalate("warning", "critical") == "critical"
    assert Lifecycle.escalate("critical", "warning") == "critical"
    assert Lifecycle.escalate("warning", "warning") == "warning"
    assert Lifecycle.escalate(nil, "warning") == "warning"
  end

  test "event time rejects implausible future evidence rather than fabricating receipt time" do
    now = ~U[2026-09-20 12:00:00Z]
    assert Lifecycle.event_time(DateTime.add(now, 60), now) == DateTime.add(now, 60)
    assert Lifecycle.event_time(DateTime.add(now, 5000), now) == {:error, :future_event_time}
    assert Lifecycle.event_time(nil, now) == now
  end

  test "episode floor and min/max helpers use event time" do
    at = ~U[2026-09-20 08:02:00Z]
    assert Lifecycle.episode_floor(at) == DateTime.add(at, -Lifecycle.episode_gap_seconds())
    assert Lifecycle.first_seen(at, DateTime.add(at, -60)) == DateTime.add(at, -60)
    assert Lifecycle.last_seen(at, DateTime.add(at, -60)) == at
  end

  test "review transitions are explicit" do
    assert {:ok, "locally_acknowledged"} = Lifecycle.review_status("locally_acknowledged")
    assert {:error, :invalid_transition} = Lifecycle.review_status("delete_everything")
    assert {:ok, "active"} = Lifecycle.review_status("new", "active")
    assert {:error, :invalid_transition} = Lifecycle.review_status("closed_by_reviewer", "quiet")
  end
end
