defmodule OpsBrain.Transport do
  @moduledoc "Bounded HTTPS reads. Fixed approved IPs prevent DNS rebinding; original hostname is verified by TLS. No redirects/retries/decompression."
  def get(c, path, query \\ []) do
    if OpsBrain.Repo.in_transaction?(), do: raise("network inside transaction forbidden")

    with {:ok, ^c} <- OpsBrain.SourceConfig.fetch(c.id),
         {:ok, {:reserved, reservation}} <- OpsBrain.Budgets.reserve(c.id, OpsBrain.Store.now()) do
      response = request(c, path, query)
      OpsBrain.Budgets.finish(c.id, reservation, response, OpsBrain.Store.now())
    else
      _ -> {:error, :source_budget_or_configuration}
    end
  end

  defp request(c, path, query) do
    with :ok <- OpsBrain.SourceConfig.validate(c),
         true <- OpsBrain.OperationPolicy.allowed?(c, path),
         true <-
           String.starts_with?(path, "/") and not String.contains?(path, ["..", "\\", "?", "#"]),
         {:ok, auth} <- credentials(c),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(hd(c.approved_ips))) do
      uri = URI.parse(c.endpoint)
      pinned = %{uri | host: ip |> :inet.ntoa() |> to_string(), path: path}

      headers =
        [{"host", uri.host}, {"accept-encoding", "identity"}, {"accept", "application/json"}] ++
          auth

      headers = if c[:tenant], do: [{"x-scope-orgid", c.tenant} | headers], else: headers

      options = [
        url: URI.to_string(pinned),
        params: query,
        headers: headers,
        connect_options: connection_options(c, uri.host),
        receive_timeout: 10_000,
        request_timeout: 15_000,
        retry: false,
        redirect: false,
        decode_body: false,
        raw: true,
        compressed: false,
        into: fn {:data, bytes}, {req, resp} ->
          body = (resp.body || "") <> bytes

          if byte_size(body) > c.max_bytes do
            {:halt, {req, %{resp | body: "", private: Map.put(resp.private, :oversized, true)}}}
          else
            {:cont, {req, %{resp | body: body}}}
          end
        end
      ]

      # Test seam is supplied by trusted application code, never source payloads.
      options =
        case Application.get_env(:ops_brain, :http_plug) do
          nil -> options
          plug -> Keyword.put(options, :plug, plug)
        end

      case Req.get(options) do
        {:ok, %{private: %{oversized: true}}} ->
          {:error, :response_too_large}

        {:ok, r} ->
          {:ok,
           %{
             status: r.status,
             headers: r.headers,
             body: r.body || "",
             bytes: byte_size(r.body || "")
           }}

        {:error, _} ->
          {:error, :transport_unavailable}
      end
    else
      _ -> {:error, :unapproved_request}
    end
  end

  defp connection_options(c, host) do
    tls =
      if c[:ca_file],
        do: [verify: :verify_peer, cacertfile: c.ca_file],
        else: [verify: :verify_peer]

    [hostname: host, timeout: 5_000, transport_opts: tls]
  end

  defp credentials(%{credential_env: name}) when is_binary(name) do
    case System.get_env(name) do
      nil ->
        {:error, :credentials_unavailable}

      value ->
        if String.contains?(value, ["\r", "\n"]),
          do: {:error, :invalid_credential},
          else: {:ok, [{"authorization", "Bearer " <> value}]}
    end
  end

  defp credentials(%{anonymous_approved: true}), do: {:ok, []}
  defp credentials(_), do: {:error, :credentials_unavailable}

  defp http_date(text) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    case Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, text) do
      [_, d, m, y, h, mi, s] ->
        month = Enum.find_index(months, &(&1 == m))

        if month,
          do:
            {{String.to_integer(y), month + 1, String.to_integer(d)},
             {String.to_integer(h), String.to_integer(mi), String.to_integer(s)}},
          else: :invalid

      _ ->
        :invalid
    end
  end

  def retry_seconds(headers, now) do
    case List.first(Map.get(headers, "retry-after", [])) do
      nil ->
        0

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 ->
            min(n, 86400)

          _ ->
            case http_date(text) do
              {{y, m, d}, {h, mi, s}} ->
                max(
                  0,
                  min(
                    86400,
                    DateTime.diff(
                      DateTime.from_naive!(NaiveDateTime.new!(y, m, d, h, mi, s), "Etc/UTC"),
                      now
                    )
                  )
                )

              _ ->
                60
            end
        end
    end
  rescue
    _ -> 60
  end
end
