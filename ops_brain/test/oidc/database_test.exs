Code.require_file("fixture_helper.exs", __DIR__)

defmodule OpsBrain.OIDC.DatabaseTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Accounts, Repo, Tenancy, TestAdminRepo}
  alias OpsBrain.Accounts.Operator
  alias OpsBrain.OIDC.{Attempts, TestFixtures}
  import Ecto.Query

  setup do
    TestAdminRepo.query!("DELETE FROM oidc_attempts")
    previous = Application.get_env(:ops_brain, :oidc_http_plug)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ops_brain, :oidc_http_plug, previous),
        else: Application.delete_env(:ops_brain, :oidc_http_plug)
    end)

    fixture()
  end

  test "durable unique hashes and atomic consumption reject replay across callers and expiry" do
    now = System.system_time(:second)
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert :ok = Attempts.insert(state, now + 300)
    %{rows: [[stored]]} = Repo.query!("SELECT state_hash FROM oidc_attempts")
    assert stored == :crypto.hash(:sha256, state)
    refute stored == state
    assert_raise Postgrex.Error, fn -> Attempts.insert(state, now + 300) end
    tasks = for _ <- 1..4, do: Task.async(fn -> Attempts.consume(state, now) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :unauthorized})) == 3
    assert :ok = Attempts.insert(state, now)
    assert {:error, :unauthorized} = Attempts.consume(state, now)
  end

  test "preapproved local operators get only existing membership; disabled/missing operators fail",
       f do
    count = Repo.aggregate(OpsBrain.Tenancy.Membership, :count)
    assert {:ok, session} = Accounts.issue_oidc_session(f.alice.id)
    assert Accounts.operator_for_session(session).id == f.alice.id
    assert {:ok, _} = Tenancy.authorize(session, f.a.id)
    assert {:error, _} = Tenancy.authorize(session, f.b.id)
    assert Repo.aggregate(OpsBrain.Tenancy.Membership, :count) == count
    assert {:error, :unauthorized} = Accounts.issue_oidc_session(Ecto.UUID.generate())
    assert {:error, :unauthorized} = Accounts.issue_oidc_session("bad")

    TestAdminRepo.update_all(from(o in Operator, where: o.id == ^f.alice.id),
      set: [enabled: false]
    )

    assert {:error, :unauthorized} = Accounts.issue_oidc_session(f.alice.id)
    assert is_nil(Accounts.operator_for_session(session))
  end

  test "browser code flow rotates session, consumes encrypted Lax cookie, and denies copied-cookie replay",
       f do
    config = %{TestFixtures.config() | subjects: %{"approved-subject" => f.alice.id}}
    TestFixtures.configure(config)
    {:ok, config} = OpsBrain.OIDC.Config.load()
    {key, jwks} = TestFixtures.keys()

    start =
      f.conn
      |> init_test_session(operator_token: f.token_a)
      |> post("https://ops.example.test/auth/oidc")

    assert start.status == 302
    assert get_resp_header(start, "cache-control") == ["no-store"]
    cookie = start.resp_cookies["__Host-ops_brain_oidc"]
    assert cookie.secure and cookie.http_only and cookie.same_site == "Lax" and cookie.path == "/"
    assert cookie.max_age == 300

    {:ok, attempt} =
      Plug.Crypto.decrypt(
        OpsBrainWeb.Endpoint.config(:secret_key_base),
        "__Host-ops_brain_oidc_cookie",
        cookie.value
      )

    refute cookie.value =~ attempt["verifier"]
    query = URI.decode_query(URI.parse(redirected_to(start)).query)
    assert query["state"] == attempt["state"]
    token = TestFixtures.token(key, config, attempt["nonce"])
    parent = self()

    Application.put_env(:ops_brain, :oidc_http_plug, fn conn ->
      send(parent, {:http, conn.request_path})

      Req.Test.json(
        conn,
        if(conn.request_path == "/token", do: %{"id_token" => token}, else: jwks)
      )
    end)

    # Only the OIDC cookie returns from the IdP; the ordinary session is SameSite=Strict.
    callback_conn =
      build_conn() |> put_req_header("cookie", "__Host-ops_brain_oidc=" <> cookie.value)

    params = %{"state" => attempt["state"], "code" => "synthetic-code"}
    callback = get(callback_conn, "https://ops.example.test/auth/oidc/callback", params)
    assert callback.status == 200

    assert callback
           |> html_response(200)
           |> LazyHTML.from_document()
           |> LazyHTML.query("#oidc-continue[href='/']")
           |> LazyHTML.to_tree() != []

    session = get_session(callback, :operator_token)
    assert Accounts.operator_for_session(session).id == f.alice.id
    refute session == f.token_a
    assert is_nil(Accounts.operator_for_session(f.token_a))
    assert callback.resp_cookies["__Host-ops_brain_oidc"].max_age == 0
    assert_receive {:http, "/token"}
    assert_receive {:http, "/keys"}
    replay = get(callback_conn, "https://ops.example.test/auth/oidc/callback", params)
    assert replay.status == 401
    refute_receive {:http, _}
    assert get_session(replay, :operator_token) == nil
    logout = delete(recycle(callback), "/sign-out")
    assert redirected_to(logout) == "/sign-in"
    assert is_nil(Accounts.operator_for_session(session))
  end
end
