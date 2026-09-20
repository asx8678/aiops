# Run in MIX_ENV=dev with BOTH URLs pointing at the same approved disposable
# ops_brain_test... database, NEVER ops_brain_dev. See docs/LOCAL_DEVELOPMENT.md.
unless Mix.env() == :dev, do: raise("This probe must exercise the actual development build")

Code.require_file("../test/support/admin_repo.ex", __DIR__)
Code.require_file("../test/support/fixtures.ex", __DIR__)

Application.put_env(:ops_brain, OpsBrain.TestAdminRepo,
  url: System.fetch_env!("MIGRATION_DATABASE_URL"),
  pool_size: 1,
  log: false
)

Application.put_env(
  :ops_brain,
  OpsBrainWeb.Endpoint,
  Keyword.put(Application.fetch_env!(:ops_brain, OpsBrainWeb.Endpoint), :server, false)
)

Application.put_env(
  :ops_brain,
  Oban,
  Keyword.put(Application.fetch_env!(:ops_brain, Oban), :testing, :manual)
)

{:ok, _} = Application.ensure_all_started(:ops_brain)
Logger.configure(level: :error)
ExUnit.start()

defmodule OpsBrainWeb.DevAutoLoginCheck do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias OpsBrain.{Accounts, Fixtures, Repo, Tenancy, TestAdminRepo}
  alias OpsBrain.Accounts.Token
  alias OpsBrainWeb.{DevAutoLogin, OperatorAuth}

  setup do
    start_supervised!(TestAdminRepo)
    # clean! checks both live identities and explicit DB approval before writes.
    Fixtures.clean!()
    f = Fixtures.fixture()
    endpoint = Application.fetch_env!(:ops_brain, OpsBrainWeb.Endpoint)
    Application.put_env(:ops_brain, :dev_auto_login, true)
    Application.put_env(:ops_brain, :dev_operator, f.alice.name)
    on_exit(fn -> Application.put_env(:ops_brain, OpsBrainWeb.Endpoint, endpoint) end)
    f
  end

  defp request(method \\ :get, path \\ "/") do
    conn = Plug.Test.conn(method, "http://localhost" <> path) |> Plug.Test.init_test_session(%{})
    %{conn | remote_ip: {127, 0, 0, 1}}
  end

  defp login(conn), do: OperatorAuth.call(conn, :fetch)

  test "cookie-free local request gets an ordinary scoped session, reused on refresh", f do
    assert DevAutoLogin.enabled?()
    count = Repo.aggregate(Token, :count)
    conn = login(request())
    raw = get_session(conn, :operator_token)
    assert conn.assigns.current_operator.id == f.alice.id
    assert Accounts.operator_for_session(raw).id == f.alice.id
    assert conn.private.plug_session_info == :renew
    assert {:ok, scope} = Tenancy.authorize(raw, f.a.id)
    assert {:ok, %{company: company}} = Tenancy.overview(scope)
    assert company.id == f.a.id
    assert {:error, :unauthorized} = Tenancy.authorize(raw, f.b.id)
    assert Repo.aggregate(Token, :count) == count + 1
    assert get_session(login(conn), :operator_token) == raw
    assert Repo.aggregate(Token, :count) == count + 1
  end

  test "configured operator is mandatory, missing or disabled never picks another operator", f do
    count = Repo.aggregate(Token, :count)

    for name <- [nil, "", "missing-local-operator"] do
      Application.put_env(:ops_brain, :dev_operator, name)
      assert is_nil(get_session(login(request()), :operator_token))
    end

    Application.put_env(:ops_brain, :dev_operator, f.alice.name)

    TestAdminRepo.query!("UPDATE operators SET enabled=false WHERE id=$1::text::uuid", [
      f.alice.id
    ])

    assert is_nil(get_session(login(request()), :operator_token))
    assert Repo.aggregate(Token, :count) == count
  end

  defp dev_requests do
    [
      request(),
      %{request() | remote_ip: {10, 1, 2, 3}},
      %{request() | host: "ops.example.test"},
      put_req_header(request(), "forwarded", "for=10.1.2.3"),
      put_req_header(request(), "x-forwarded-for", "10.1.2.3"),
      put_req_header(request(), "x-forwarded-host", "ops.example.test"),
      put_req_header(request(), "sec-fetch-site", "cross-site"),
      %{request() | remote_ip: {10, 1, 2, 3}, host: "ops.example.test"}
      |> put_req_header("x-forwarded-for", "10.1.2.3")
      |> put_req_header("sec-fetch-site", "cross-site")
    ]
  end

  test "cookie-free development requests skip login regardless of peer, host or proxy headers",
       f do
    count = Repo.aggregate(Token, :count)
    requests = dev_requests()

    for conn <- requests do
      conn = login(conn)
      raw = get_session(conn, :operator_token)
      assert conn.assigns.current_operator.id == f.alice.id
      assert Accounts.operator_for_session(raw).id == f.alice.id
      assert {:ok, _scope} = Tenancy.authorize(raw, f.a.id)
      assert {:error, :unauthorized} = Tenancy.authorize(raw, f.b.id)
    end

    assert Repo.aggregate(Token, :count) == count + length(requests)
  end

  test "listener address does not change development auto-login", f do
    endpoint = Application.fetch_env!(:ops_brain, OpsBrainWeb.Endpoint)

    Application.put_env(
      :ops_brain,
      OpsBrainWeb.Endpoint,
      put_in(endpoint, [:http, :ip], {0, 0, 0, 0})
    )

    for conn <- dev_requests() do
      assert login(conn).assigns.current_operator.id == f.alice.id
    end
  end

  test "disabled flag restores normal login for every entry path", _f do
    count = Repo.aggregate(Token, :count)
    Application.put_env(:ops_brain, :dev_auto_login, false)
    refute DevAutoLogin.enabled?()

    for conn <- [request(:get, "/sign-in") | dev_requests()] do
      conn = login(conn)
      assert is_nil(conn.assigns.current_operator)
      assert is_nil(get_session(conn, :operator_token))
    end

    assert Repo.aggregate(Token, :count) == count
  end

  test "only page GETs create sessions; auth callbacks and logout do not", _f do
    for {method, path} <- [
          {:post, "/sign-in"},
          {:delete, "/sign-out"},
          {:get, "/sign-out"},
          {:get, "/auth/oidc/callback"}
        ] do
      assert is_nil(get_session(login(request(method, path)), :operator_token))
    end

    assert is_binary(get_session(login(request(:get, "/sign-in")), :operator_token))
  end

  test "IPv6 loopback works and existing operators are never silently switched", f do
    ipv6 = %{request() | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}, host: "::1"}
    assert login(ipv6).assigns.current_operator.id == f.alice.id
    count = Repo.aggregate(Token, :count)
    conn = request() |> put_session(:operator_token, f.token_b) |> login()
    assert conn.assigns.current_operator.id == f.bob.id
    assert get_session(conn, :operator_token) == f.token_b
    assert Repo.aggregate(Token, :count) == count
  end

  test "membership removal and operator disablement still invalidate local data access", f do
    raw = get_session(login(request()), :operator_token)
    {:ok, scope} = Tenancy.authorize(raw, f.a.id)
    TestAdminRepo.query!("DELETE FROM memberships WHERE operator_id=$1::text::uuid", [f.alice.id])
    assert {:error, :unauthorized} = Tenancy.overview(scope)

    TestAdminRepo.query!("UPDATE operators SET enabled=false WHERE id=$1::text::uuid", [
      f.alice.id
    ])

    assert is_nil(Accounts.operator_for_session(raw))
    assert is_nil(get_session(login(request()), :operator_token))
  end

  test "revoked or expired sessions can reenter locally while normal session validation still fails",
       f do
    Accounts.revoke_session(f.token_a)
    assert is_nil(Accounts.operator_for_session(f.token_a))
    expired = Accounts.issue_token(f.alice.id, "session", DateTime.add(DateTime.utc_now(), -60))

    for previous <- [f.token_a, expired] do
      conn = request() |> put_session(:operator_token, previous) |> login()
      raw = get_session(conn, :operator_token)
      assert raw != previous
      assert Accounts.operator_for_session(raw).id == f.alice.id
    end
  end
end
