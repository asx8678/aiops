defmodule OpsBrain.Accounts do
  @moduledoc "Revocable operator sessions. Login capabilities are issued offline, never by public registration."
  import Ecto.Query
  alias OpsBrain.Repo
  alias OpsBrain.Accounts.{Operator, Token}

  def exchange_login_token(raw, now \\ DateTime.utc_now()) do
    with {:ok, hash} <- token_hash(raw) do
      Repo.transaction(fn ->
        query =
          from t in Token,
            join: o in Operator,
            on: o.id == t.operator_id,
            where:
              t.token_hash == ^hash and t.context == "login" and t.expires_at > ^now and o.enabled,
            select: t.operator_id

        case Repo.delete_all(query) do
          {1, [operator_id]} -> issue_token(operator_id, "session", DateTime.add(now, 8, :hour))
          _ -> Repo.rollback(:unauthorized)
        end
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def operator_for_session(raw, now \\ DateTime.utc_now()) do
    with {:ok, hash} <- token_hash(raw) do
      Repo.one(
        from o in Operator,
          join: t in Token,
          on: t.operator_id == o.id,
          where:
            t.token_hash == ^hash and t.context == "session" and t.expires_at > ^now and o.enabled,
          select: o
      )
    else
      _ -> nil
    end
  end

  @doc "Issues a normal revocable session for an existing, enabled, preapproved OIDC operator."
  def issue_oidc_session(operator_id, now \\ DateTime.utc_now()) do
    with {:ok, id} <- Ecto.UUID.cast(operator_id) do
      Repo.transaction(fn ->
        # SELECT-only operator access: every later session use rechecks enabled status.
        # Never create identities or memberships, or require runtime operator-update grants.
        case Repo.one(from o in Operator, where: o.id == ^id and o.enabled) do
          %Operator{} -> issue_token(id, "session", DateTime.add(now, 8, :hour))
          _ -> Repo.rollback(:unauthorized)
        end
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def revoke_session(raw) do
    case token_hash(raw) do
      {:ok, hash} ->
        Repo.delete_all(from t in Token, where: t.token_hash == ^hash and t.context == "session")

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  def issue_token(operator_id, context, expires_at) when context in ["login", "session"] do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {:ok, hash} = token_hash(raw)

    Repo.insert!(%Token{
      operator_id: operator_id,
      token_hash: hash,
      context: context,
      expires_at: expires_at
    })

    raw
  end

  defp token_hash(raw) when is_binary(raw) and byte_size(raw) == 43 do
    case Base.url_decode64(raw, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, :crypto.hash(:sha256, raw)}
      _ -> :error
    end
  end

  defp token_hash(_), do: :error
end
