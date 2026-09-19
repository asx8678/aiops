defmodule OpsBrain.Store do
  @moduledoc false
  alias OpsBrain.Repo

  def rows(sql, params \\ []) do
    r = Repo.query!(sql, params)

    Enum.map(r.rows || [], fn values ->
      Map.new(Enum.zip(r.columns, values), fn {key, value} -> {key, utc(value)} end)
    end)
  end

  defp utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp utc(value), do: value

  def one(sql, params \\ []), do: List.first(rows(sql, params))
  def now, do: Application.get_env(:ops_brain, :clock, &DateTime.utc_now/0).()
  def iso(%DateTime{} = t), do: DateTime.to_iso8601(t)
  def iso(nil), do: nil
  def parse(nil), do: nil

  def parse(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def digest(data),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(data, [:deterministic]))
      |> Base.encode16(case: :lower)
end
