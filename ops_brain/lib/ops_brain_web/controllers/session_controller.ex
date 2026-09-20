defmodule OpsBrainWeb.SessionController do
  use OpsBrainWeb, :controller
  alias OpsBrain.Accounts

  def new(conn, _params) do
    # Already-authenticated operators (including development auto-login) skip the form.
    if conn.assigns[:current_operator],
      do: redirect(conn, to: "/"),
      else: render(conn, :new, failed: false)
  end

  def create(conn, %{"login" => %{"token" => token}}) do
    case Accounts.exchange_login_token(token) do
      {:ok, session} ->
        Accounts.revoke_session(get_session(conn, :operator_token))

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:operator_token, session)
        |> redirect(to: "/")

      _ ->
        conn |> put_status(:unauthorized) |> render(:new, failed: true)
    end
  end

  def create(conn, _), do: conn |> put_status(:unauthorized) |> render(:new, failed: true)

  def delete(conn, _) do
    Accounts.revoke_session(get_session(conn, :operator_token))
    conn |> configure_session(drop: true) |> redirect(to: "/sign-in")
  end
end
