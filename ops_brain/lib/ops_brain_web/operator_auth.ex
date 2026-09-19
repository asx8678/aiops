defmodule OpsBrainWeb.OperatorAuth do
  import Plug.Conn, only: [get_session: 2, halt: 1]
  import Phoenix.LiveView
  import Phoenix.Component
  alias OpsBrain.{Accounts, Tenancy}

  def init(action), do: action

  def call(conn, :fetch) do
    Plug.Conn.assign(
      conn,
      :current_operator,
      Accounts.operator_for_session(get_session(conn, :operator_token))
    )
  end

  def call(conn, :require) do
    if conn.assigns.current_operator,
      do: conn,
      else: conn |> Phoenix.Controller.redirect(to: "/sign-in") |> halt()
  end

  def on_mount(:require, params, session, socket) do
    token = session["operator_token"]

    case access(token, params) do
      {:ok, scope} ->
        socket =
          socket
          |> assign(:session_token, token)
          |> assign(:current_scope, scope)
          |> attach_hook(:authorize_navigation, :handle_params, fn params, _uri, socket ->
            check(socket, params)
          end)
          |> attach_hook(:authorize_event, :handle_event, fn _event, _params, socket ->
            params =
              if socket.assigns.current_scope,
                do: %{"company_id" => socket.assigns.current_scope.company_id},
                else: %{}

            check(socket, params)
          end)

        {:cont, socket}

      _ ->
        {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  defp check(socket, params) do
    case access(socket.assigns.session_token, params) do
      {:ok, scope} -> {:cont, assign(socket, :current_scope, scope)}
      _ -> {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  defp access(token, %{"company_id" => company_id}), do: Tenancy.authorize(token, company_id)

  defp access(token, _) do
    if Accounts.operator_for_session(token), do: {:ok, nil}, else: {:error, :unauthorized}
  end
end
