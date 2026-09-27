defmodule OpsBrain.IssueReview do
  @moduledoc "Transactional, revision-checked local operator actions and bounded audit history. No source or notification I/O."
  alias OpsBrain.{Accounts, Lifecycle, Redactor, Repo, Store, Tenancy}

  def assign(scope, id, owner, opts) do
    with {:ok, owner} <- assign_owner(owner),
         {:ok, revision} <- revision(opts, [:expected_revision]) do
      mutate(scope, id, revision, "assign", fn _ -> {:ok, %{"owner" => owner}} end)
    end
  end

  def unassign(scope, id, opts) do
    with {:ok, revision} <- revision(opts, [:expected_revision]) do
      mutate(scope, id, revision, "unassign", fn _ -> {:ok, %{"owner" => nil}} end)
    end
  end

  def review(scope, id, action, opts) do
    with {:ok, revision} <- revision(opts, [:expected_revision, :owner]),
         {:ok, action} <- Lifecycle.review_status(action),
         {:ok, owner} <- review_owner(Keyword.get(opts, :owner)) do
      mutate(scope, id, revision, "review", fn current ->
        with {:ok, action} <- Lifecycle.review_status(current["status"], action) do
          {:ok, %{"status" => action, "owner" => owner || current["owner"]}}
        end
      end)
    end
  end

  def snooze(scope, id, until, opts, now) do
    with {:ok, revision} <- revision(opts, [:expected_revision]),
         true <- match?(%DateTime{}, until) and match?(%DateTime{}, now),
         true <- DateTime.diff(until, now) in 1..604_800 do
      mutate(scope, id, revision, "snooze", fn _ -> {:ok, %{"snoozed_until" => until}} end)
    else
      false -> {:error, :invalid_snooze}
      error -> error
    end
  end

  def history(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Tenancy.with_scope(scope, fn ->
        Store.rows(
          "SELECT id::text,source_id::text,group_id::text,actor_id::text,actor_name,action,before_revision,after_revision,before_state,after_state,inserted_at FROM issue_audit_events WHERE group_id=$1::text::uuid ORDER BY after_revision DESC LIMIT 50",
          [id]
        )
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp revision(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      case Keyword.fetch(opts, :expected_revision) do
        {:ok, revision} when is_integer(revision) and revision in 1..2_147_483_646 ->
          {:ok, revision}

        :error ->
          {:error, :revision_required}

        _ ->
          {:error, :invalid_revision}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp revision(_, _), do: {:error, :invalid_options}

  defp mutate(scope, id, revision, action, change) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Tenancy.with_scope(scope, fn ->
        current =
          Store.one(
            "SELECT id::text,source_id::text,status,owner,snoozed_until,revision FROM issue_groups WHERE id=$1::text::uuid FOR UPDATE",
            [id]
          )

        if current do
          # Resolve the real actor after acquiring the group lock, rechecking
          # revocation that may have happened while this request was waiting.
          actor = actor!(scope)
          if current["revision"] != revision, do: Repo.rollback(:stale_revision)

          changes =
            case change.(current) do
              {:ok, changes} -> changes
              {:error, reason} -> Repo.rollback(reason)
            end

          next = Map.merge(current, changes)

          updated =
            Store.one(
              "UPDATE issue_groups SET status=$2,owner=$3,snoozed_until=$4,revision=revision+1 WHERE id=$1::text::uuid AND revision=$5 RETURNING id::text,status,owner,snoozed_until,revision",
              [id, next["status"], next["owner"], next["snoozed_until"], revision]
            )

          if updated == nil, do: Repo.rollback(:stale_revision)

          # Failure here rolls back the state update as well. No best-effort log.
          Repo.query!(
            "INSERT INTO issue_audit_events(id,company_id,source_id,group_id,actor_id,actor_name,action,before_revision,after_revision,before_state,after_state,inserted_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$6,$7,$8,$9,$10,$11,$12)",
            [
              Ecto.UUID.generate(),
              scope.company_id,
              current["source_id"],
              id,
              actor.id,
              Redactor.clean(actor.name, 100),
              action,
              revision,
              updated["revision"],
              snapshot(current),
              snapshot(updated),
              Store.now()
            ]
          )

          updated
        end
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp actor!(scope) do
    with {:ok, _} <- Tenancy.authorize(scope.session_token, scope.company_id),
         %{id: _} = actor <- Accounts.operator_for_session(scope.session_token) do
      actor
    else
      _ -> Repo.rollback(:unauthorized)
    end
  end

  defp snapshot(row) do
    %{
      "status" => row["status"],
      "owner" => if(is_binary(row["owner"]), do: Redactor.clean(row["owner"], 100)),
      "snoozed_until" => Store.iso(row["snoozed_until"])
    }
  end

  defp assign_owner(owner) when is_binary(owner) and byte_size(owner) in 1..100,
    do: {:ok, Redactor.clean(owner, 100)}

  defp assign_owner(_), do: {:error, :invalid_owner}

  defp review_owner(nil), do: {:ok, nil}

  defp review_owner(owner) when is_binary(owner) and byte_size(owner) <= 100,
    do: {:ok, Redactor.clean(owner, 100)}

  defp review_owner(_), do: {:error, :invalid_owner}
end
