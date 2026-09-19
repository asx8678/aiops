Code.require_file("fixture_helper.exs", __DIR__)
Code.require_file("store_helper.exs", __DIR__)

defmodule OpsBrain.OIDC.OfflineTest do
  use ExUnit.Case, async: false
  alias OpsBrain.OIDC
  alias OpsBrain.OIDC.{TestFixtures, TestStore}

  setup do
    start_supervised!(TestStore)
    {key, jwks} = TestFixtures.keys()
    now = System.system_time(:second)
    {:ok, config: Map.put(TestFixtures.config(), :test_now, now), key: key, jwks: jwks, now: now}
  end

  test "authorization uses fresh state, nonce and S256 PKCE and requests only openid", f do
    {:ok, url, attempt} = OIDC.begin(f.config, TestStore, f.now)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert %{uri | query: nil} |> URI.to_string() == f.config.authorization_endpoint
    assert query["scope"] == "openid"
    assert query["response_type"] == "code"
    assert query["response_mode"] == "query"
    assert query["redirect_uri"] == f.config.redirect_uri
    assert query["nonce"] == attempt["nonce"]
    assert query["state"] == attempt["state"]
    assert query["code_challenge_method"] == "S256"

    assert query["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, attempt["verifier"]), padding: false)

    refute url =~ attempt["verifier"]
    {:ok, _, other} = OIDC.begin(f.config, TestStore, f.now)
    for field <- ~w(state nonce verifier), do: refute(attempt[field] == other[field])
  end

  test "real JOSE signatures, issuer/audience/time/nonce and JWKS key metadata are enforced", f do
    nonce = "synthetic-nonce"
    valid = TestFixtures.token(f.key, f.config, nonce)
    assert {:ok, "approved-subject"} = OIDC.verify_id_token(valid, f.jwks, f.config, nonce, f.now)

    for changes <- [
          %{"iss" => "https://evil.test"},
          %{"aud" => "other-client"},
          %{"aud" => [f.config.client_id, "other"]},
          %{"azp" => "other"},
          %{"exp" => f.now},
          %{"exp" => "forever"},
          %{"iat" => f.now + 100},
          %{"nbf" => f.now + 100},
          %{"nbf" => "bad"},
          %{"nonce" => "wrong"},
          %{"sub" => ""},
          %{"sub" => nil}
        ] do
      token = TestFixtures.token(f.key, f.config, nonce, changes)

      assert {:error, :invalid_id_token} =
               OIDC.verify_id_token(token, f.jwks, f.config, nonce, f.now)
    end

    multi =
      TestFixtures.token(f.key, f.config, nonce, %{
        "aud" => [f.config.client_id, "other"],
        "azp" => f.config.client_id
      })

    assert {:ok, _} = OIDC.verify_id_token(multi, f.jwks, f.config, nonce, f.now)
    [public] = f.jwks["keys"]

    for jwks <- [
          %{"keys" => []},
          %{"keys" => [public, public]},
          %{"keys" => [Map.put(public, "kid", "unknown")]},
          %{"keys" => [Map.put(public, "use", "enc")]},
          %{"keys" => [Map.put(public, "alg", "HS256")]},
          %{"keys" => [Map.put(public, "key_ops", ["encrypt"])]},
          %{"keys" => [Map.put(public, "n", "AA")]},
          %{}
        ] do
      assert {:error, :invalid_id_token} =
               OIDC.verify_id_token(valid, jwks, f.config, nonce, f.now)
    end

    {other_key, _} = TestFixtures.keys()
    forged = TestFixtures.token(other_key, f.config, nonce)
    assert {:error, _} = OIDC.verify_id_token(forged, f.jwks, f.config, nonce, f.now)

    for header <- [
          %{"kid" => "unknown"},
          %{"jku" => "https://evil.test/keys"},
          %{"jwk" => public},
          %{"crit" => ["unexpected"]}
        ] do
      token = TestFixtures.token(f.key, f.config, nonce, %{}, header)
      assert {:error, _} = OIDC.verify_id_token(token, f.jwks, f.config, nonce, f.now)
    end

    for token <- [nil, "bad", "e30.e30.", String.duplicate("x", 32_769)] do
      assert {:error, _} = OIDC.verify_id_token(token, f.jwks, f.config, nonce, f.now)
    end

    symmetric = JOSE.JWK.from_oct("synthetic-not-a-real-secret")
    hs = TestFixtures.token(symmetric, f.config, nonce, %{}, %{"alg" => "HS256"})
    assert {:error, _} = OIDC.verify_id_token(hs, f.jwks, f.config, nonce, f.now)
  end

  test "HTTP code contract succeeds once; copied attempt and callback replay never call HTTP",
       f do
    {:ok, _, attempt} = OIDC.begin(f.config, TestStore, f.now)
    token = TestFixtures.token(f.key, f.config, attempt["nonce"])
    parent = self()

    plug = fn conn ->
      send(parent, {:http, conn.method, conn.request_path})
      assert conn.host == "identity.example.test"
      assert conn.scheme == :https
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      case conn.request_path do
        "/token" ->
          assert conn.method == "POST"
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert URI.decode_query(body) == %{
                   "grant_type" => "authorization_code",
                   "code" => "one-code",
                   "client_id" => f.config.client_id,
                   "redirect_uri" => f.config.redirect_uri,
                   "code_verifier" => attempt["verifier"]
                 }

          Req.Test.json(conn, %{
            "id_token" => token,
            "access_token" => "discarded",
            "refresh_token" => "discarded"
          })

        "/keys" ->
          assert conn.method == "GET"
          Req.Test.json(conn, f.jwks)
      end
    end

    params = %{"state" => attempt["state"], "code" => "one-code"}
    options = [store: TestStore, now: f.now, plug: plug]
    assert {:ok, id} = OIDC.finish(f.config, attempt, params, options)
    assert id == f.config.subjects["approved-subject"]
    assert_receive {:http, "POST", "/token"}
    assert_receive {:http, "GET", "/keys"}
    assert {:error, :unauthorized} = OIDC.finish(f.config, attempt, params, options)
    refute_receive {:http, _, _}
  end

  test "bad state, expiry, errors and changed configuration burn the attempt before HTTP", f do
    for kind <- [:state, :expired, :error, :missing_code, :config, :issuer] do
      {:ok, _, attempt} = OIDC.begin(f.config, TestStore, f.now)
      params = %{"state" => attempt["state"], "code" => "code"}

      params =
        case kind do
          :state -> Map.put(params, "state", "wrong")
          :error -> Map.put(params, "error", "access_denied")
          :missing_code -> Map.delete(params, "code")
          :issuer -> Map.put(params, "iss", "https://evil.test")
          _ -> params
        end

      config = if kind == :config, do: %{f.config | client_id: "changed"}, else: f.config
      now = if kind == :expired, do: f.now + 300, else: f.now
      opts = [store: TestStore, now: now, plug: fn _ -> flunk("must not issue HTTP") end]
      assert {:error, :unauthorized} = OIDC.finish(config, attempt, params, opts)

      assert {:error, :unauthorized} =
               OIDC.finish(
                 f.config,
                 attempt,
                 %{"state" => attempt["state"], "code" => "code"},
                 opts
               )
    end

    assert {:error, :unauthorized} = OIDC.finish(f.config, nil, %{}, store: TestStore)
  end

  test "confidential code flow keeps client secret out of authorization URL, JWKS request and logs",
       f do
    config = %{
      f.config
      | auth_method: "client_secret_post",
        client_secret: "synthetic-client-secret"
    }

    {:ok, url, attempt} = OIDC.begin(config, TestStore, f.now)
    refute url =~ config.client_secret
    token = TestFixtures.token(f.key, config, attempt["nonce"])

    plug = fn conn ->
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if conn.request_path == "/token" do
        form = URI.decode_query(body)
        assert form["client_secret"] == config.client_secret
        assert form["code_verifier"] == attempt["verifier"]
        Req.Test.json(conn, %{"id_token" => token})
      else
        assert body == ""
        Req.Test.json(conn, f.jwks)
      end
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} =
                 OIDC.finish(
                   config,
                   attempt,
                   %{"state" => attempt["state"], "code" => "synthetic-code-secret"},
                   store: TestStore,
                   now: f.now,
                   plug: plug
                 )
      end)

    for secret <- [config.client_secret, token, attempt["verifier"], "synthetic-code-secret"],
        do: refute(log =~ secret)
  end

  test "provider failure consumes the attempt and cannot be retried with a copied cookie", f do
    {:ok, _, attempt} = OIDC.begin(f.config, TestStore, f.now)
    params = %{"state" => attempt["state"], "code" => "one-code"}
    parent = self()

    plug = fn conn ->
      send(parent, :exchange)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(503, ~s({"error":"unavailable"}))
    end

    opts = [store: TestStore, now: f.now, plug: plug]
    assert {:error, :unauthorized} = OIDC.finish(f.config, attempt, params, opts)
    assert_receive :exchange
    assert {:error, :unauthorized} = OIDC.finish(f.config, attempt, params, opts)
    refute_receive :exchange
  end

  test "unapproved subjects and ID-token replay with a new nonce are denied", f do
    for kind <- [:unapproved, :nonce_replay] do
      {:ok, _, attempt} = OIDC.begin(f.config, TestStore, f.now)

      changes =
        if kind == :unapproved,
          do: %{"sub" => "unapproved", "email" => "admin@example.test", "groups" => ["admin"]},
          else: %{}

      nonce = if kind == :nonce_replay, do: "previous-flow-nonce", else: attempt["nonce"]
      token = TestFixtures.token(f.key, f.config, nonce, changes)

      plug = fn conn ->
        Req.Test.json(
          conn,
          if(conn.request_path == "/token", do: %{"id_token" => token}, else: f.jwks)
        )
      end

      assert {:error, :unauthorized} =
               OIDC.finish(f.config, attempt, %{"state" => attempt["state"], "code" => "code"},
                 store: TestStore,
                 now: f.now,
                 plug: plug
               )
    end
  end
end
