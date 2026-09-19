defmodule OpsBrain.OIDC.Config do
  @moduledoc "Fail-closed, environment-referenced configuration for one reviewed OIDC issuer."
  @urls [:issuer, :authorization_endpoint, :token_endpoint, :jwks_uri, :redirect_uri]
  @refs @urls ++ [:client_id, :subjects, :reviewed, :auth_method]

  def load do
    settings = Application.get_env(:ops_brain, :oidc, [])

    if settings[:enabled] == true do
      values = Map.new(@refs, fn key -> {key, env(settings[key])} end)
      secret = env(settings[:client_secret])

      with "true" <- values.reviewed,
           true <- Enum.all?(@urls, &https_endpoint?(values[&1])),
           true <- URI.parse(values.redirect_uri).path == "/auth/oidc/callback",
           true <- text?(values.client_id, 512),
           {:ok, subjects} <- decode_subjects(values.subjects),
           true <- values.auth_method in ["none", "client_secret_post"],
           true <- values.auth_method == "none" or text?(secret, 4096) do
        {:ok, Map.merge(values, %{subjects: subjects, client_secret: secret})}
      else
        _ -> {:error, :unconfigured}
      end
    else
      {:error, :disabled}
    end
  end

  def available?, do: match?({:ok, _}, load())

  def https_endpoint?(url) when is_binary(url) and byte_size(url) <= 2048 do
    uri = URI.parse(url)

    uri.scheme == "https" and is_binary(uri.host) and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, uri.host) and
      uri.port == 443 and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment) and not String.contains?(url, ["%", "\\", "..", " ", "\r", "\n", "\t"]) and
      URI.to_string(uri) == url and
      Regex.match?(~r/\Ahttps:\/\/[a-z0-9.-]+(?:\/[A-Za-z0-9._~\/-]*)?\z/, url)
  end

  def https_endpoint?(_), do: false

  def fingerprint(config) do
    config
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp env(name) when is_binary(name), do: System.get_env(name)
  defp env(_), do: nil

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and
        not String.contains?(value, ["\r", "\n"])

  defp decode_subjects(raw) when is_binary(raw) and byte_size(raw) <= 65_536 do
    with {:ok, subjects} when is_map(subjects) and map_size(subjects) in 1..1000 <-
           Jason.decode(raw),
         true <-
           Enum.all?(subjects, fn {sub, id} ->
             text?(sub, 255) and match?({:ok, _}, Ecto.UUID.cast(id))
           end) do
      {:ok, subjects}
    else
      _ -> :error
    end
  end

  defp decode_subjects(_), do: :error
end
