defmodule OpsBrain.OIDC.HTTP do
  @moduledoc "Only the reviewed token POST and JWKS GET; bounded bodies, TLS verification, no redirects/retries."
  alias OpsBrain.OIDC.Config
  @max_bytes 131_072

  def request(config, operation, form \\ [], plug \\ nil) when operation in [:token, :jwks] do
    url = if operation == :token, do: config.token_endpoint, else: config.jwks_uri

    if Config.https_endpoint?(url) do
      options = [
        method: if(operation == :token, do: :post, else: :get),
        url: url,
        headers: [{"accept", "application/json"}, {"accept-encoding", "identity"}],
        connect_options: [timeout: 5_000, transport_opts: [verify: :verify_peer]],
        receive_timeout: 5_000,
        request_timeout: 10_000,
        retry: false,
        redirect: false,
        decode_body: false,
        raw: true,
        compressed: false,
        into: fn {:data, bytes}, {req, resp} ->
          body = (resp.body || "") <> bytes

          if byte_size(body) > @max_bytes do
            {:halt, {req, %{resp | body: "", private: Map.put(resp.private, :oversized, true)}}}
          else
            {:cont, {req, %{resp | body: body}}}
          end
        end
      ]

      options = if operation == :token, do: Keyword.put(options, :form, form), else: options

      # Trusted application-code test seam, consistent with other transports; no env/browser override.
      plug = plug || Application.get_env(:ops_brain, :oidc_http_plug)
      options = if plug, do: Keyword.put(options, :plug, plug), else: options

      with {:ok, response} <- Req.request(options),
           true <- response.status == 200 and response.private[:oversized] != true,
           [] <- Req.Response.get_header(response, "content-encoding"),
           [type] <- Req.Response.get_header(response, "content-type"),
           true <- String.downcase(hd(String.split(type, ";"))) == "application/json",
           body when is_binary(body) and byte_size(body) <= @max_bytes <- response.body,
           {:ok, json} when is_map(json) <- Jason.decode(body) do
        {:ok, json}
      else
        _ -> {:error, :provider_unavailable}
      end
    else
      {:error, :unapproved_endpoint}
    end
  end
end
