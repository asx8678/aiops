defmodule OpsBrain.NotificationWorker do
  use Oban.Worker,
    queue: :delivery,
    max_attempts: 3,
    unique: [period: 300, fields: [:args, :worker]]

  def timeout(_job), do: :timer.minutes(5)

  def perform(%Oban.Job{args: %{"source_id" => source, "id" => id}}) do
    case OpsBrain.Notifications.deliver(source, id) do
      {:ok, _} -> :ok
      {:snooze, n} -> {:snooze, n}
      {:error, :delivery_disabled} -> {:snooze, 300}
      {:error, :not_due} -> {:snooze, 60}
      _ -> :discard
    end
  end
end
