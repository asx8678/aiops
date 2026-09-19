defmodule OpsBrainWeb.AuthorizationTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Accounts, TestAdminRepo}
  alias OpsBrain.Tenancy.Membership
  import Ecto.Query

  setup do
    fixture()
  end

  test "HTTP token exchange renews session and logout revokes it", f do
    raw = login_token(f.alice)
    conn = post(f.conn, "/sign-in", %{"login" => %{"token" => raw}})
    assert redirected_to(conn) == "/"
    session = get_session(conn, :operator_token)
    refute session == raw
    assert Accounts.operator_for_session(session).id == f.alice.id
    conn = delete(recycle(conn), "/sign-out")
    assert redirected_to(conn) == "/sign-in"
    assert is_nil(Accounts.operator_for_session(session))
    conn = post(recycle(conn), "/sign-in", %{"login" => %{"token" => raw}})
    assert conn.status == 401
  end

  test "company portfolio and direct source URLs enforce membership", f do
    conn = init_test_session(f.conn, operator_token: f.token_a)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#companies-#{f.a.id}")
    refute has_element?(view, "#companies-#{f.b.id}")
    assert has_element?(view, "#coverage-not-configured")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/companies/#{f.b.id}")
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}/sources/#{f.source_a.id}")
    assert has_element?(view, "#selected-source")

    assert {:error, {:redirect, %{to: path}}} =
             live(conn, "/companies/#{f.a.id}/sources/#{f.source_b.id}")

    assert path == "/companies/#{f.a.id}"
  end

  test "membership revocation is checked on event and reconnect", f do
    conn = init_test_session(f.conn, operator_token: f.token_a)
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}")
    TestAdminRepo.delete_all(from m in Membership, where: m.operator_id == ^f.alice.id)
    render_click(element(view, "#refresh"))
    assert_redirect(view, "/sign-in")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/companies/#{f.a.id}")
  end

  test "navigation cannot change authority to another company or expose guessed source", f do
    conn = init_test_session(f.conn, operator_token: f.token_a)
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}")
    render_patch(view, "/companies/#{f.b.id}")
    assert_redirect(view, "/sign-in")
  end

  test "revoked sessions are checked on events even without company selection", f do
    conn = init_test_session(f.conn, operator_token: f.token_a)
    {:ok, view, _} = live(conn, "/")
    Accounts.revoke_session(f.token_a)
    render_click(element(view, "#refresh"))
    assert_redirect(view, "/sign-in")
  end

  test "missing CSRF blocks login and logout, and tokens are not echoed in failed forms", f do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      f.conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/sign-in", %{"login" => %{"token" => login_token(f.alice)}})
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      f.conn |> put_private(:plug_skip_csrf_protection, false) |> delete("/sign-out")
    end

    raw = login_token(f.alice, DateTime.add(DateTime.utc_now(), -1, :minute))
    conn = post(f.conn, "/sign-in", %{"login" => %{"token" => raw}})
    refute html_response(conn, 401) =~ raw
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "a forged session or source company parameter does not confer access", f do
    conn = init_test_session(f.conn, operator_token: String.duplicate("x", 43))
    assert redirected_to(get(conn, "/companies/#{f.a.id}")) == "/sign-in"
    conn = init_test_session(f.conn, operator_token: f.token_a)
    {:ok, view, _} = live(conn, "/companies/#{f.a.id}")
    render_click(element(view, "#refresh"), %{"company_id" => f.b.id, "id" => f.source_b.id})
    assert has_element?(view, "#sources-#{f.source_a.id}")
    refute has_element?(view, "#sources-#{f.source_b.id}")
  end

  test "vendor scripts are served locally, with no external CDN", %{conn: conn} do
    for path <- [
          "/vendor/phoenix/phoenix.js",
          "/vendor/live_view/phoenix_live_view.js",
          "/vendor/html/phoenix_html.js"
        ] do
      assert get(recycle(conn), path).status == 200
    end
  end
end
