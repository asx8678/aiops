defmodule OpsBrain.OIDC.TestFixtures do
  def config do
    %{
      issuer: "https://identity.example.test/tenant",
      authorization_endpoint: "https://identity.example.test/authorize",
      token_endpoint: "https://identity.example.test/token",
      jwks_uri: "https://identity.example.test/keys",
      redirect_uri: "https://ops.example.test/auth/oidc/callback",
      reviewed: "true",
      client_id: "synthetic-client",
      auth_method: "none",
      client_secret: nil,
      subjects: %{"approved-subject" => "00000000-0000-4000-8000-000000000001"}
    }
  end

  def keys do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)

    {key,
     %{
       "keys" => [Map.merge(public, %{"kid" => "reviewed-key", "use" => "sig", "alg" => "RS256"})]
     }}
  end

  def token(key, config, nonce, overrides \\ %{}, header \\ %{}) do
    now = Map.get(config, :test_now, System.system_time(:second))

    claims =
      Map.merge(
        %{
          "iss" => config.issuer,
          "aud" => config.client_id,
          "sub" => "approved-subject",
          "iat" => now,
          "exp" => now + 120,
          "nonce" => nonce
        },
        overrides
      )

    {_, token} =
      key
      |> JOSE.JWT.sign(Map.merge(%{"alg" => "RS256", "kid" => "reviewed-key"}, header), claims)
      |> JOSE.JWS.compact()

    token
  end

  def configure(config) do
    previous = Application.get_env(:ops_brain, :oidc)

    refs =
      for {key, value} <- config do
        name = "OPS_BRAIN_TEST_OIDC_" <> String.upcase(Atom.to_string(key))
        old = System.get_env(name)

        ExUnit.Callbacks.on_exit(fn ->
          if old, do: System.put_env(name, old), else: System.delete_env(name)
        end)

        cond do
          is_map(value) -> System.put_env(name, Jason.encode!(value))
          is_binary(value) -> System.put_env(name, value)
          true -> System.delete_env(name)
        end

        {key, name}
      end

    Application.put_env(:ops_brain, :oidc, [enabled: true] ++ refs)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:ops_brain, :oidc, previous),
        else: Application.delete_env(:ops_brain, :oidc)
    end)

    refs
  end
end
