defmodule OpsBrain.Lifecycle do
  @moduledoc """
  One pure policy for issue episodes and human review. Persistence and transport
  live elsewhere; this module only decides transitions so every caller agrees.

  Time semantics: `event_time` is the source-observed time, `now` is receipt
  time. Episode membership is derived from event times and explicit closure
  boundaries, never from processing/arrival time. Severity is monotonic within
  an episode: a newer critical cannot be downgraded by older evidence.
  """

  @episode_gap_seconds 3600
  @future_skew_seconds 300

  @statuses ~w(new active locally_acknowledged quiet recovered closed_by_reviewer)
  @review_actions ~w(locally_acknowledged active quiet closed_by_reviewer)

  @transition_targets %{
    "new" => @review_actions,
    "active" => @review_actions,
    "locally_acknowledged" => @review_actions,
    "quiet" => @review_actions,
    "recovered" => ~w(active locally_acknowledged closed_by_reviewer),
    "closed_by_reviewer" => ~w(active)
  }

  @severity_rank %{"unknown" => 0, "normal" => 1, "warning" => 2, "critical" => 3}

  # Unknown/quiet/missing inputs never mean recovery. Persistence additionally
  # requires the same source/service/profile/policy identity and newer event time.
  def capacity_recoverable?(%{condition: "normal", window_end: at}, policy, %DateTime{} = now)
      when is_number(at) and is_map(policy) do
    age = DateTime.to_unix(now) - at
    freshness = Map.get(policy, :freshness_seconds)
    is_number(freshness) and freshness > 0 and age >= 0 and age <= freshness
  end

  def capacity_recoverable?(_, _, _), do: false

  def episode_gap_seconds, do: @episode_gap_seconds
  def statuses, do: @statuses
  def review_actions, do: @review_actions

  def event_time(%DateTime{} = occurred, %DateTime{} = now) do
    if DateTime.diff(occurred, now) > @future_skew_seconds,
      do: {:error, :future_event_time},
      else: occurred
  end

  def event_time(_, %DateTime{} = now), do: now

  def episode_floor(%DateTime{} = event_at), do: DateTime.add(event_at, -@episode_gap_seconds)

  def escalate(current, observed) do
    if rank(observed) > rank(current), do: observed, else: current
  end

  def rank(nil), do: 0
  def rank(severity) when is_binary(severity), do: Map.get(@severity_rank, severity, 0)

  def first_seen(current, event_at), do: Enum.min_by([current, event_at], &DateTime.to_unix/1)
  def last_seen(current, event_at), do: Enum.max_by([current, event_at], &DateTime.to_unix/1)

  def review_status(action) when is_binary(action) do
    if action in @review_actions, do: {:ok, action}, else: {:error, :invalid_transition}
  end

  def review_status(_), do: {:error, :invalid_transition}

  def review_status(current, action) do
    with {:ok, action} <- review_status(action),
         allowed when is_list(allowed) <- Map.get(@transition_targets, current) do
      if action in allowed, do: {:ok, action}, else: {:error, :invalid_transition}
    else
      _ -> {:error, :invalid_transition}
    end
  end
end
