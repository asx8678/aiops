defmodule OpsBrain.CollectionWorker do
  use Oban.Worker,
    queue: :collect,
    max_attempts: 5,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias OpsBrain.Outcome

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => id}}) do
    if Application.get_env(:ops_brain, :collection_enabled, false) do
      collect(id)
    else
      :discard
    end
  end

  defp collect(id) do
    id
    |> dispatch()
    |> Outcome.normalize()
    |> Outcome.to_oban()
  end

  defp dispatch(id) do
    case OpsBrain.SourceConfig.fetch(id) do
      {:ok, %{kind: "azure_build"}} -> OpsBrain.Collection.tick(id)
      {:ok, _} -> OpsBrain.TelemetryCollection.tick(id)
      _ -> {:error, :source_disabled_or_invalid}
    end
  end
end
