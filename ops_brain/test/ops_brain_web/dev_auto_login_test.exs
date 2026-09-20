defmodule OpsBrainWeb.DevAutoLoginTest do
  use OpsBrainWeb.ConnCase, async: false
  alias OpsBrain.{Repo, Accounts}
  alias OpsBrain.Accounts.Token
  alias OpsBrainWeb.{DevAutoLogin, OperatorAuth, UI}

  setup do
    f = fixture()
    old = Application.get_env(:ops_brain, :dev_auto_login)
    operator = Application.get_env(:ops_brain, :dev_operator)

    on_exit(fn ->
      Application.put_env(:ops_brain, :dev_auto_login, old)
      Application.put_env(:ops_brain, :dev_operator, operator)
    end)

    Application.put_env(:ops_brain, :dev_auto_login, true)
    Application.put_env(:ops_brain, :dev_operator, f.alice.name)
    f
  end

  test "test build cannot enable automatic login even with the runtime flag set", _f do
    refute DevAutoLogin.enabled?()
    refute UI.dev_auto_login?()
    count = Repo.aggregate(Token, :count)
    conn = Plug.Test.conn(:get, "http://localhost/") |> init_test_session(%{})
    conn = OperatorAuth.call(conn, :fetch)
    assert is_nil(conn.assigns.current_operator)
    assert is_nil(get_session(conn, :operator_token))
    assert Repo.aggregate(Token, :count) == count
    assert redirected_to(get(build_conn(), "/")) == "/sign-in"
  end

  test "regular authenticated sessions and logout remain available", f do
    conn = init_test_session(build_conn(), operator_token: f.token_a)
    assert redirected_to(get(conn, "/sign-in")) == "/"
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#sign-out")
    refute has_element?(view, "#dev-auto-login")
    assert redirected_to(delete(conn, "/sign-out")) == "/sign-in"
    assert is_nil(Accounts.operator_for_session(f.token_a))
  end
end
