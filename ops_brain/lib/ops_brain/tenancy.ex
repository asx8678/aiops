defmodule OpsBrain.Tenancy do
  @moduledoc "Operator-facing company-scoped APIs. No caller-supplied identity is authority."
  import Ecto.Query
  alias OpsBrain.{Accounts, Repo}
  alias OpsBrain.Tenancy.{Company, Environment, Membership, Scope, Source}

  def list_companies(token) do
    case Accounts.operator_for_session(token) do
      nil ->
        {:error, :unauthorized}

      operator ->
        {:ok,
         Repo.all(
           from c in Company,
             join: m in Membership,
             on: m.company_id == c.id,
             where: m.operator_id == ^operator.id,
             order_by: c.slug,
             limit: 100
         )}
    end
  end

  def authorize(token, company_id) do
    with {:ok, id} <- Ecto.UUID.cast(company_id),
         %{id: operator_id} <- Accounts.operator_for_session(token),
         true <-
           Repo.exists?(
             from m in Membership, where: m.company_id == ^id and m.operator_id == ^operator_id
           ) do
      {:ok, %Scope{session_token: token, company_id: id}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def with_scope(%Scope{} = scope, fun) when is_function(fun, 0) do
    if Repo.in_transaction?() and current_scope() not in [nil, ""],
      do: Repo.rollback(:nested_scope)

    Repo.transaction(fn ->
      case authorize(scope.session_token, scope.company_id) do
        {:ok, _} -> :ok
        _ -> Repo.rollback(:unauthorized)
      end

      # Reject nested scopes: no inner company transaction may change outer authority.
      if current_scope() not in [nil, ""], do: Repo.rollback(:nested_scope)
      set_scope(scope.company_id)
      result = fun.()
      # Explicit cleanup also protects callers using an outer transaction (e.g. sandbox).
      set_scope("")
      result
    end)
  end

  def with_scope(_, _), do: {:error, :unauthorized}

  def overview(scope) do
    with_scope(scope, fn ->
      %{
        company: Repo.get!(Company, scope.company_id),
        environments:
          Repo.all(
            from e in Environment, where: e.company_id == ^scope.company_id, order_by: e.name
          ),
        sources:
          Repo.all(
            from s in Source,
              where: s.company_id == ^scope.company_id,
              order_by: s.name,
              limit: 100
          )
      }
    end)
  end

  def get_source(scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, source} <-
           with_scope(scope, fn ->
             Repo.one(
               from s in Source, where: s.id == ^uuid and s.company_id == ^scope.company_id
             )
           end) do
      if source, do: {:ok, source}, else: {:error, :not_found}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def create_source(scope, attrs) do
    scoped_insert(scope, fn -> Source.changeset(%Source{company_id: scope.company_id}, attrs) end)
  end

  def create_environment(scope, attrs) do
    scoped_insert(scope, fn ->
      Environment.changeset(%Environment{company_id: scope.company_id}, attrs)
    end)
  end

  defp scoped_insert(scope, changeset) do
    with_scope(scope, fn ->
      case Repo.insert(changeset.()) do
        {:ok, value} -> value
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp current_scope do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('ops_brain.company_id', true)")
    value
  end

  defp set_scope(id), do: Repo.query!("SELECT set_config('ops_brain.company_id', $1, true)", [id])
end
