defmodule OpsBrain.Scheduler do
  @moduledoc "Bounded single-deployment scheduling. Company scopes are re-resolved inside workers. Disabled unless explicitly enabled."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    if Application.get_env(:ops_brain, :collection_enabled, false),
      do: Process.send_after(self(), :tick, 1_000)

    if Application.get_env(:ops_brain, :maintenance_enabled, false),
      do: Process.send_after(self(), {:maintenance, 0}, 5_000)

    {:ok, 0}
  end

  def handle_info({:maintenance, offset}, state) do
    if Application.get_env(:ops_brain, :maintenance_enabled, false) do
      # Persist configured policies first, then sweep every durable source with a
      # known policy, including disabled or removed configuration entries.
      OpsBrain.Retention.sync_from_config()
      ids = OpsBrain.Retention.targets() |> Enum.sort()

      for id <- Enum.slice(ids, offset, 20) do
        Oban.insert(OpsBrain.MaintenanceWorker.new(%{source_id: id}))
      end

      Oban.insert(OpsBrain.DirectoryMaintenanceWorker.new(%{}))
      next = if offset + 20 >= length(ids), do: 0, else: offset + 20
      Process.send_after(self(), {:maintenance, next}, 300_000)
    end

    {:noreply, state}
  end

  def handle_info(:tick, offset) do
    # Rotate a bounded inventory rather than enqueue an unbounded source backlog.
    ids = OpsBrain.SourceConfig.all() |> Map.keys() |> Enum.sort()
    chunk = Enum.slice(ids, offset, 20)

    for id <- chunk do
      case OpsBrain.SourceConfig.fetch(id) do
        {:ok, %{kind: "kubernetes"}} ->
          DynamicSupervisor.start_child(
            OpsBrain.WatchSupervisor,
            {OpsBrain.KubernetesWatcher, id}
          )

        {:ok, _} ->
          %{source_id: id}
          |> OpsBrain.CollectionWorker.new(schedule_in: :erlang.phash2(id, 30))
          |> Oban.insert()

        _ ->
          :disabled
      end
    end

    Process.send_after(self(), :tick, 30_000)
    {:noreply, if(offset + 20 >= length(ids), do: 0, else: offset + 20)}
  end
end
