defmodule OpsBrainWeb.OIDCController do
  use OpsBrainWeb, :controller
  alias OpsBrain.{Accounts, OIDC}
  alias OpsBrain.OIDC.Config
  @cookie "__Host-ops_brain_oidc"
  @cookie_options [secure: true, http_only: true, same_site: "Lax", path: "/"]

  def start(conn, _params) do
    with {:ok, config} <- Config.load(),
         true <- origin_matches?(conn, config),
         {:ok, url, attempt} <- OIDC.begin(config) do
      attempt = Map.put(attempt, "previous_session", get_session(conn, :operator_token))

      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_cookie(@cookie, attempt, @cookie_options ++ [encrypt: true, max_age: 300])
      |> redirect(external: url)
    else
      _ -> deny(conn)
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@cookie])
    attempt = conn.cookies[@cookie]
    conn = delete_resp_cookie(conn, @cookie, @cookie_options)

    with {:ok, config} <- Config.load(),
         true <- origin_matches?(conn, config),
         {:ok, operator_id} <- OIDC.finish(config, attempt, params),
         {:ok, session} <- Accounts.issue_oidc_session(operator_id) do
      Accounts.revoke_session(attempt["previous_session"])
      Accounts.revoke_session(get_session(conn, :operator_token))

      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:operator_token, session)
      # End the cross-site redirect chain before navigating with the Strict session cookie.
      |> render(:complete)
    else
      _ -> deny(conn)
    end
  end

  defp origin_matches?(conn, config) do
    uri = URI.parse(config.redirect_uri)
    conn.scheme == :https and conn.host == uri.host and conn.port == uri.port
  end

  defp deny(conn) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_status(:unauthorized)
    |> text("OIDC sign-in unavailable or invalid. Use the token sign-in page.")
  end
end
