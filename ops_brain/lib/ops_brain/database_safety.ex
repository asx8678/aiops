defmodule OpsBrain.DatabaseSafety do
  @moduledoc "Startup gate: the runtime database identity may not own or bypass protected data."
  use GenServer
  alias OpsBrain.Repo

  # One reviewed source of truth for the forced-RLS operational inventory. New
  # tenant-owned tables must be added here, to runtime_grants.sql and to a
  # forward migration in the same change.
  @protected_tables ~w(
    sources environments collection_states pipeline_runs run_snapshots
    evidence_items error_fingerprints issue_groups failure_occurrences
    service_instances observation_windows source_budgets notification_outbox
    observation_revisions kubernetes_cursors occurrence_evidence issue_audit_events
  )

  def protected_tables, do: @protected_tables

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
      Repo.query!(
        """
        SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = ANY($1)
          AND c.relrowsecurity AND c.relforcerowsecurity
          AND NOT pg_has_role(current_user, c.relowner, 'MEMBER')
        """,
        [@protected_tables]
      )

    if unsafe_role or protected != length(@protected_tables) do
      raise "Unsafe runtime database role or missing RLS migration. Use a non-owner, non-BYPASSRLS role."
    end

    %{rows: [[can_append, can_modify]]} =
      Repo.query!("""
      SELECT has_table_privilege(current_user, 'issue_audit_events', 'SELECT')
         AND has_table_privilege(current_user, 'issue_audit_events', 'INSERT'),
         has_table_privilege(current_user, 'issue_audit_events', 'UPDATE,DELETE,TRUNCATE')
      """)

    if not can_append or can_modify do
      raise "Unsafe audit history privileges. Apply reviewed SELECT/INSERT-only runtime grants."
    end

    :ok
  end
end
