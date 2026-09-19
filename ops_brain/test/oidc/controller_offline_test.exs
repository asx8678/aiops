Code.require_file("fixture_helper.exs", __DIR__)

defmodule OpsBrainWeb.OIDCControllerOfflineTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.LiveViewTest
  alias OpsBrain.OIDC.TestFixtures
  alias OpsBrainWeb.OIDCController

  setup do
    unless Process.whereis(OpsBrain.PubSub),
      do: start_supervised!({Phoenix.PubSub, name: OpsBrain.PubSub})

    unless Process.whereis(OpsBrainWeb.Endpoint),
      do: start_supervised!({OpsBrainWeb.Endpoint, server: false})

    :ok
  end

  defp conn do
    Plug.Test.conn(:get, "https://ops.example.test/auth/oidc/callback")
    |> Map.put(:secret_key_base, String.duplicate("synthetic-test-key-", 8))
    |> Plug.Test.init_test_session(%{})
  end

  test "disabled/missing configuration preserves token form and hides OIDC; controller denies without HTTP/DB" do
    TestFixtures.configure(TestFixtures.config())
    Application.put_env(:ops_brain, :oidc, enabled: false)
    html = render_component(&OpsBrainWeb.SessionHTML.new/1, flash: %{}, failed: false)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#sign-in-form input[type=password]") |> LazyHTML.to_tree() !=
             []

    assert LazyHTML.query(document, "#oidc-sign-in") |> LazyHTML.to_tree() == []
    assert OIDCController.start(conn(), %{}).status == 401
    denied = OIDCController.callback(conn(), %{"code" => "never-echo-this", "state" => "forged"})
    assert denied.status == 401
    refute denied.resp_body =~ "never-echo-this"
    assert get_resp_header(denied, "referrer-policy") == ["no-referrer"]
    assert denied.resp_cookies["__Host-ops_brain_oidc"].max_age == 0
  end

  test "enabled form is POST with CSRF and callback requires a bound encrypted cookie" do
    TestFixtures.configure(TestFixtures.config())
    html = render_component(&OpsBrainWeb.SessionHTML.new/1, flash: %{}, failed: false)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#oidc-sign-in-form[method=post][action='/auth/oidc'] input[name=_csrf_token]"
           )
           |> LazyHTML.to_tree() != []

    assert OIDCController.callback(conn(), %{"code" => "code", "state" => "state"}).status == 401
    wrong_origin = %{conn() | host: "evil.example.test"}
    assert OIDCController.start(wrong_origin, %{}).status == 401
    assert OIDCController.start(%{conn() | scheme: :http}, %{}).status == 401
    forged = conn() |> put_req_header("cookie", "__Host-ops_brain_oidc=forged")
    assert OIDCController.callback(forged, %{}).status == 401
  end

  test "callback parameters are filtered from Phoenix logs and not reflected in HTML or headers" do
    TestFixtures.configure(TestFixtures.config())

    secrets = %{
      "code" => "secret-code-marker",
      "state" => "secret-state-marker",
      "nonce" => "secret-nonce-marker",
      "id_token" => "secret-token-marker",
      "client_secret" => "secret-client-marker",
      "error_description" => "secret-provider-marker"
    }

    filtered = Phoenix.Logger.filter_values(secrets)
    assert Enum.all?(Map.values(filtered), &(&1 == "[FILTERED]"))

    raw =
      Plug.Test.conn(:get, "https://ops.example.test/auth/oidc/callback", secrets)
      |> Map.put(:secret_key_base, String.duplicate("synthetic-test-key-", 8))
      |> put_private(:phoenix_endpoint, OpsBrainWeb.Endpoint)
      |> Plug.Test.init_test_session(%{})

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        result = OpsBrainWeb.Router.call(raw, OpsBrainWeb.Router.init([]))
        assert result.status == 401
        assert get_resp_header(result, "cache-control") == ["no-store"]

        for secret <- Map.values(secrets) do
          refute result.resp_body =~ secret
          refute inspect(result.resp_headers) =~ secret
        end
      end)

    for secret <- Map.values(secrets), do: refute(log =~ secret)
  end

  test "registered routes retain token sign-in and protect OIDC initiation in browser pipeline" do
    raw =
      Plug.Test.conn(:post, "https://ops.example.test/auth/oidc")
      |> Map.put(:secret_key_base, String.duplicate("synthetic-test-key-", 8))
      |> put_private(:phoenix_endpoint, OpsBrainWeb.Endpoint)
      |> Plug.Test.init_test_session(%{})

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        OpsBrainWeb.Router.call(raw, OpsBrainWeb.Router.init([]))
      end

    assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = error.reason
    routes = OpsBrainWeb.Router.__routes__()

    assert Enum.any?(
             routes,
             &(&1.verb == :post and &1.path == "/auth/oidc" and &1.plug == OIDCController and
                 &1.plug_opts == :start)
           )

    assert Enum.any?(
             routes,
             &(&1.verb == :get and &1.path == "/auth/oidc/callback" and &1.plug_opts == :callback)
           )

    assert Enum.any?(
             routes,
             &(&1.verb == :post and &1.path == "/sign-in" and
                 &1.plug == OpsBrainWeb.SessionController)
           )
  end
end
