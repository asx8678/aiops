defmodule OpsBrain.OIDC do
  @moduledoc "Optional OIDC code flow. Provider claims identify an operator; they never grant membership."
  alias OpsBrain.OIDC.{Attempts, Config, HTTP}
  @ttl 300

  def begin(config, store \\ Attempts, now \\ System.system_time(:second)) do
    attempt = %{
      "state" => random(),
      "nonce" => random(),
      "verifier" => random(),
      "expires_at" => now + @ttl,
      "config" => Config.fingerprint(config)
    }

    with :ok <- store.insert(attempt["state"], attempt["expires_at"]) do
      query =
        URI.encode_query(%{
          "response_type" => "code",
          "response_mode" => "query",
          "scope" => "openid",
          "client_id" => config.client_id,
          "redirect_uri" => config.redirect_uri,
          "state" => attempt["state"],
          "nonce" => attempt["nonce"],
          "code_challenge" => challenge(attempt["verifier"]),
          "code_challenge_method" => "S256"
        })

      {:ok, config.authorization_endpoint <> "?" <> query, attempt}
    end
  end

  def finish(config, attempt, params, options \\ []) do
    now = Keyword.get(options, :now, System.system_time(:second))
    store = Keyword.get(options, :store, Attempts)
    plug = Keyword.get(options, :plug)

    # Consume the durable attempt before interpreting the provider response or doing HTTP.
    # Even an old, valid encrypted cookie cannot revive a consumed authorization.
    with %{
           "state" => state,
           "nonce" => nonce,
           "verifier" => verifier,
           "expires_at" => expires,
           "config" => fingerprint
         } <- attempt,
         true <- valid_random?(state) and valid_random?(nonce) and valid_random?(verifier),
         :ok <- store.consume(state, now),
         true <- is_integer(expires) and expires > now and expires <= now + @ttl,
         true <- fingerprint == Config.fingerprint(config),
         %{"state" => returned_state, "code" => code} <- params,
         true <- is_binary(returned_state) and Plug.Crypto.secure_compare(state, returned_state),
         true <-
           is_binary(code) and byte_size(code) in 1..4096 and not Map.has_key?(params, "error"),
         true <- not Map.has_key?(params, "iss") or params["iss"] == config.issuer,
         {:ok, %{"id_token" => token}} <-
           HTTP.request(config, :token, token_form(config, code, verifier), plug),
         {:ok, jwks} <- HTTP.request(config, :jwks, [], plug),
         {:ok, subject} <- verify_id_token(token, jwks, config, nonce, now),
         operator_id when is_binary(operator_id) <- Map.get(config.subjects, subject) do
      {:ok, operator_id}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_id_token(token, %{"keys" => keys}, config, nonce, now)
      when is_binary(token) and byte_size(token) <= 32_768 and is_list(keys) and
             length(keys) in 1..32 do
    with {:ok, header} <- token |> JOSE.JWS.peek_protected() |> Jason.decode(),
         %{"alg" => "RS256", "kid" => kid} when is_binary(kid) and byte_size(kid) in 1..255 <-
           header,
         true <- not Enum.any?(~w(crit jku jwk x5u b64), &Map.has_key?(header, &1)),
         [key] <- Enum.filter(keys, &(is_map(&1) and &1["kid"] == kid)),
         true <- signing_key?(key),
         {true, %JOSE.JWT{fields: claims}, _} <-
           JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         true <- claims["iss"] == config.issuer,
         true <- audience?(claims, config.client_id),
         exp when is_integer(exp) and exp > now <- claims["exp"],
         iat when is_integer(iat) and iat <= now and iat < exp <- claims["iat"],
         true <-
           not Map.has_key?(claims, "nbf") or (is_integer(claims["nbf"]) and claims["nbf"] <= now),
         claimed_nonce when is_binary(claimed_nonce) <- claims["nonce"],
         true <- Plug.Crypto.secure_compare(nonce, claimed_nonce),
         sub when is_binary(sub) and byte_size(sub) in 1..255 <- claims["sub"] do
      {:ok, sub}
    else
      _ -> {:error, :invalid_id_token}
    end
  rescue
    _ -> {:error, :invalid_id_token}
  catch
    _, _ -> {:error, :invalid_id_token}
  end

  def verify_id_token(_, _, _, _, _), do: {:error, :invalid_id_token}

  defp signing_key?(key) do
    with "RSA" <- key["kty"],
         true <- Map.get(key, "use", "sig") == "sig",
         true <- Map.get(key, "alg", "RS256") == "RS256",
         true <- Map.get(key, "key_ops", ["verify"]) == ["verify"],
         false <- Map.has_key?(key, "d"),
         {:ok, modulus} <- Base.url_decode64(key["n"], padding: false),
         true <- byte_size(modulus) in 256..1024,
         {:ok, exponent} <- Base.url_decode64(key["e"], padding: false),
         true <- byte_size(exponent) in 1..8 do
      true
    else
      _ -> false
    end
  end

  defp audience?(claims, client_id) do
    aud = claims["aud"]
    authorized_party = claims["azp"]

    cond do
      aud == client_id ->
        is_nil(authorized_party) or authorized_party == client_id

      is_list(aud) and aud != [] ->
        Enum.all?(aud, &is_binary/1) and client_id in aud and
          (authorized_party == client_id or (length(aud) == 1 and is_nil(authorized_party)))

      true ->
        false
    end
  end

  defp token_form(config, code, verifier) do
    form = [
      grant_type: "authorization_code",
      code: code,
      client_id: config.client_id,
      redirect_uri: config.redirect_uri,
      code_verifier: verifier
    ]

    if config.auth_method == "client_secret_post",
      do: form ++ [client_secret: config.client_secret],
      else: form
  end

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp valid_random?(value), do: is_binary(value) and byte_size(value) == 43

  defp challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
end
