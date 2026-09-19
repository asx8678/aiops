defmodule OpsBrain.CollectionWorker do
  use Oban.Worker,
    queue: :collect,
    max_attempts: 5,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => id}}) do
    if Application.get_env(:ops_brain, :collection_enabled, false) do
      collect(id)
    else
      :discard
    end
  end

  defp collect(id) do
    case OpsBrain.SourceConfig.fetch(id) do
      {:ok, %{kind: "azure_build"}} -> normalize(OpsBrain.Collection.tick(id))
      {:ok, _} -> normalize(OpsBrain.TelemetryCollection.tick(id))
      _ -> :discard
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:snooze, n}), do: {:snooze, n}
  defp normalize(_), do: {:error, :collection_failed}
end
