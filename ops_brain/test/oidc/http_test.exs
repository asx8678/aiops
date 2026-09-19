Code.require_file("fixture_helper.exs", __DIR__)

defmodule OpsBrain.OIDC.HTTPTest do
  use ExUnit.Case, async: true
  alias OpsBrain.OIDC.{HTTP, TestFixtures}

  test "both HTTP operations refuse redirects, unexpected status/type, malformed and oversized bodies" do
    parent = self()

    for operation <- [:token, :jwks],
        response <- [:redirect, :server_error, :html, :json, :array, :oversized, :compressed] do
      plug = fn conn ->
        send(parent, :request)

        case response do
          :redirect ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://evil.test/steal")
            |> Plug.Conn.send_resp(302, "")

          :server_error ->
            Plug.Conn.send_resp(conn, 503, "failure")

          :html ->
            conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "{}")

          :json ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "not-json")

          :array ->
            Req.Test.json(conn, [])

          :oversized ->
            Req.Test.json(conn, %{"too_big" => String.duplicate("x", 131_073)})

          :compressed ->
            conn |> Plug.Conn.put_resp_header("content-encoding", "gzip") |> Req.Test.json(%{})
        end
      end

      assert {:error, :provider_unavailable} =
               HTTP.request(TestFixtures.config(), operation, [code: "synthetic-code"], plug)

      assert_receive :request
      refute_receive :request
    end
  end

  test "confidential exchange sends secrets only in token POST body and never logs responses or credentials" do
    config = %{
      TestFixtures.config()
      | auth_method: "client_secret_post",
        client_secret: "synthetic-client-secret"
    }

    secrets = [
      config.client_secret,
      "synthetic-code-secret",
      "synthetic-verifier-secret",
      "synthetic-provider-error-secret"
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        plug = fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == []
          assert conn.query_string == ""
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          if conn.method == "POST" do
            form = URI.decode_query(body)
            assert form["client_secret"] == config.client_secret
            assert form["code"] == "synthetic-code-secret"
          else
            assert body == ""
          end

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, ~s({"error_description":"synthetic-provider-error-secret"}))
        end

        assert {:error, :provider_unavailable} =
                 HTTP.request(
                   config,
                   :token,
                   [
                     client_secret: config.client_secret,
                     code: "synthetic-code-secret",
                     code_verifier: "synthetic-verifier-secret"
                   ],
                   plug
                 )

        assert {:error, :provider_unavailable} = HTTP.request(config, :jwks, [], plug)
      end)

    for secret <- secrets, do: refute(log =~ secret)
  end

  test "invalid endpoints fail before HTTP, and timeout errors are sanitized" do
    for endpoint <- [
          "http://identity.example.test/token",
          "https://identity.example.test/token?next=evil",
          "https://user:pass@identity.example.test/token"
        ] do
      config = %{TestFixtures.config() | token_endpoint: endpoint}

      assert {:error, :unapproved_endpoint} =
               HTTP.request(config, :token, [], fn _ -> flunk("egress denied") end)
    end

    plug = fn conn -> Req.Test.transport_error(conn, :timeout) end
    assert {:error, :provider_unavailable} = HTTP.request(TestFixtures.config(), :jwks, [], plug)
  end
end
