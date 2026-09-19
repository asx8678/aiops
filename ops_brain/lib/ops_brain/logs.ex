defmodule OpsBrain.Logs do
  @moduledoc "Loki fixed-window backend totals and bounded samples. Sample multiplicity is preserved; no total extrapolation."
  alias OpsBrain.{Transport, Store, Redactor}

  def collect(c, start, finish) do
    p = c.profile
    seconds = DateTime.diff(finish, start)

    with true <- p[:reviewed] == true and is_binary(p[:selector]) and seconds in 30..3600,
         {:ok, %{status: 200, body: body}} <-
           Transport.get(c, "/loki/api/v1/query", [
             {"query", "sum(count_over_time(#{p.selector}[#{seconds}s]))"},
             {"time", DateTime.to_unix(finish, :nanosecond) - 1}
           ]),
         {:ok, count} <- decode_count(body) do
      # Sampling is a separate request and may be rate-limited/unavailable without invalidating the backend total.
      {samples, coverage} =
        if count >= (p[:minimum_count] || 10) do
          sample(c, start, finish)
        else
          {[], "not_requested"}
        end

      {:ok,
       %{
         "count" => count,
         "count_basis" => "backend total for fixed window",
         "samples" => samples,
         "sample_coverage" => coverage,
         "profile_version" => p.version,
         "coverage" => "complete",
         "condition" => if(count >= (p[:minimum_count] || 10), do: "watch", else: "normal"),
         "missing" => "Producer severity does not prove impact; fingerprint totals unknown"
       }}
    else
      _ -> {:error, :log_count_unavailable}
    end
  end

  def decode_count(body) do
    with {:ok,
          %{"status" => "success", "data" => %{"resultType" => "vector", "result" => rows}} = r} <-
           Jason.decode(body),
         true <- Map.get(r, "warnings", []) == [],
         true <- length(rows) == 1,
         %{"value" => [_, n]} <- hd(rows),
         {count, ""} <- Float.parse(n),
         true <- count >= 0 and count < 1.0e12 do
      {:ok, count}
    else
      # Empty streams are not evidence of a counted zero.
      _ -> {:error, :missing_or_partial_count}
    end
  end

  defp sample(c, start, finish) do
    case Transport.get(c, "/loki/api/v1/query_range", [
           {"query", c.profile.selector},
           {"start", DateTime.to_unix(start, :nanosecond)},
           {"end", DateTime.to_unix(finish, :nanosecond) - 1},
           {"limit", 200},
           {"direction", "forward"}
         ]) do
      {:ok, %{status: 200, body: body}} ->
        case decode_samples(body) do
          {:ok, entries, status} -> {entries, status}
          _ -> {[], "unavailable"}
        end

      _ ->
        {[], "unavailable_or_budget_limited"}
    end
  end

  def decode_samples(body) do
    with {:ok,
          %{"status" => "success", "data" => %{"resultType" => "streams", "result" => streams}}} <-
           Jason.decode(body),
         true <- is_list(streams) and length(streams) <= 200 do
      rows =
        Enum.flat_map(streams, fn s ->
          Enum.map(s["values"] || [], fn [ts, line] ->
            %{
              "timestamp" => ts,
              "message" => Redactor.clean(line, 160),
              "stream" => Store.digest(s["stream"] || %{})
            }
          end)
        end)

      {:ok, Enum.take(rows, 200),
       if(length(rows) >= 200, do: "capped_or_saturated", else: "bounded_sample")}
    else
      _ -> {:error, :invalid_sample}
    end
  rescue
    _ -> {:error, :invalid_sample}
  end
end
