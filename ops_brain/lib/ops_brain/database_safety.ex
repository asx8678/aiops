defmodule OpsBrain.DatabaseSafety do
  @moduledoc "Startup gate: the runtime database identity may not own or bypass protected data."
  use GenServer
  alias OpsBrain.Repo

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    verify!()
    {:ok, %{}}
  end

  def verify! do
    %{rows: [[unsafe_role]]} =
      Repo.query!("SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user")

    %{rows: [[protected]]} =
      Repo.query!("""
      SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname IN ('sources','environments','collection_states','pipeline_runs','run_snapshots','evidence_items','error_fingerprints','issue_groups','failure_occurrences','service_instances','observation_windows','source_budgets','notification_outbox','observation_revisions','kubernetes_cursors')
        AND c.relrowsecurity AND c.relforcerowsecurity
        AND NOT pg_has_role(current_user, c.relowner, 'MEMBER')
      """)

    if unsafe_role or protected != 15 do
      raise "Unsafe runtime database role or missing RLS migration. Use a non-owner, non-BYPASSRLS role."
    end

    :ok
  end
end
