defmodule OpsBrain.OIDC.Attempts do
  @moduledoc "Durable single-use state hashes. Consumption commits before any provider HTTP."
  import Ecto.Query
  alias OpsBrain.Repo

  def insert(state, expires_at) do
    now = System.system_time(:second)
    Repo.delete_all(from a in "oidc_attempts", where: a.expires_at <= ^now)

    {1, _} =
      Repo.insert_all("oidc_attempts", [%{state_hash: hash(state), expires_at: expires_at}])

    :ok
  end

  def consume(state, now) do
    digest = hash(state)

    case Repo.delete_all(
           from a in "oidc_attempts", where: a.state_hash == ^digest and a.expires_at > ^now
         ) do
      {1, _} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp hash(state), do: :crypto.hash(:sha256, state)
end
