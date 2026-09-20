defmodule OpsBrain.Workspace do
  @moduledoc "Single-workspace entry resolution. Configuration selects a home, never grants membership."
  alias OpsBrain.Tenancy

  def resolve(token) do
    case Application.get_env(:ops_brain, :workspace_company_id) do
      nil ->
        case Tenancy.list_companies(token) do
          {:ok, [company]} -> Tenancy.authorize(token, company.id)
          {:ok, []} -> {:error, :no_workspace}
          {:ok, _} -> {:error, :workspace_not_configured}
          error -> error
        end

      id when is_binary(id) ->
        Tenancy.authorize(token, id)

      _ ->
        {:error, :workspace_not_configured}
    end
  end
end
