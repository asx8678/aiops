defmodule OpsBrain.KubernetesWatcher do
  @moduledoc "Supervised bounded watch loop; durable window/checkpoint survives process restart."
  use GenServer

  def start_link(id),
    do: GenServer.start_link(__MODULE__, id, name: {:via, Registry, {OpsBrain.WatchRegistry, id}})

  def child_spec(id),
    do: %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [id]}, restart: :transient}

  def init(id) do
    send(self(), :watch)
    {:ok, id}
  end

  def handle_info(:watch, id) do
    case if(Application.get_env(:ops_brain, :collection_enabled, false),
           do: OpsBrain.SourceConfig.fetch(id),
           else: {:error, :disabled}
         ) do
      {:ok, c} ->
        OpsBrain.TelemetryCollection.tick(id)
        Process.send_after(self(), :watch, c.interval_seconds * 1000)
        {:noreply, id}

      _ ->
        {:stop, :normal, id}
    end
  end
end
