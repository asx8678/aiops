defmodule OpsBrainWeb.DevAutoLogin do
  @moduledoc "Development convenience: skip login for an explicitly named, existing local operator."
  @dev_build Mix.env() == :dev

  def init(opts), do: opts

  def enabled? do
    @dev_build and Application.get_env(:ops_brain, :dev_auto_login, false) == true
  end

  # Issuance is not compiled into test or production builds. Runtime flags alone
  # cannot activate it there. Normal revocable sessions and tenant RLS stay intact.
  if @dev_build do
    import Plug.Conn
    import Ecto.Query
    require Logger
    alias OpsBrain.{Accounts, Repo}
    alias OpsBrain.Accounts.Operator

    def call(conn, _opts) do
      if enabled?() and page_request?(conn) and
           is_nil(Accounts.operator_for_session(get_session(conn, :operator_token))) do
        case issue_session() do
          {:ok, session} ->
            Accounts.revoke_session(get_session(conn, :operator_token))

            Logger.warning(
              "Constellation local development mode: login skipped for configured operator."
            )

            conn
            |> configure_session(renew: true)
            |> clear_session()
            |> put_session(:operator_token, session)

          _ ->
            conn
        end
      else
        conn
      end
    end

    # Owner request: no login in local development, regardless of host or how the
    # page is reached. Issuance stays compile-gated to :dev and flag-gated at runtime;
    # normal revocable sessions and tenant RLS are unchanged.
    defp page_request?(conn) do
      conn.method == "GET" and conn.path_info not in [["sign-out"]] and
        not match?(["auth" | _], conn.path_info)
    end

    defp issue_session do
      name = Application.get_env(:ops_brain, :dev_operator)

      if is_binary(name) and byte_size(name) in 1..100 do
        Repo.transaction(fn ->
          case Repo.one(from o in Operator, where: o.name == ^name and o.enabled) do
            %Operator{id: id} ->
              Accounts.issue_token(id, "session", DateTime.add(DateTime.utc_now(), 8, :hour))

            _ ->
              Repo.rollback(:operator_unavailable)
          end
        end)
      else
        {:error, :operator_not_configured}
      end
    end
  else
    def call(conn, _opts), do: conn
  end
end
