defmodule OpsBrain.OIDC.TestStore do
  @moduledoc false
  use Agent
  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def insert(state, expires), do: Agent.update(__MODULE__, &Map.put(&1, state, expires))

  def consume(state, now) do
    Agent.get_and_update(__MODULE__, fn entries ->
      {expires, entries} = Map.pop(entries, state)
      result = if is_integer(expires) and expires > now, do: :ok, else: {:error, :unauthorized}
      {result, entries}
    end)
  end
end
