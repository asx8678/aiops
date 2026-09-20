defmodule OpsBrain.MaintenanceWorker do
  @moduledoc "Source-local retention worker. Scheduler/queue registration is an integration concern."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => id} = args}) when map_size(args) == 1 do
    if Application.get_env(:ops_brain, :maintenance_enabled, false), do: sweep(id), else: :discard
  end

  def perform(_), do: :discard

  defp sweep(id) do
    case OpsBrain.Retention.sweep(id) do
      {:ok, %{status: :deferred_live_work}} -> {:snooze, 60}
      {:ok, %{status: :policy_unknown}} -> :ok
      {:ok, %{more?: true}} -> {:snooze, 5}
      {:ok, %{status: :ok}} -> :ok
      {:error, :source_disabled_or_invalid} -> :discard
      {:error, :source_not_found} -> :discard
      {:error, reason} -> {:error, reason}
    end
  end
end
